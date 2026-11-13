from __future__ import annotations

import argparse
import hashlib
import json
import math
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.optimize import least_squares


INPUT_ANCHORS = np.array([0.0, 0.08, 0.22, 0.50, 0.72, 0.90, 1.0], np.float32)
HUE_CENTERS = np.array([0.075, 0.155, 0.33, 0.50, 0.64], np.float32)
HUE_WIDTHS = np.array([0.095, 0.09, 0.13, 0.10, 0.13], np.float32)


GLOBAL_NAMES = [
    "exposureEV", "brightness", "contrast", "blackPoint",
    "shadowRollOff", "lowerMidtoneLift", "midtoneBias",
    "upperMidtoneSeparation", "highlightRollOff", "whitePoint",
    "saturation", "orangeHue", "orangeSaturation", "orangeLuminance",
    "yellowHue", "yellowSaturation", "yellowLuminance", "greenHue",
    "greenSaturation", "greenLuminance",
]
GLOBAL_LOWER = np.array([
    -0.35, -0.06, 0.96, 0.0,
    0.0, -0.08, -0.08, -0.06, 0.0, 0.88,
    0.96, -0.025, -0.18, -0.08, -0.025, -0.18, -0.08, -0.03, -0.20, -0.08,
], np.float32)
GLOBAL_UPPER = np.array([
    0.35, 0.06, 1.14, 0.035,
    1.0, 0.12, 0.08, 0.10, 1.0, 1.0,
    1.08, 0.025, 0.18, 0.08, 0.025, 0.18, 0.08, 0.03, 0.20, 0.08,
], np.float32)
GLOBAL_NEUTRAL = np.array([
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
    1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
], np.float32)

LOCAL_REGIONS = ("ground", "vegetation", "sky", "architecture")
LOCAL_NAMES = [f"{region}.{control}" for region in LOCAL_REGIONS for control in ("exposureEV", "contrast", "saturation")]
LOCAL_LOWER = np.array(sum(([-0.14, 1.0, 0.94] if region != "sky" else [-0.20, 0.99999, 0.96] for region in LOCAL_REGIONS), []), np.float32)
LOCAL_UPPER = np.array(sum(([0.14, 1.075, 1.08] if region != "sky" else [0.08, 1.00001, 1.08] for region in LOCAL_REGIONS), []), np.float32)
LOCAL_NEUTRAL = np.array(sum(([0.0, 1.0, 1.0] for _ in LOCAL_REGIONS), []), np.float32)

# These bounds are deliberately outside `AutomaticEditingRecipe.clamped()`.
# They are used only to diagnose whether the transform vocabulary is capable
# while the current product safety envelope is the limiting factor.
EXTENDED_GLOBAL_LOWER = np.array([
    -1.20, -0.15, 0.80, 0.0,
    0.0, -0.25, -0.25, -0.20, 0.0, 0.70,
    0.75, -0.07, -0.45, -0.20, -0.07, -0.45, -0.20, -0.08, -0.45, -0.20,
], np.float32)
EXTENDED_GLOBAL_UPPER = np.array([
    0.60, 0.12, 1.35, 0.10,
    1.0, 0.25, 0.20, 0.25, 1.0, 1.0,
    1.35, 0.07, 0.50, 0.25, 0.07, 0.50, 0.25, 0.08, 0.50, 0.25,
], np.float32)
EXTENDED_LOCAL_LOWER = np.array(sum(([-1.0, 0.82, 0.70] if region != "sky" else [-0.8, 0.99999, 0.75] for region in LOCAL_REGIONS), []), np.float32)
EXTENDED_LOCAL_UPPER = np.array(sum(([0.6, 1.30, 1.35] if region != "sky" else [0.35, 1.00001, 1.30] for region in LOCAL_REGIONS), []), np.float32)


@dataclass
class RegistrationEvidence:
    source_shape: list[int]
    target_shape: list[int]
    keypoints: list[int]
    good_matches: int
    inliers: int
    inlier_ratio: float
    median_reprojection_px: float
    p95_reprojection_px: float
    homography_source_to_target: list[list[float]]
    corner_shift_px: list[list[float]]
    strict_same_frame: bool
    note: str


def read_image(path: Path, flags: int = cv2.IMREAD_COLOR) -> np.ndarray:
    data = np.fromfile(str(path), dtype=np.uint8)
    image = cv2.imdecode(data, flags)
    if image is None:
        raise ValueError(f"Cannot decode {path}")
    return image


def write_image(path: Path, image: np.ndarray, quality: int = 94) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    suffix = path.suffix.lower() or ".jpg"
    params = [cv2.IMWRITE_JPEG_QUALITY, quality] if suffix in {".jpg", ".jpeg"} else []
    ok, encoded = cv2.imencode(suffix, image, params)
    if not ok:
        raise ValueError(f"Cannot encode {path}")
    encoded.tofile(str(path))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4).astype(np.float32)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return np.where(value <= 0.0031308, value * 12.92, 1.055 * np.power(value, 1.0 / 2.4) - 0.055).astype(np.float32)


