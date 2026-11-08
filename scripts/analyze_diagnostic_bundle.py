#!/usr/bin/env python3
"""Measure same-source A/B/D/E1/E2/M evidence exported by XiaoSu Camera.

This is a Windows-side evidence tool. It does not emulate Core Image and does
not claim aesthetic success. Masks and candidate images must come from the
same diagnostic ZIP.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image


IMAGE_NAMES = {
    "A": "A_original.jpg",
    "B": "B_formal_output.jpg",
    "D": "D_automatic_diagnostic.jpg",
    "E1": "E1_spatial_emphasis.jpg",
    "E2": "E2_restrained_depth.jpg",
    "M": "M_manual_render.jpg",
}
MASK_NAMES = {
    "sky": "蒙版-天空.jpg",
    "ground": "蒙版-地面道路.jpg",
    "vegetation": "蒙版-植被.jpg",
    "architecture": "蒙版-建筑.jpg",
}


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def load_mask(path: Path, size: tuple[int, int]) -> np.ndarray:
    image = Image.open(path).convert("L").resize(size, Image.Resampling.BILINEAR)
    values = np.asarray(image, dtype=np.float32) / 255.0
    return values >= 0.35


def luminance(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def hsv(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    maximum = rgb.max(axis=-1)
    minimum = rgb.min(axis=-1)
    delta = maximum - minimum
    saturation = np.divide(delta, maximum, out=np.zeros_like(delta), where=maximum > 1e-6)
    hue = np.zeros_like(maximum)
    active = delta > 1e-6
    red = active & (maximum == rgb[..., 0])
    green = active & (maximum == rgb[..., 1])
    blue = active & (maximum == rgb[..., 2])
    hue[red] = ((rgb[..., 1][red] - rgb[..., 2][red]) / delta[red]) % 6
    hue[green] = ((rgb[..., 2][green] - rgb[..., 0][green]) / delta[green]) + 2
    hue[blue] = ((rgb[..., 0][blue] - rgb[..., 1][blue]) / delta[blue]) + 4
    return hue * 60.0, saturation, maximum


def boundary(mask: np.ndarray) -> np.ndarray:
    result = np.zeros_like(mask)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        result |= mask != np.roll(mask, shift=(dy, dx), axis=(0, 1))
    return result


def metric_set(rgb: np.ndarray, selected: np.ndarray | None = None) -> dict[str, Any]:
    y = luminance(rgb)
    hue, saturation, _ = hsv(rgb)
    if selected is None:
        selected = np.ones(y.shape, dtype=bool)
    if not np.any(selected):
        return {"coverage": 0.0}
    ys = y[selected]
    ss = saturation[selected]
    hs = hue[selected]
    gradients = (np.abs(np.diff(y, axis=0)).mean() + np.abs(np.diff(y, axis=1)).mean()) / 2
    return {
        "coverage": float(selected.mean()),
        "luminance_mean": float(ys.mean()),
        "luminance_p01": float(np.percentile(ys, 1)),
        "luminance_p05": float(np.percentile(ys, 5)),
        "luminance_p50": float(np.percentile(ys, 50)),
        "luminance_p95": float(np.percentile(ys, 95)),
        "luminance_p99": float(np.percentile(ys, 99)),
        "contrast_p05_p95": float(np.percentile(ys, 95) - np.percentile(ys, 5)),
        "shadow_ratio": float((ys < 0.12).mean()),
        "black_ratio": float((ys < 0.03).mean()),
        "highlight_ratio": float((ys > 0.85).mean()),
        "white_ratio": float((ys > 0.97).mean()),
        "saturation_mean": float(ss.mean()),
        "yellow_ratio": float(((hs >= 35) & (hs <= 75) & (ss >= 0.16)).mean()),
        "green_ratio": float(((hs > 75) & (hs <= 165) & (ss >= 0.14)).mean()),
        "gradient_energy_global": float(gradients),
    }


def neutral_metrics(source: np.ndarray, edited: np.ndarray) -> dict[str, float]:
    source_y = luminance(source)
    source_chroma = source.max(axis=-1) - source.min(axis=-1)
    neutral = (source_chroma < 0.075) & (source_y > 0.25) & (source_y < 0.96)
    white_neutral = neutral & (source_y > 0.65)
    result: dict[str, float] = {"neutral_coverage": float(neutral.mean())}
    for name, mask in (("neutral", neutral), ("white_neutral", white_neutral)):
        if not np.any(mask):
            continue
        edited_y = luminance(edited)
        edited_chroma = edited.max(axis=-1) - edited.min(axis=-1)
        result[f"{name}_luminance_shift"] = float((edited_y[mask] - source_y[mask]).mean())
        result[f"{name}_chroma_shift"] = float((edited_chroma[mask] - source_chroma[mask]).mean())
    return result


def halo_metrics(source: np.ndarray, edited: np.ndarray, masks: dict[str, np.ndarray]) -> dict[str, Any]:
    delta = np.abs(luminance(edited) - luminance(source))
    output: dict[str, Any] = {}
    for name, mask in masks.items():
        edge = boundary(mask)
        interior = mask & ~edge
        output[name] = {
            "boundary_mean_abs_luma_delta": float(delta[edge].mean()) if np.any(edge) else 0.0,
            "interior_mean_abs_luma_delta": float(delta[interior].mean()) if np.any(interior) else 0.0,
            "boundary_pixels": int(edge.sum()),
        }
    return output


def analyze(root: Path) -> dict[str, Any]:
    images_dir = root / "images"
    source = load_rgb(images_dir / IMAGE_NAMES["A"])
    height, width = source.shape[:2]
    images = {
        key: load_rgb(images_dir / name)
        for key, name in IMAGE_NAMES.items()
        if (images_dir / name).exists()
    }
    for key, image in images.items():
        if image.shape != source.shape:
            raise ValueError(f"{key} shape {image.shape} does not match A {source.shape}")
    masks = {
        key: load_mask(root / "masks" / name, (width, height))
        for key, name in MASK_NAMES.items()
    }

    candidates: dict[str, Any] = {}
    for key, image in images.items():
        entry: dict[str, Any] = {"full": metric_set(image)}
        entry["regions"] = {name: metric_set(image, mask) for name, mask in masks.items()}
        if key != "A":
            entry["neutral_protection"] = neutral_metrics(source, image)
            entry["halo_proxy"] = halo_metrics(source, image, masks)
            entry["rgb_mae"] = float(np.abs(image - source).mean())
            entry["changed_pixel_ratio_2_255"] = float(
                (np.abs(image - source).max(axis=-1) > (2.0 / 255.0)).mean()
            )
        candidates[key] = entry

    state_path = root / "evidence" / "candidate_states_and_parameters.json"
    state_records = json.loads(state_path.read_text(encoding="utf-8"))
    c_record = next((item for item in state_records if item.get("identifier") == "C"), {})
    c_image = images_dir / "C_reference_candidate.jpg"
    c_unavailable = "unavailable" in c_record.get("states", []) or bool(c_record.get("unavailable"))
    return {
        "source": {"width": width, "height": height, "root": str(root)},
        "mask_coverage": {name: float(mask.mean()) for name, mask in masks.items()},
        "c_export_contract": {
            "state_unavailable": c_unavailable,
            "image_present": c_image.exists(),
            "violation": bool(c_unavailable and c_image.exists()),
            "image_dimensions": list(Image.open(c_image).size) if c_image.exists() else None,
        },
        "candidates": candidates,
    }


def markdown(report: dict[str, Any], label: str) -> str:
    lines = [
        f"# {label} diagnostic pixel analysis",
        "",
        "> Windows evidence analysis only; this does not emulate Core Image or certify aesthetic quality.",
        "",
        f"Source: `{report['source']['root']}` ({report['source']['width']}×{report['source']['height']})",
        "",
        "|Candidate|Mean luma|P05–P95|Shadow|Highlight|Saturation|RGB MAE|",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for key in ("A", "B", "D", "E1", "E2", "M"):
        if key not in report["candidates"]:
            continue
        entry = report["candidates"][key]
        full = entry["full"]
        lines.append(
            f"|{key}|{full['luminance_mean']:.4f}|{full['contrast_p05_p95']:.4f}|"
            f"{full['shadow_ratio']:.4f}|{full['highlight_ratio']:.4f}|{full['saturation_mean']:.4f}|"
            f"{entry.get('rgb_mae', 0):.4f}|"
        )
    lines += ["", "## Region measurements", ""]
    for region in ("ground", "vegetation", "sky", "architecture"):
        lines += [f"### {region}", "", "|Candidate|Luma|Contrast|Saturation|Yellow|Green|", "|---|---:|---:|---:|---:|---:|"]
        for key in ("A", "B", "D", "E1", "E2", "M"):
            if key not in report["candidates"]:
                continue
            value = report["candidates"][key]["regions"][region]
            lines.append(
                f"|{key}|{value.get('luminance_mean', math.nan):.4f}|{value.get('contrast_p05_p95', math.nan):.4f}|"
                f"{value.get('saturation_mean', math.nan):.4f}|{value.get('yellow_ratio', math.nan):.4f}|"
                f"{value.get('green_ratio', math.nan):.4f}|"
            )
        lines.append("")
    contract = report["c_export_contract"]
    lines += [
        "## Export contract",
        "",
        f"C unavailable: `{contract['state_unavailable']}`; C image present: `{contract['image_present']}`; violation: `{contract['violation']}`.",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path, help="Extracted diagnostic bundle directory")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--label", default="Diagnostic bundle")
    args = parser.parse_args()
    report = analyze(args.bundle)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown(report, args.label), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
