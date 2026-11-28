#!/usr/bin/env python3
"""Generate deterministic, redistributable PT-LEARN-007 renderer fixtures.

The fixture contains only programmatic pixels and masks.  It mirrors the
encoded-sRGB mathematics used by the existing Core Image RGB-curve, HSL and
three-way grading operators, then applies the ORACLE regional EV/contrast/
saturation controls in linear light.  It never reads the private autumn photo
or its target.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

import numpy as np

ANCHORS = np.array([0.0, 0.08, 0.22, 0.50, 0.72, 0.90, 1.0], np.float32)
HUE_CENTERS = np.array([0.0, 0.075, 0.155, 0.33, 0.50, 0.64, 0.755, 0.89], np.float32)
HUE_WIDTHS = np.array([0.095, 0.095, 0.09, 0.13, 0.10, 0.13, 0.105, 0.115], np.float32)


def srgb_to_linear(v: np.ndarray) -> np.ndarray:
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(v: np.ndarray) -> np.ndarray:
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.maximum(v, 1e-8) ** (1 / 2.4) - 0.055)


def curve(rgb: np.ndarray, outputs: np.ndarray, intensity: float = 1.0) -> np.ndarray:
    effective = ANCHORS + (outputs - ANCHORS) * intensity
    return np.stack([np.interp(rgb[..., c], ANCHORS, effective[c] if effective.ndim == 2 else effective)
                     for c in range(3)], axis=-1).astype(np.float32)


def color_cube(transform, linear: np.ndarray, dimension: int = 32) -> np.ndarray:
    """Mirror Core Image's 32^3 CIColorCube sampling in linear working RGB.

    The Swift operators build a finite linear-RGB lattice, then Core Image
    trilinearly interpolates it.  Evaluating the analytic transform directly
    is not a platform consistency reference because it omits that deliberate
    production approximation.
    """
    axis = np.linspace(0, 1, dimension, dtype=np.float32)
    red, green, blue = np.meshgrid(axis, axis, axis, indexing="ij")
    lattice_input = np.stack([red, green, blue], axis=-1)
    lattice = transform(lattice_input).astype(np.float32)

    bounded = np.clip(linear, 0, 1)
    position = bounded * np.float32(dimension - 1)
    lower = np.floor(position).astype(np.int32)
    upper = np.minimum(lower + 1, dimension - 1)
    fraction = position - lower

    r0, g0, b0 = lower[..., 0], lower[..., 1], lower[..., 2]
    r1, g1, b1 = upper[..., 0], upper[..., 1], upper[..., 2]
    fr, fg, fb = fraction[..., 0:1], fraction[..., 1:2], fraction[..., 2:3]
    c000 = lattice[r0, g0, b0]
    c100 = lattice[r1, g0, b0]
    c010 = lattice[r0, g1, b0]
    c110 = lattice[r1, g1, b0]
    c001 = lattice[r0, g0, b1]
    c101 = lattice[r1, g0, b1]
    c011 = lattice[r0, g1, b1]
    c111 = lattice[r1, g1, b1]
    c00 = c000 * (1 - fr) + c100 * fr
    c10 = c010 * (1 - fr) + c110 * fr
    c01 = c001 * (1 - fr) + c101 * fr
    c11 = c011 * (1 - fr) + c111 * fr
    c0 = c00 * (1 - fg) + c10 * fg
    c1 = c01 * (1 - fg) + c11 * fg
    transformed = c0 * (1 - fb) + c1 * fb
    # ExtendedRangeColorCube restores samples outside the cube domain.
    return transformed + linear - bounded


def rgb_to_hsl(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn
    l = (mx + mn) * 0.5
    s = np.where(d > 1e-6, d / np.maximum(1 - np.abs(2 * l - 1), 1e-6), 0)
    h = np.zeros_like(l)
    valid = d > 1e-6
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mr, mg, mb = valid & (mx == r), valid & (mx == g), valid & (mx == b)
    h[mr] = np.mod((g[mr] - b[mr]) / d[mr], 6)
    h[mg] = (b[mg] - r[mg]) / d[mg] + 2
    h[mb] = (r[mb] - g[mb]) / d[mb] + 4
    return np.mod(h / 6, 1), np.clip(s, 0, 1), np.clip(l, 0, 1)


def hsl_to_rgb(h: np.ndarray, s: np.ndarray, l: np.ndarray) -> np.ndarray:
    c = (1 - np.abs(2 * l - 1)) * s
    q = np.mod(h, 1) * 6
    x = c * (1 - np.abs(np.mod(q, 2) - 1))
    z = np.zeros_like(c)
    choices = np.stack([
        np.stack([c, x, z], -1), np.stack([x, c, z], -1),
        np.stack([z, c, x], -1), np.stack([z, x, c], -1),
        np.stack([x, z, c], -1), np.stack([c, z, x], -1),
    ], -2)
    idx = (np.floor(q).astype(np.int32) % 6)[..., None, None]
    selected = np.take_along_axis(choices, np.repeat(idx, 3, -1), axis=-2)[..., 0, :]
    return np.clip(selected + (l - c * 0.5)[..., None], 0, 1)


def smoothstep(a: float, b: float, v: np.ndarray) -> np.ndarray:
    x = np.clip((v - a) / max(b - a, 1e-6), 0, 1)
    return x * x * (3 - 2 * x)


def apply_hsl(rgb: np.ndarray, values: np.ndarray) -> np.ndarray:
    h, s, l = rgb_to_hsl(rgb)
    dist = np.minimum(np.abs(h[..., None] - HUE_CENTERS), 1 - np.abs(h[..., None] - HUE_CENTERS))
    w = np.clip(1 - dist / HUE_WIDTHS, 0, 1)
    w = w * w * (3 - 2 * w)
    guard = np.clip((rgb.max(-1) - rgb.min(-1)) / 0.12, 0, 1)
    h = np.mod(h + (w * values[:, 0]).sum(-1) * guard, 1)
    s = np.clip(s * (1 + (w * values[:, 1]).sum(-1) * guard), 0, 1)
    l = np.clip(l + (w * values[:, 2]).sum(-1) * guard, 0, 1)
    return hsl_to_rgb(h, s, l)


def apply_grade(rgb: np.ndarray, grade: np.ndarray) -> np.ndarray:
    y = (rgb * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(-1)
    chroma = rgb.max(-1) - rgb.min(-1)
    cg = np.clip(chroma / 0.18, 0, 1)
    neutral = 0.18 + 0.82 * cg
    highlight_neutral = 1 - 0.90 * (1 - cg) * smoothstep(0.68, 0.96, y)
    sw = 1 - smoothstep(0.12, 0.50, y)
    hw = smoothstep(0.55, 0.92, y)
    mw = np.clip(1 - sw - hw, 0, 1)
    lum = grade @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    chromatic = grade - lum[:, None]
    delta = (sw[..., None] * chromatic[0] + mw[..., None] * chromatic[1]
             + hw[..., None] * chromatic[2] * highlight_neutral[..., None])
    return np.clip(rgb + delta * neutral[..., None], 0, 1)


def color_controls(linear: np.ndarray, contrast: float, saturation: float) -> np.ndarray:
    # CIColorControls is evaluated in the Core Image working space.  This is the
    # documented affine contrast/saturation reference used for comparison; the
    # Apple test reports the measured residual instead of assuming equality.
    luma = (linear * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(-1, keepdims=True)
    out = luma + (linear - luma) * saturation
    return np.clip((out - 0.5) * contrast + 0.5, 0, 1)


def render(encoded: np.ndarray, masks: dict[str, np.ndarray], p: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    linear = srgb_to_linear(encoded) * (2.0 ** p["exposure_ev"])
    master = np.array(p["master_curve"], np.float32)
    linear = color_cube(
        lambda value: srgb_to_linear(curve(linear_to_srgb(value), master)),
        linear,
    )
    rgb_curves = np.array(p["rgb_curves"], np.float32)
    linear = color_cube(
        lambda value: srgb_to_linear(curve(linear_to_srgb(value), rgb_curves, p["rgb_intensity"])),
        linear,
    )
    hsl = np.array(p["hsl"], np.float32)
    linear = color_cube(
        lambda value: srgb_to_linear(apply_hsl(linear_to_srgb(value), hsl)),
        linear,
    )
    tonal_grade = np.array(p["tonal_grade"], np.float32)
    linear = color_cube(
        lambda value: srgb_to_linear(apply_grade(linear_to_srgb(value), tonal_grade)),
        linear,
    )
    global_out = linear_to_srgb(linear)
    exposure_only = linear.copy()
    for region in p["regional"]:
        mask = masks[region["region"]][..., None]
        adjusted = exposure_only * (2.0 ** region["exposure_ev"])
        exposure_only = adjusted * mask + exposure_only * (1 - mask)
    for region in p["regional"]:
        mask = masks[region["region"]][..., None]
        adjusted = linear * (2.0 ** region["exposure_ev"])
        adjusted = color_controls(adjusted, region["contrast"], region["saturation"])
        linear = adjusted * mask + linear * (1 - mask)
    return global_out, linear_to_srgb(exposure_only), linear_to_srgb(linear)


def programmatic_input(width: int, height: int) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    x = np.linspace(0, 1, width, dtype=np.float32)[None, :]
    y = np.linspace(0, 1, height, dtype=np.float32)[:, None]
    image = np.stack([
        np.broadcast_to(x, (height, width)),
        np.broadcast_to(0.12 + 0.76 * y, (height, width)),
        np.clip(0.08 + 0.72 * (1 - x) * (0.35 + 0.65 * y), 0, 1),
    ], -1)
    # Add exact neutrals and the eight hue families.
    patches = np.array([[.18,.18,.18],[.50,.50,.50],[.88,.88,.88],[.8,.12,.12],
                        [.9,.42,.08],[.86,.78,.08],[.10,.65,.16],[.08,.68,.68],
                        [.10,.25,.85],[.48,.12,.78],[.82,.10,.58]], np.float32)
    patch_w = max(2, width // len(patches))
    for i, value in enumerate(patches):
        image[: max(2, height // 5), i * patch_w:min(width, (i + 1) * patch_w)] = value
    feather = max(1.0, width * 0.006)
    xx, yy = np.meshgrid(np.arange(width), np.arange(height))
    logistic = lambda z: 1 / (1 + np.exp(-z / feather))
    masks = {
        "ground": logistic(yy - height * .52),
        "vegetation": logistic(height * .48 - yy),
        "sky": logistic(width * .30 - xx) * logistic(height * .36 - yy),
        "architecture": logistic(xx - width * .70) * logistic(yy - height * .30),
    }
    return image, {k: v.astype(np.float32) for k, v in masks.items()}


def encode_u8(value: np.ndarray) -> str:
    return base64.b64encode(np.rint(np.clip(value, 0, 1) * 255).astype(np.uint8).tobytes()).decode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    params = {
        "exposure_ev": -0.4078526,
        "master_curve": [0,.0340664,.091884,.312438,.613086,.885867,1],
        "rgb_curves": [[0,.0482327,.185986,.387044,.658897,.876494,1],
                       [0,.0470563,.138933,.361801,.612413,.895097,1],
                       [0,.0463718,.133347,.460457,.725716,.899657,1]],
        "rgb_intensity": .543546,
        "hsl": [[.05275,-.27372,-.07278],[.002145,.14613,.009685],[-.032779,.175332,.042585],
                [-.044445,-.35,-.180607],[.067792,-.114659,-.131103],[.018052,-.239244,-.211707],
                [-.072289,.336885,-.119446],[.064676,-.245225,-.003323]],
        "tonal_grade": [[.004843,.002363,-.000525],[.048057,.021405,-.057065],[.011989,-.009144,-.003002]],
        "regional": [
            {"region":"ground","exposure_ev":-.890257,"contrast":1.229293,"saturation":1.3},
            {"region":"vegetation","exposure_ev":.5,"contrast":.987537,"saturation":.988411},
            {"region":"sky","exposure_ev":.302217,"contrast":1.044689,"saturation":.728079},
            {"region":"architecture","exposure_ev":-.043572,"contrast":.964028,"saturation":1.008152},
        ],
    }
    width, height = 64, 32
    source, masks = programmatic_input(width, height)
    # CIImage receives the fixture as encoded 8-bit sRGB; calculate the
    # reference from those exact bytes rather than the pre-quantized floats.
    source = np.rint(np.clip(source, 0, 1) * 255).astype(np.uint8).astype(np.float32) / 255
    global_out, regional_exposure_only, final_out = render(source, masks, params)
    payload = {
        "schema_version": 1,
        "rule_id": "PT-LEARN-007",
        "fixture_kind": "programmatic_no_private_pixels",
        "color_contract": {"input":"encoded-sRGB-u8","working":"extended-linear-sRGB","output":"encoded-sRGB-u8"},
        "operator_order": ["linear_exposure","encoded_master_curve","encoded_rgb_curves","perceptual_hsl","three_way_grade","regional_linear_adjustments"],
        "width": width, "height": height, "channels": 3,
        "parameters": params,
        "input_rgb_base64": encode_u8(source),
        "windows_global_rgb_base64": encode_u8(global_out),
        "windows_regional_exposure_only_rgb_base64": encode_u8(regional_exposure_only),
        "windows_final_rgb_base64": encode_u8(final_out),
        "masks_float32_base64": {k: base64.b64encode(v.tobytes()).decode("ascii") for k,v in masks.items()},
        "known_platform_boundaries": [
            "the Windows reference explicitly mirrors CIColorCube's 32^3 lattice and trilinear sampling",
            "CIColorControls is an Apple operator; the Windows regional contrast/saturation expression is a documented approximation",
            "the current production manual recipe has no arbitrary seven-anchor master-curve field, so this fixture applies the existing RGB processor twice in the isolated Apple test"
        ]
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