def rgb_to_hsv(rgb: np.ndarray) -> np.ndarray:
    flat = np.clip(rgb.reshape(-1, 1, 3), 0, 1).astype(np.float32)
    return cv2.cvtColor(flat, cv2.COLOR_RGB2HSV).reshape(rgb.shape[:-1] + (3,)) * np.array([1 / 360, 1, 1], np.float32)


def hsv_to_rgb(hsv: np.ndarray) -> np.ndarray:
    value = hsv.copy().astype(np.float32)
    value[..., 0] = np.mod(value[..., 0], 1.0) * 360
    flat = value.reshape(-1, 1, 3)
    return cv2.cvtColor(flat, cv2.COLOR_HSV2RGB).reshape(hsv.shape)


def hue_weight(hue: np.ndarray, center: float, width: float) -> np.ndarray:
    direct = np.abs(hue - center)
    distance = np.minimum(direct, 1.0 - direct)
    normalized = np.maximum(0.0, 1.0 - distance / width)
    return normalized * normalized * (3.0 - 2.0 * normalized)


def smooth_curve_map(value: np.ndarray, outputs: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0, 1)
    indices = np.searchsorted(INPUT_ANCHORS, value, side="left")
    indices = np.clip(indices, 1, len(INPUT_ANCHORS) - 1)
    left = INPUT_ANCHORS[indices - 1]
    right = INPUT_ANCHORS[indices]
    fraction = np.divide(value - left, right - left, out=np.zeros_like(value), where=(right > left))
    fraction = fraction * fraction * (3.0 - 2.0 * fraction)
    mapped = outputs[indices - 1] + (outputs[indices] - outputs[indices - 1]) * fraction
    return np.where(value <= 0, outputs[0], np.where(value >= 1, outputs[-1], mapped))


def core_image_cube_curve_map(value: np.ndarray, outputs: np.ndarray, dimension: int = 32) -> np.ndarray:
    """Match the app's 32³ CIColorCube sampling and linear LUT interpolation.

    The Swift renderer evaluates its smooth seven-anchor curve only at the cube
    lattice. Core Image then interpolates between those lattice samples; applying
    the analytic smooth curve directly is measurably different for steep R3
    midtones and previously understated the Apple result by as much as 20/255.
    """
    value = np.clip(value, 0, 1).astype(np.float32)
    grid = np.linspace(0, 1, dimension, dtype=np.float32)
    samples = smooth_curve_map(grid, outputs)
    scaled = value * np.float32(dimension - 1)
    lower = np.floor(scaled).astype(np.int32)
    upper = np.minimum(lower + 1, dimension - 1)
    fraction = scaled - lower
    return (samples[lower] * (1.0 - fraction) + samples[upper] * fraction).astype(np.float32)


def cinematic_outputs(params: np.ndarray, strength: float = 1.0) -> np.ndarray:
    _, _, _, _, shadow_roll, lower, middle, upper, highlight_roll, white, *_ = params
    target = INPUT_ANCHORS.copy()
    target[1] += shadow_roll * 0.018
    target[2] += lower
    target[3] += middle
    target[4] += upper
    target[5] -= highlight_roll * 0.035
    target[6] = min(target[6], white)
    output = INPUT_ANCHORS + (target - INPUT_ANCHORS) * strength
    for index in range(1, len(output)):
        output[index] = max(output[index], output[index - 1] + 0.008)
    return np.clip(output, 0, 1).astype(np.float32)


def apply_hsl_transform_encoded(encoded: np.ndarray, params: np.ndarray) -> np.ndarray:
    """Apply the Swift processor's perceptual HSV operation in encoded sRGB."""
    hsv = rgb_to_hsv(encoded)
    hue, sat, val = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    chroma_guard = np.minimum(1.0, sat * 3.2)
    weights = [hue_weight(hue, float(c), float(w)) for c, w in zip(HUE_CENTERS, HUE_WIDTHS)]
    # Solver exposes orange/yellow/green only. Cyan and blue remain exactly neutral.
    hue_delta = (weights[0] * params[11] + weights[1] * params[14] + weights[2] * params[17]) * chroma_guard
    sat_delta = (weights[0] * params[12] + weights[1] * params[15] + weights[2] * params[18]) * chroma_guard
    lum_delta = (weights[0] * params[13] + weights[1] * params[16] + weights[2] * params[19]) * chroma_guard
    hsv[..., 0] = np.mod(hue + hue_delta, 1.0)
    hsv[..., 1] = np.clip(sat * (1.0 + sat_delta), 0, 1)
    hsv[..., 2] = np.clip(val + lum_delta, 0, 1)
    return hsv_to_rgb(hsv)


