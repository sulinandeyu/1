from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from inverse_solver import (
    GLOBAL_NAMES,
    GLOBAL_NEUTRAL,
    LOCAL_NAMES,
    LOCAL_NEUTRAL,
    apply_local_controls,
    apply_measured_cool_cinematic_grade,
    read_image,
    region_metrics,
    render_global,
    sha256,
    write_image,
)


def encoded_rgb(path: Path) -> np.ndarray:
    return cv2.cvtColor(read_image(path), cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


def load_mask(path: Path, shape: tuple[int, int]) -> np.ndarray:
    mask = read_image(path, cv2.IMREAD_GRAYSCALE)
    if mask.shape != shape:
        mask = cv2.resize(mask, (shape[1], shape[0]), interpolation=cv2.INTER_LINEAR)
    return mask.astype(np.float32) / 255.0


def source_measurements(rgb: np.ndarray) -> dict[str, float]:
    hsv = cv2.cvtColor(rgb.astype(np.float32), cv2.COLOR_RGB2HSV)
    hue = hsv[..., 0] / 360.0
    saturation = hsv[..., 1]
    value = hsv[..., 2]
    luma = np.sum(rgb * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)
    warm = (hue >= 0.035) & (hue <= 0.19) & (saturation >= 0.20)
    green = (hue >= 0.20) & (hue <= 0.46) & (saturation >= 0.16)
    neutral = (saturation <= 0.12) & (value >= 0.18) & (value <= 0.96)
    return {
        "meanLuminance": float(luma.mean()),
        "p05": float(np.quantile(luma, 0.05)),
        "p50": float(np.quantile(luma, 0.50)),
        "p95": float(np.quantile(luma, 0.95)),
        "averageSaturation": float(saturation.mean()),
        "warmCoverage": float(warm.mean()),
        "greenCoverage": float(green.mean()),
        "neutralCoverage": float(neutral.mean()),
        "redAverage": float(rgb[..., 0].mean()),
        "greenAverage": float(rgb[..., 1].mean()),
        "blueAverage": float(rgb[..., 2].mean()),
    }


def measured_parameters(
    rgb: np.ndarray,
    masks: dict[str, np.ndarray],
    contains_person: bool,
) -> tuple[np.ndarray, np.ndarray, dict[str, float]]:
    """Solve a source-only diagnostic projection for a declared cool-cinematic intent.

    The aesthetic direction is explicit, but every magnitude is recomputed from
    current-image measurements. No filename, scene name, target image, target
    hash, inverse parameter or reference pixel is read here.
    """
    measured = source_measurements(rgb)
    portrait_scale = 0.22 if contains_person else 1.0
    mean = measured["meanLuminance"]
    dynamic_range = measured["p95"] - measured["p05"]
    neutral = measured["neutralCoverage"]
    warm = measured["warmCoverage"]
    green = measured["greenCoverage"]

    global_params = GLOBAL_NEUTRAL.copy()
    target_mean = float(np.clip(0.52 - max(0.0, mean - 0.54) * 0.30, 0.43, 0.52))
    exposure = math.log2(max(target_mean, 1e-4) / max(mean, 1e-4)) * 0.72
    global_params[0] = np.clip(exposure * portrait_scale, -0.42, 0.16)
    global_params[1] = np.clip((0.50 - mean) * 0.055 * portrait_scale, -0.025, 0.015)
    global_params[2] = np.clip(1.0 + (0.76 - dynamic_range) * 0.07 * portrait_scale, 0.98, 1.045)
    global_params[3] = np.clip(max(0.0, 0.018 - measured["p05"] * 0.12) * portrait_scale, 0.0, 0.018)
    global_params[4] = np.clip((0.10 - measured["p05"]) * 1.6 * portrait_scale, 0.0, 0.36)
    global_params[5] = np.clip((-0.045 - max(0.0, mean - 0.58) * 0.10) * portrait_scale, -0.075, 0.0)
    global_params[6] = np.clip((-0.038 - max(0.0, mean - 0.58) * 0.08) * portrait_scale, -0.065, 0.0)
    global_params[7] = np.clip(0.018 * portrait_scale, 0.0, 0.025)
    global_params[8] = np.clip((measured["p95"] - 0.86) * 1.7, 0.16, 0.58)
    global_params[9] = np.clip(0.985 - max(0.0, measured["p95"] - 0.94) * 0.25, 0.95, 0.99)
    global_params[10] = np.clip(1.0 - (0.018 + neutral * 0.035) * portrait_scale, 0.965, 1.0)
    if not contains_person:
        warm_headroom = max(0.0, 0.55 - measured["averageSaturation"])
        global_params[12] = np.clip(warm * warm_headroom * 0.34, 0.0, 0.14)
        global_params[13] = np.clip(-warm * 0.08, -0.035, 0.0)
        global_params[15] = np.clip(warm * warm_headroom * 0.48, 0.0, 0.20)
        global_params[16] = np.clip(-warm * 0.10, -0.045, 0.0)
        global_params[18] = np.clip(-green * 0.22, -0.10, 0.0)
        global_params[19] = np.clip(-green * 0.08, -0.04, 0.0)

    local_params = LOCAL_NEUTRAL.copy()
    region_luma: dict[str, float] = {}
    for region, mask in masks.items():
        active = mask > 0.45
        if np.any(active):
            luma = np.sum(rgb * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)
            region_luma[region] = float(luma[active].mean())
    ground = region_luma.get("ground")
    vegetation = region_luma.get("vegetation")
    if not contains_person and ground is not None and vegetation is not None:
        desired_ground = max(0.16, min(ground, vegetation - 0.055))
        local_params[0] = np.clip(math.log2(max(desired_ground, 1e-4) / max(ground, 1e-4)), -0.52, 0.08)
        local_params[1] = np.clip(1.0 + max(0.0, ground - desired_ground) * 0.16, 1.0, 1.08)
        local_params[2] = np.clip(1.0 - neutral * 0.05, 0.95, 1.0)
        local_params[3] = np.clip(max(0.0, desired_ground - vegetation) * 0.35, -0.04, 0.10)
        local_params[4] = np.clip(1.0 + max(0.0, 0.48 - vegetation) * 0.08, 1.0, 1.055)
        local_params[5] = np.clip(1.0 + warm * 0.08 - green * 0.03, 0.98, 1.07)
    sky = region_luma.get("sky")
    if sky is not None:
        local_params[6] = np.clip(max(0.0, 0.82 - sky) * 0.18 + 0.08, -0.05, 0.16)
        local_params[7] = 1.0
        local_params[8] = np.clip(1.0 - neutral * 0.06, 0.94, 1.0)
    architecture = region_luma.get("architecture")
    if architecture is not None:
        local_params[9] = np.clip((0.48 - architecture) * 0.12, -0.08, 0.06)
        local_params[10] = np.clip(1.0 + max(0.0, 0.55 - architecture) * 0.04, 1.0, 1.035)
        local_params[11] = np.clip(1.0 - neutral * 0.04, 0.96, 1.0)

    grade = {
        "intensity": 0.0 if contains_person else float(np.clip(0.24 + neutral * 0.28 + warm * 0.22, 0.04, 0.48)),
        "shadowCool": 0.0 if contains_person else float(np.clip(0.24 + neutral * 0.26, 0.02, 0.42)),
        "midtoneCool": 0.0 if contains_person else float(np.clip(0.16 + neutral * 0.20, 0.015, 0.30)),
        "highlightWarm": float(np.clip(warm * 0.06 * portrait_scale, 0.0, 0.025)),
        "neutralHighlightProtection": float(np.clip(0.72 + neutral * 0.24, 0.72, 0.92)),
        "colorContrast": float(np.clip((0.025 + warm * neutral * 0.12) * portrait_scale, 0.006, 0.065)),
    }
    return global_params, local_params, grade


def render_source_only(
    rgb: np.ndarray,
    masks: dict[str, np.ndarray],
    contains_person: bool,
) -> tuple[np.ndarray, dict[str, Any]]:
    global_params, local_params, grade = measured_parameters(rgb, masks, contains_person)
    rendered = render_global(rgb, global_params)
    rendered = apply_measured_cool_cinematic_grade(
        rendered,
        intensity=grade["intensity"],
        shadow_cool=grade["shadowCool"],
        midtone_cool=grade["midtoneCool"],
        highlight_warm=grade["highlightWarm"],
        neutral_highlight_protection=grade["neutralHighlightProtection"],
        color_contrast=grade["colorContrast"],
    )
    rendered = apply_local_controls(rendered, local_params, masks)
    evidence = {
        "targetAccessDuringSolve": False,
        "styleDirection": "cool-cinematic; magnitudes solved from current image measurements",
        "containsPersonProtection": contains_person,
        "measurements": source_measurements(rgb),
        "globalParameters": dict(zip(GLOBAL_NAMES, map(float, global_params))),
        "localParameters": dict(zip(LOCAL_NAMES, map(float, local_params))),
        "tonalColorGrade": grade,
        "rendererStatus": "windows_projection_not_core_image_acceptance",
    }
    return rendered, evidence


def image_metrics(source: np.ndarray, rendered: np.ndarray) -> dict[str, float]:
    source_luma = np.sum(source * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)
    rendered_luma = np.sum(rendered * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)
    return {
        "rgbMAEFromSource": float(np.mean(np.abs(rendered - source))),
        "sourceMeanLuminance": float(source_luma.mean()),
        "renderedMeanLuminance": float(rendered_luma.mean()),
        "sourceShadowClip": float((source_luma < 0.015).mean()),
        "renderedShadowClip": float((rendered_luma < 0.015).mean()),
        "sourceHighlightClip": float((source_luma > 0.985).mean()),
        "renderedHighlightClip": float((rendered_luma > 0.985).mean()),
    }


def contact_sheet(paths: list[tuple[str, Path]], output: Path) -> None:
    cells: list[tuple[str, Image.Image]] = []
    for label, path in paths:
        image = Image.open(path).convert("RGB")
        image.thumbnail((560, 760), Image.Resampling.LANCZOS)
        cells.append((label, image.copy()))
    canvas = Image.new("RGB", (len(cells) * 580, 820), "#171717")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=24)
    for index, (label, image) in enumerate(cells):
        x = index * 580 + 10
        canvas.paste(image, (x, 50))
        draw.text((x, 12), label, fill="white", font=font)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, quality=93)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--target", type=Path)
    parser.add_argument("--old-d", type=Path)
    parser.add_argument("--inverse-r", type=Path)
    parser.add_argument("--mask-ground", type=Path)
    parser.add_argument("--mask-vegetation", type=Path)
    parser.add_argument("--mask-sky", type=Path)
    parser.add_argument("--mask-architecture", type=Path)
    parser.add_argument("--contains-person", action="store_true")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    source = encoded_rgb(args.source)
    shape = source.shape[:2]
    masks: dict[str, np.ndarray] = {}
    for region in ("ground", "vegetation", "sky", "architecture"):
        path = getattr(args, f"mask_{region}")
        if path:
            masks[region] = load_mask(path, shape)
    rendered, evidence = render_source_only(source, masks, args.contains_person)
    # This is an isolated diagnostic projection.  It must never be labelled B:
    # B is the shipping algorithm and is deliberately unchanged by this work.
    output_image = args.output / "new_auto_diagnostic_windows_projection.jpg"
    write_image(output_image, cv2.cvtColor((rendered * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
    evidence["source"] = {"path": str(args.source), "sha256": sha256(args.source)}
    evidence["output"] = str(output_image)
    evidence["sourceRelativeMetrics"] = image_metrics(source, rendered)

    valid = np.ones(shape, bool)
    if args.target:
        target = encoded_rgb(args.target)
        if target.shape != source.shape:
            target = cv2.resize(target, (shape[1], shape[0]), interpolation=cv2.INTER_AREA)
        evidence["postSolveTargetEvaluation"] = region_metrics(source, target, rendered, valid, masks)
    (args.output / "experiment_evidence.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    sheet_paths = [("A source", args.source)]
    if args.target:
        sheet_paths.append(("T reference (evaluation only)", args.target))
    if args.old_d:
        sheet_paths.append(("Build 36 old D (iPhone Core Image)", args.old_d))
    sheet_paths.append(("New auto diagnostic (Windows projection)", output_image))
    if args.inverse_r:
        sheet_paths.append(("A/T inverse R3-W (capability)", args.inverse_r))
    contact_sheet(sheet_paths, args.output / "A_T_oldD_newAuto_R3W_contact.jpg")


if __name__ == "__main__":
    main()