def trilinear_cube_sample(values: np.ndarray, cube: np.ndarray) -> np.ndarray:
    """Sample an RGB cube exactly as a CIColorCube lattice interpolation.

    Work in bounded chunks so a full 2160x2880 validation frame does not create
    eight simultaneous full-resolution corner arrays.
    """
    original_shape = values.shape
    flat = np.clip(values.reshape(-1, 3), 0, 1).astype(np.float32)
    dimension = cube.shape[0]
    output = np.empty_like(flat)
    for start in range(0, len(flat), 250_000):
        part = flat[start:start + 250_000]
        scaled = part * np.float32(dimension - 1)
        lower = np.floor(scaled).astype(np.int32)
        upper = np.minimum(lower + 1, dimension - 1)
        fraction = scaled - lower
        sampled = np.zeros_like(part)
        for red_high in (0, 1):
            red_index = upper[:, 0] if red_high else lower[:, 0]
            red_weight = fraction[:, 0] if red_high else 1.0 - fraction[:, 0]
            for green_high in (0, 1):
                green_index = upper[:, 1] if green_high else lower[:, 1]
                green_weight = fraction[:, 1] if green_high else 1.0 - fraction[:, 1]
                for blue_high in (0, 1):
                    blue_index = upper[:, 2] if blue_high else lower[:, 2]
                    blue_weight = fraction[:, 2] if blue_high else 1.0 - fraction[:, 2]
                    weight = (red_weight * green_weight * blue_weight)[:, None]
                    sampled += cube[red_index, green_index, blue_index] * weight
        output[start:start + len(part)] = sampled
    return output.reshape(original_shape)


def apply_hsl(linear: np.ndarray, params: np.ndarray, dimension: int = 32) -> np.ndarray:
    """Match ProfessionalHSLProcessor's perceptual 32³ Core Image cube.

    The cube input/output is extended-linear sRGB, while the HSV calculation is
    intentionally performed in encoded sRGB inside each lattice sample.
    """
    grid = np.linspace(0, 1, dimension, dtype=np.float32)
    red, green, blue = np.meshgrid(grid, grid, grid, indexing="ij")
    lattice_linear = np.stack([red, green, blue], axis=-1)
    lattice_encoded = linear_to_srgb(lattice_linear)
    adjusted_encoded = apply_hsl_transform_encoded(lattice_encoded, params)
    cube = srgb_to_linear(adjusted_encoded)
    return trilinear_cube_sample(linear, cube)


def apply_color_controls(linear: np.ndarray, brightness: float, contrast: float, saturation: float) -> np.ndarray:
    # This follows the documented control semantics, but Apple does not publish
    # CIColorControls' complete implementation. Core Image parity remains required.
    luma = np.sum(linear * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1, keepdims=True)
    colored = luma + (linear - luma) * saturation
    return np.clip((colored - 0.5) * contrast + 0.5 + brightness, 0, 1)


def apply_measured_cool_cinematic_grade(
    encoded_rgb: np.ndarray,
    intensity: float,
    shadow_cool: float,
    midtone_cool: float,
    highlight_warm: float,
    neutral_highlight_protection: float,
    color_contrast: float,
) -> np.ndarray:
    """Windows projection of PT-AESTHETIC-012's Core Image diagnostic grade.

    This mirrors the public arithmetic used by `CinematicColorGradingEngine` in
    extended-linear sRGB. Core Image's undocumented filter details still require
    Apple pixel tests, so callers must label its output as a projection rather
    than an iPhone/Core Image result.
    """
    linear = srgb_to_linear(encoded_rgb.astype(np.float32))
    luma = np.sum(linear * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)
    shadow_mask = np.power(np.clip(1.0 - luma, 0, 1), 2.0)
    highlight_mask = np.power(np.clip(luma, 0, 1), 2.15)
    raw_midtone_mask = np.clip(4.0 * luma - 4.0 * luma * luma, 0, 1)
    protected_highlight = np.clip(highlight_mask * neutral_highlight_protection, 0, 1)
    midtone_mask = raw_midtone_mask * (1.0 - protected_highlight)

    def bias(values: np.ndarray, vector: tuple[float, float, float], amount: float, mask: np.ndarray) -> np.ndarray:
        candidate = values + np.array(vector, np.float32) * np.float32(amount)
        alpha = np.clip(mask[..., None], 0, 1).astype(np.float32)
        return candidate * alpha + values * (1.0 - alpha)

    output = linear
    if shadow_cool > 1e-6:
        output = bias(output, (-0.075, 0.006, 0.085), intensity * shadow_cool, shadow_mask)
    if midtone_cool > 1e-6:
        output = bias(output, (-0.052, 0.004, 0.062), intensity * midtone_cool, midtone_mask)
    if highlight_warm > 1e-6:
        amount = intensity * highlight_warm * (1.0 - neutral_highlight_protection * 0.82)
        output = bias(output, (0.045, 0.008, -0.032), amount, highlight_mask)
    if color_contrast > 1e-6:
        output = apply_color_controls(
            output,
            brightness=0.0,
            contrast=1.0 + color_contrast * 0.04,
            saturation=1.0 + color_contrast * 0.10,
        )
    return np.clip(linear_to_srgb(output), 0, 1).astype(np.float32)


def render_global(encoded_rgb: np.ndarray, params: np.ndarray) -> np.ndarray:
    exposure, brightness, contrast, black_point = params[:4]
    linear = srgb_to_linear(encoded_rgb) * np.float32(2.0 ** float(exposure))
    if black_point > 1e-6:
        slope = 1.0 / (1.0 - black_point)
        linear = linear * slope - black_point * slope
    uses_cinematic_curve = (
        abs(float(params[4])) > 1e-6
        or abs(float(params[5])) > 1e-6
        or abs(float(params[6])) > 1e-6
        or abs(float(params[7])) > 1e-6
        or abs(float(params[8])) > 1e-6
        or abs(float(params[9]) - 1.0) > 1e-6
    )
    if uses_cinematic_curve:
        outputs = cinematic_outputs(params, strength=1.0)
        linear = core_image_cube_curve_map(np.clip(linear, 0, 1), outputs)
    linear = apply_color_controls(linear, float(brightness), float(contrast), float(params[10]))
    # CIColorCube executes in the CIContext's extended-linear-sRGB working
    # space. HSL therefore sees linear working values, not encoded sRGB.
    linear = apply_hsl(linear, params)
    return np.clip(linear_to_srgb(linear), 0, 1).astype(np.float32)


def apply_local_controls(encoded: np.ndarray, params: np.ndarray, masks: dict[str, np.ndarray]) -> np.ndarray:
    # The app composites all local candidates and masks in extended-linear-sRGB.
    # Keep one linear working buffer so sequential regional edits do not blend
    # encoded sRGB values.
    output = srgb_to_linear(encoded.astype(np.float32))
    for index, region in enumerate(LOCAL_REGIONS):
        mask = masks.get(region)
        if mask is None or float(mask.max()) <= 0:
            continue
        ev, contrast, saturation = params[index * 3:index * 3 + 3]
        adjusted_linear = output * np.float32(2.0 ** float(ev))
        adjusted_linear = apply_color_controls(adjusted_linear, 0.0, float(contrast), float(saturation))
        alpha = np.clip(mask[..., None], 0, 1).astype(np.float32)
        output = adjusted_linear * alpha + output * (1.0 - alpha)
    return np.clip(linear_to_srgb(output), 0, 1)


def register_pair(source_bgr: np.ndarray, target_bgr: np.ndarray) -> tuple[np.ndarray, np.ndarray, RegistrationEvidence]:
    source_gray = cv2.cvtColor(source_bgr, cv2.COLOR_BGR2GRAY)
    target_gray = cv2.cvtColor(target_bgr, cv2.COLOR_BGR2GRAY)
    sift = cv2.SIFT_create(nfeatures=12000, contrastThreshold=0.02)
    source_keys, source_desc = sift.detectAndCompute(source_gray, None)
    target_keys, target_desc = sift.detectAndCompute(target_gray, None)
    matches = cv2.BFMatcher(cv2.NORM_L2).knnMatch(source_desc, target_desc, k=2)
    good = [first for first, second in matches if first.distance < 0.72 * second.distance]
    if len(good) < 40:
        raise RuntimeError(f"Insufficient same-frame evidence: only {len(good)} feature matches")
    source_points = np.float32([source_keys[item.queryIdx].pt for item in good])
    target_points = np.float32([target_keys[item.trainIdx].pt for item in good])
    homography, inlier_mask = cv2.findHomography(source_points, target_points, cv2.RANSAC, 2.0)
    if homography is None or inlier_mask is None:
        raise RuntimeError("Homography estimation failed")
    inliers = inlier_mask.ravel().astype(bool)
    projected = cv2.perspectiveTransform(source_points[inliers, None, :], homography)[:, 0]
    errors = np.linalg.norm(projected - target_points[inliers], axis=1)
    inverse = np.linalg.inv(homography)
    height, width = source_bgr.shape[:2]
    aligned_target = cv2.warpPerspective(target_bgr, inverse, (width, height), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_CONSTANT)
    overlap = cv2.warpPerspective(np.full(target_gray.shape, 255, np.uint8), inverse, (width, height), flags=cv2.INTER_NEAREST) > 0
    overlap = cv2.erode(overlap.astype(np.uint8), np.ones((13, 13), np.uint8), iterations=1).astype(bool)
    corners = np.float32([[[0, 0]], [[width - 1, 0]], [[width - 1, height - 1]], [[0, height - 1]]])
    shifts = cv2.perspectiveTransform(corners, homography)[:, 0] - corners[:, 0]
    inlier_ratio = float(inliers.mean())
    median_error = float(np.median(errors))
    evidence = RegistrationEvidence(
        source_shape=list(source_bgr.shape), target_shape=list(target_bgr.shape),
        keypoints=[len(source_keys), len(target_keys)], good_matches=len(good),
        inliers=int(inliers.sum()), inlier_ratio=inlier_ratio,
        median_reprojection_px=median_error, p95_reprojection_px=float(np.percentile(errors, 95)),
        homography_source_to_target=homography.tolist(), corner_shift_px=shifts.tolist(),
        strict_same_frame=inlier_ratio >= 0.85 and median_error <= 1.0,
        note="Same capture geometry after homography; target has a small scale/crop/re-encode difference, so metrics use registered overlap only.",
    )
    return aligned_target, overlap, evidence


def find_mask(mask_dir: Path, token: str) -> Path | None:
    candidates = [path for path in mask_dir.glob("*.jpg") if token in path.name and "叠加" not in path.name]
    return candidates[0] if candidates else None


def load_masks(mask_dir: Path | None, shape: tuple[int, int], valid: np.ndarray) -> dict[str, np.ndarray]:
    height, width = shape
    mapping = {"ground": "地面道路", "vegetation": "植被", "sky": "天空", "architecture": "建筑"}
    masks: dict[str, np.ndarray] = {}
    if mask_dir:
        for region, token in mapping.items():
            path = find_mask(mask_dir, token)
            if path is None:
                continue
            raw = read_image(path, cv2.IMREAD_GRAYSCALE).astype(np.float32) / 255.0
            resized = cv2.resize(raw, (width, height), interpolation=cv2.INTER_LINEAR)
            # Core Image uses a roughly 0.6% long-edge feather for these masks.
            sigma = min(max(max(height, width) * 0.006, 1.0), 18.0)
            softened = cv2.GaussianBlur(resized, (0, 0), sigmaX=sigma, sigmaY=sigma)
            masks[region] = np.clip(softened * valid, 0, 1)
    return masks


def build_valid_mask(overlap: np.ndarray) -> np.ndarray:
    valid = overlap.copy()
    height, width = valid.shape
    # The tutorial exports contain a Douyin attribution overlay near the lower
    # edge. It is excluded from fitting, never removed from the delivered image.
    valid[int(height * 0.91):, :] = False
    valid[:, : max(3, int(width * 0.004))] = False
    valid[:, width - max(3, int(width * 0.004)):] = False
    return valid


def balanced_sample_indices(valid: np.ndarray, masks: dict[str, np.ndarray], maximum: int, seed: int = 20261109) -> np.ndarray:
    rng = np.random.default_rng(seed)
    flat_valid = np.flatnonzero(valid.reshape(-1))
    pieces: list[np.ndarray] = []
    per_region = max(400, maximum // (len(masks) + 2))
    for mask in masks.values():
        candidates = np.flatnonzero((valid & (mask > 0.45)).reshape(-1))
        if len(candidates):
            pieces.append(rng.choice(candidates, min(per_region, len(candidates)), replace=False))
    remaining = max(0, maximum - sum(len(piece) for piece in pieces))
    pieces.append(rng.choice(flat_valid, min(remaining, len(flat_valid)), replace=False))
    return np.unique(np.concatenate(pieces))


def residual_global(params: np.ndarray, source: np.ndarray, target: np.ndarray, scale: np.ndarray) -> np.ndarray:
    rendered = render_global(source, params)
    rgb = (rendered - target).reshape(-1)
    luma_weights = np.array([0.2126, 0.7152, 0.0722], np.float32)
    luma = ((rendered - target) * luma_weights).sum(axis=-1)
    regularization = (params - GLOBAL_NEUTRAL) / scale * 0.012
    return np.concatenate([rgb, luma * 1.35, regularization]).astype(np.float64)


def residual_local(params: np.ndarray, global_render: np.ndarray, target: np.ndarray, masks: dict[str, np.ndarray], scale: np.ndarray) -> np.ndarray:
    rendered = apply_local_controls(global_render, params, masks)
    rgb = (rendered - target).reshape(-1)
    luma_weights = np.array([0.2126, 0.7152, 0.0722], np.float32)
    luma = ((rendered - target) * luma_weights).sum(axis=-1)
    regularization = (params - LOCAL_NEUTRAL) / scale * 0.016
    return np.concatenate([rgb, luma * 1.45, regularization]).astype(np.float64)


def fit_parameters(
    source: np.ndarray,
    target: np.ndarray,
    valid: np.ndarray,
    masks: dict[str, np.ndarray],
    max_evaluations: int,
    global_lower: np.ndarray = GLOBAL_LOWER,
    global_upper: np.ndarray = GLOBAL_UPPER,
    local_lower: np.ndarray = LOCAL_LOWER,
    local_upper: np.ndarray = LOCAL_UPPER,
) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
    indices = balanced_sample_indices(valid, masks, maximum=14000)
    source_samples = source.reshape(-1, 3)[indices]
    target_samples = target.reshape(-1, 3)[indices]
    start = time.perf_counter()
    # The seven-anchor Core Image stage is deliberately bypassed at the exact
    # neutral point. Generic active seeds avoid a zero numerical derivative at
    # that branch without encoding anything about the photographed scene.
    seeds = [GLOBAL_NEUTRAL.copy()]
    for exposure, midtone, contrast, saturation in (
        (-0.12, -0.025, 1.035, 1.01),
        (-0.28, -0.060, 1.075, 1.03),
        (0.08, 0.025, 1.015, 1.01),
    ):
        seed = GLOBAL_NEUTRAL.copy()
        seed[0], seed[2], seed[6], seed[8], seed[9], seed[10] = exposure, contrast, midtone, 0.28, 0.965, saturation
        seeds.append(np.clip(seed, global_lower + 1e-5, global_upper - 1e-5))
    global_scale = np.maximum(global_upper - global_lower, 1e-4)
    global_results = [
        least_squares(
            residual_global, seed, bounds=(global_lower, global_upper),
            args=(source_samples, target_samples, global_scale), loss="soft_l1", f_scale=0.035,
            max_nfev=max_evaluations, xtol=2e-5, ftol=2e-5, gtol=2e-5,
            diff_step=1e-2,
        )
        for seed in seeds
    ]
    global_result = min(global_results, key=lambda item: item.cost)
    global_samples = render_global(source_samples, global_result.x)
    sample_masks = {name: mask.reshape(-1)[indices] for name, mask in masks.items()}
    local_seed = LOCAL_NEUTRAL.copy()
    # Non-zero generic starting points keep finite differences representable in
    # float32; optimisation remains entirely target-driven.
    for index in range(len(LOCAL_REGIONS)):
        local_seed[index * 3] = -0.015
        local_seed[index * 3 + 1] = 1.01 if LOCAL_REGIONS[index] != "sky" else 1.0
    local_result = least_squares(
        residual_local, np.clip(local_seed, local_lower + 1e-5, local_upper - 1e-5), bounds=(local_lower, local_upper),
        args=(global_samples, target_samples, sample_masks, np.maximum(local_upper - local_lower, 1e-4)), loss="soft_l1", f_scale=0.03,
        max_nfev=max(80, max_evaluations // 2), xtol=2e-5, ftol=2e-5, gtol=2e-5,
        diff_step=1e-2,
    )
    diagnostics = {
        "sample_count": int(len(indices)), "seconds": time.perf_counter() - start,
        "global": {"success": bool(global_result.success), "message": global_result.message, "nfev": int(global_result.nfev), "cost": float(global_result.cost), "optimality": float(global_result.optimality), "multi_start_costs": [float(item.cost) for item in global_results]},
        "local": {"success": bool(local_result.success), "message": local_result.message, "nfev": int(local_result.nfev), "cost": float(local_result.cost), "optimality": float(local_result.optimality)},
    }
    return global_result.x.astype(np.float32), local_result.x.astype(np.float32), diagnostics


def luminance(rgb: np.ndarray) -> np.ndarray:
    return np.sum(srgb_to_linear(rgb) * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)


def lab_image(rgb: np.ndarray) -> np.ndarray:
    return cv2.cvtColor(np.clip(rgb, 0, 1).astype(np.float32), cv2.COLOR_RGB2LAB)


def detail_energy(rgb: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(np.clip(rgb, 0, 1).astype(np.float32), cv2.COLOR_RGB2GRAY)
    dx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    dy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    return np.sqrt(dx * dx + dy * dy)


def region_metrics(source: np.ndarray, target: np.ndarray, rendered: np.ndarray, valid: np.ndarray, masks: dict[str, np.ndarray]) -> dict[str, Any]:
    hsv = rgb_to_hsv(source)
    rows = np.indices(valid.shape)[0] / max(1, valid.shape[0] - 1)
    derived = {
        "yellow_orange": ((hsv[..., 0] >= 0.035) & (hsv[..., 0] <= 0.19) & (hsv[..., 1] >= 0.16)).astype(np.float32),
        "green": ((hsv[..., 0] > 0.19) & (hsv[..., 0] <= 0.48) & (hsv[..., 1] >= 0.12)).astype(np.float32),
        "neutral_bright": ((hsv[..., 1] < 0.13) & (hsv[..., 2] > 0.48)).astype(np.float32),
        "lower_frame_white_neutral": ((hsv[..., 1] < 0.12) & (hsv[..., 2] > 0.72) & (rows > 0.42)).astype(np.float32),
    }
    all_masks = {"global": valid.astype(np.float32), **masks, **derived}
    result: dict[str, Any] = {}
    labs = {"A_source": lab_image(source), "T_target": lab_image(target), "R_render": lab_image(rendered)}
    details = {"A_source": detail_energy(source), "T_target": detail_energy(target), "R_render": detail_energy(rendered)}
    for name, weight in all_masks.items():
        selected = valid & (weight > 0.35)
        if selected.sum() < 64:
            continue
        item: dict[str, Any] = {"pixels": int(selected.sum()), "coverage": float(selected.mean())}
        for label, image in (("A_source", source), ("T_target", target), ("R_render", rendered)):
            lum = luminance(image)[selected]
            h = rgb_to_hsv(image)[selected]
            lab = labs[label][selected]
            item[label] = {
                "linear_luminance_mean": float(lum.mean()),
                "linear_luminance_p05_p50_p95": [float(x) for x in np.percentile(lum, [5, 50, 95])],
                "saturation_mean": float(h[:, 1].mean()),
                "highlight_clip_ratio": float((lum >= 0.98).mean()),
                "shadow_clip_ratio": float((lum <= 0.006).mean()),
                "lab_mean": [float(x) for x in lab.mean(axis=0)],
                "lab_chroma_mean": float(np.sqrt(lab[:, 1] ** 2 + lab[:, 2] ** 2).mean()),
                "detail_energy_mean": float(details[label][selected].mean()),
            }
        rgb_error = np.abs(rendered[selected] - target[selected])
        delta_e = np.linalg.norm(labs["R_render"][selected] - labs["T_target"][selected], axis=1)
        item["R_to_T"] = {
            "rgb_mae": float(rgb_error.mean()),
            "linear_luminance_mae": float(np.abs(luminance(rendered)[selected] - luminance(target)[selected]).mean()),
            "deltaE76_mean": float(delta_e.mean()),
        }
        result[name] = item
    if "ground" in result and "vegetation" in result:
        for label in ("A_source", "T_target", "R_render"):
            result.setdefault("relationships", {})[f"ground_minus_vegetation_luminance_{label}"] = (
                result["ground"][label]["linear_luminance_mean"] - result["vegetation"][label]["linear_luminance_mean"]
            )
    return result


def values_at_bounds(names: list[str], values: np.ndarray, lower: np.ndarray, upper: np.ndarray, tolerance: float = 0.012) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    span = np.maximum(upper - lower, 1e-6)
    for name, value, low, high, width in zip(names, values, lower, upper, span):
        low_distance = (value - low) / width
        high_distance = (high - value) / width
        if low_distance <= tolerance:
            result.append({"parameter": name, "side": "lower", "value": float(value), "bound": float(low)})
        elif high_distance <= tolerance:
            result.append({"parameter": name, "side": "upper", "value": float(value), "bound": float(high)})
    return result


def edge_halo_risk(source: np.ndarray, rendered: np.ndarray, masks: dict[str, np.ndarray]) -> dict[str, float]:
    source_luma = luminance(source)
    render_luma = luminance(rendered)
    result: dict[str, float] = {}
    for name, mask in masks.items():
        binary = (mask > 0.5).astype(np.uint8)
        boundary = cv2.morphologyEx(binary, cv2.MORPH_GRADIENT, np.ones((9, 9), np.uint8)).astype(bool)
        if boundary.sum() < 20:
            continue
        change = np.abs(render_luma - source_luma)
        result[name] = float(np.percentile(change[boundary], 95))
    return result


def parameter_dict(names: Iterable[str], values: np.ndarray) -> dict[str, float]:
    return {name: float(value) for name, value in zip(names, values)}


def contact_sheet(items: list[tuple[str, Path]], output: Path) -> None:
    panels: list[tuple[str, Image.Image]] = []
    for label, path in items:
        image = Image.open(path).convert("RGB")
        image.thumbnail((540, 720), Image.Resampling.LANCZOS)
        panels.append((label, image.copy()))
    canvas = Image.new("RGB", (len(panels) * 560, 780), (22, 22, 22))
    draw = ImageDraw.Draw(canvas)
    font_path = Path(r"C:\Windows\Fonts\msyh.ttc")
    font = ImageFont.truetype(str(font_path), 22) if font_path.exists() else ImageFont.load_default()
    for index, (label, image) in enumerate(panels):
        x = index * 560 + (560 - image.width) // 2
        canvas.paste(image, (x, 45))
        draw.text((index * 560 + 16, 10), label, fill="white", font=font)
    canvas.save(output, quality=92)


def run(args: argparse.Namespace) -> dict[str, Any]:
    source_path, target_path, output = Path(args.source), Path(args.target), Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    source_bgr, target_bgr = read_image(source_path), read_image(target_path)
    aligned_target_bgr, overlap, registration = register_pair(source_bgr, target_bgr)
    if not registration.strict_same_frame:
        raise RuntimeError("A/T are not proven to be the same frame; inverse solving stopped")
    valid = build_valid_mask(overlap)
    masks = load_masks(Path(args.mask_dir) if args.mask_dir else None, source_bgr.shape[:2], valid)
    source = cv2.cvtColor(source_bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    target = cv2.cvtColor(aligned_target_bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0

    scale = min(1.0, 480.0 / max(source.shape[:2]))
    working_size = (max(1, int(source.shape[1] * scale)), max(1, int(source.shape[0] * scale)))
    source_small = cv2.resize(source, working_size, interpolation=cv2.INTER_AREA)
    target_small = cv2.resize(target, working_size, interpolation=cv2.INTER_AREA)
    valid_small = cv2.resize(valid.astype(np.uint8), working_size, interpolation=cv2.INTER_NEAREST).astype(bool)
    masks_small = {name: cv2.resize(mask, working_size, interpolation=cv2.INTER_AREA) for name, mask in masks.items()}
    global_params, local_params, solver_diagnostics = fit_parameters(source_small, target_small, valid_small, masks_small, args.max_evaluations)

    global_render = render_global(source, global_params)
    local_render = apply_local_controls(global_render, local_params, masks)
    global_bgr = cv2.cvtColor((global_render * 255 + 0.5).astype(np.uint8), cv2.COLOR_RGB2BGR)
    local_bgr = cv2.cvtColor((local_render * 255 + 0.5).astype(np.uint8), cv2.COLOR_RGB2BGR)

    source_out = output / "A_source.jpg"
    target_out = output / "T_target_original.jpg"
    target_aligned_out = output / "T_target_registered.jpg"
    global_out = output / "R_global_only.jpg"
    local_out = output / "R_global_plus_local.jpg"
    write_image(source_out, source_bgr)
    write_image(target_out, target_bgr)
    write_image(target_aligned_out, aligned_target_bgr)
    write_image(global_out, global_bgr)
    write_image(local_out, local_bgr)

    extended: dict[str, Any] | None = None
    extended_out: Path | None = None
    if args.extended_gap_probe:
        extended_global, extended_local, extended_solver = fit_parameters(
            source_small, target_small, valid_small, masks_small,
            max(120, args.max_evaluations),
            EXTENDED_GLOBAL_LOWER, EXTENDED_GLOBAL_UPPER,
            EXTENDED_LOCAL_LOWER, EXTENDED_LOCAL_UPPER,
        )
        extended_render = apply_local_controls(render_global(source, extended_global), extended_local, masks)
        extended_out = output / "R_extended_bounds_gap_probe.jpg"
        write_image(extended_out, cv2.cvtColor((extended_render * 255 + 0.5).astype(np.uint8), cv2.COLOR_RGB2BGR))
        extended = {
            "status": "research_only_outside_current_app_clamps",
            "purpose": "separate transform-vocabulary capability from current safety-bound limitations",
            "global_parameters": parameter_dict(GLOBAL_NAMES, extended_global),
            "local_parameters": parameter_dict(LOCAL_NAMES, extended_local),
            "solver": extended_solver,
            "metrics": region_metrics(source, target, extended_render, valid, masks),
            "artifact": extended_out.name,
        }
    write_image(output / "valid_fit_mask.png", valid.astype(np.uint8) * 255)
    for name, mask in masks.items():
        write_image(output / f"mask_{name}.png", (np.clip(mask, 0, 1) * 255).astype(np.uint8))

    global_metrics = region_metrics(source, target, global_render, valid, masks)
    local_metrics = region_metrics(source, target, local_render, valid, masks)
    report = {
        "schema": "xiao-su-camera.parameter-inverse-solving.v1",
        "source": {"path": str(source_path.resolve()), "sha256": sha256(source_path)},
        "target": {"path": str(target_path.resolve()), "sha256": sha256(target_path)},
        "registration": asdict(registration),
        "fit_policy": {
            "target_pixels_are_never_blended_or_copied": True,
            "watermark_exclusion": "bottom 9% excluded from objective; source overlay remains in R",
            "working_long_edge": max(working_size),
            "full_resolution_validation": f"{source.shape[1]}x{source.shape[0]}",
            "global_first_then_local": True,
            "core_image_parity": "partial; Apple-only filters held neutral; remote Core Image parity still required",
        },
        "public_tutorial_controls": {
            "software": "iPhone Photos / original camera editor",
            "confirmed_same_creator_id": "97619347110",
            "values": {"exposure": -17, "brilliance": -49, "highlights": -80, "shadows": 89, "contrast": 12, "brightness": -19, "blackPoint": 7, "saturation": 8, "warmth": 34, "tint": 42, "definition": 19, "filter": "Vivid"},
            "mapping_policy": "provenance evidence only; values are not numerically copied into Core Image parameters",
        },
        "global_parameters": parameter_dict(GLOBAL_NAMES, global_params),
        "local_parameters": parameter_dict(LOCAL_NAMES, local_params),
        "parameters_at_current_bounds": values_at_bounds(GLOBAL_NAMES, global_params, GLOBAL_LOWER, GLOBAL_UPPER) + values_at_bounds(LOCAL_NAMES, local_params, LOCAL_LOWER, LOCAL_UPPER),
        "solver": solver_diagnostics,
        "global_only_metrics": global_metrics,
        "global_plus_local_metrics": local_metrics,
        "local_boundary_change_p95": edge_halo_risk(source, local_render, masks),
        "extended_bounds_gap_probe": extended,
        "artifacts": {"A": source_out.name, "T_original": target_out.name, "T_registered": target_aligned_out.name, "R_global": global_out.name, "R_local": local_out.name},
        "aesthetic_status": "pending_human_review",
    }
    (output / "inverse_result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    comparison_items = [
        ("A 原图", source_out), ("T 专业目标（配准后）", target_aligned_out),
        ("R1 仅全局参数", global_out), ("R2 全局+可靠局部", local_out),
    ]
    if extended_out is not None:
        comparison_items.append(("R3 扩展边界（仅缺口诊断）", extended_out))
    contact_sheet(comparison_items, output / "A_T_R_comparison.jpg")
    return report


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Renderer-constrained professional-photo parameter inverse solver")
    value.add_argument("--source", required=True)
    value.add_argument("--target", required=True)
    value.add_argument("--mask-dir")
    value.add_argument("--output", required=True)
    value.add_argument("--max-evaluations", type=int, default=150)
    value.add_argument("--extended-gap-probe", action="store_true")
    return value


if __name__ == "__main__":
    result = run(parser().parse_args())
    print(json.dumps({
        "same_frame": result["registration"]["strict_same_frame"],
        "global_rgb_mae": result["global_only_metrics"]["global"]["R_to_T"]["rgb_mae"],
        "local_rgb_mae": result["global_plus_local_metrics"]["global"]["R_to_T"]["rgb_mae"],
        "artifacts": result["artifacts"],
    }, ensure_ascii=False, indent=2))

