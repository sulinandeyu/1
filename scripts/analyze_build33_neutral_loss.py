#!/usr/bin/env python3
"""Localize Build 33 neutral-luminance loss by real semantic region.

This is a Windows evidence tool.  It mirrors the source-pixel neutral sample
definition used by ``QualityCheckService`` (luma 0.18...0.96, RGB chroma <=
0.095), but evaluates the full-resolution export and attributes the samples to
the masks exported by the same iPhone diagnostic run.  It does not emulate
Core Image and it does not turn a technical measurement into an aesthetic
verdict.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


IMAGE_FILES = {
    "A": "A_original.jpg",
    "B": "B_formal_output.jpg",
    "D": "D_automatic_diagnostic.jpg",
    "E1": "E1_spatial_emphasis.jpg",
    "E2": "E2_restrained_depth.jpg",
    "M": "M_manual_render.jpg",
}

MASK_FILES = {
    "subject": "蒙版-显著性原始.jpg",
    "sky": "蒙版-天空.jpg",
    "ground": "蒙版-地面道路.jpg",
    "vegetation": "蒙版-植被.jpg",
    "architecture": "蒙版-建筑.jpg",
}


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def load_mask(path: Path, size: tuple[int, int]) -> np.ndarray:
    image = Image.open(path).convert("L").resize(size, Image.Resampling.BILINEAR)
    return np.asarray(image, dtype=np.float32) / 255.0 >= 0.35


def luma(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def distribution(values: np.ndarray) -> dict[str, float | int]:
    if values.size == 0:
        return {"pixels": 0}
    return {
        "pixels": int(values.size),
        "mean": float(values.mean()),
        "p01": float(np.percentile(values, 1)),
        "p05": float(np.percentile(values, 5)),
        "p50": float(np.percentile(values, 50)),
        "p95": float(np.percentile(values, 95)),
        "p99": float(np.percentile(values, 99)),
        "fraction_below_minus_0_065": float((values < -0.065).mean()),
        "fraction_below_minus_0_12": float((values < -0.12).mean()),
    }


def analyze_candidate(
    source: np.ndarray,
    candidate: np.ndarray,
    neutral: np.ndarray,
    masks: dict[str, np.ndarray],
) -> dict[str, object]:
    source_y = luma(source)
    candidate_y = luma(candidate)
    shift = candidate_y - source_y
    result: dict[str, object] = {
        "full_neutral": distribution(shift[neutral]),
        "neutral_coverage": float(neutral.mean()),
        "regions": {},
    }

    assigned = np.zeros(neutral.shape, dtype=bool)
    # Subject is first because it is the only exported proxy for a visually
    # important object.  The remaining masks may overlap at soft boundaries.
    for name in ("subject", "sky", "ground", "vegetation", "architecture"):
        selected = neutral & masks[name]
        result["regions"][name] = {
            "neutral_coverage_of_frame": float(selected.mean()),
            "neutral_fraction_in_region": float(selected.sum() / max(1, masks[name].sum())),
            "shift": distribution(shift[selected]),
        }
        assigned |= selected
    other = neutral & ~assigned
    result["regions"]["unassigned"] = {
        "neutral_coverage_of_frame": float(other.mean()),
        "shift": distribution(shift[other]),
    }

    # Bright neutral pixels are the high-risk proxy for white cars, lamps and
    # pale architecture.  This is deliberately reported separately from gray
    # road and sky; it is not a semantic vehicle detector.
    bright = neutral & (source_y >= 0.65)
    middle = neutral & (source_y >= 0.30) & (source_y < 0.65)
    result["bright_neutral"] = distribution(shift[bright])
    result["midtone_neutral"] = distribution(shift[middle])
    return result


def overlay_loss(
    source: np.ndarray,
    shift: np.ndarray,
    neutral: np.ndarray,
    masks: dict[str, np.ndarray],
) -> Image.Image:
    base = np.clip(source * 0.42 + 0.08, 0, 1)
    loss = neutral & (shift < -0.065)
    severe = neutral & (shift < -0.12)
    base[loss] = base[loss] * 0.30 + np.array([0.75, 0.12, 0.04], dtype=np.float32)
    base[severe] = base[severe] * 0.18 + np.array([0.92, 0.04, 0.02], dtype=np.float32)

    # Show the exported subject proxy in cyan to reveal whether the neutral
    # failure overlaps a visually important object.
    subject_edge = masks["subject"] ^ np.roll(masks["subject"], 1, axis=0)
    subject_edge |= masks["subject"] ^ np.roll(masks["subject"], 1, axis=1)
    base[subject_edge] = np.array([0.0, 1.0, 1.0], dtype=np.float32)
    return Image.fromarray(np.uint8(np.clip(base, 0, 1) * 255), mode="RGB")


def make_contact_sheet(
    items: list[tuple[str, Path]],
    output: Path,
    width: int = 540,
) -> None:
    cells: list[tuple[str, Image.Image]] = []
    for label, path in items:
        image = Image.open(path).convert("RGB")
        height = round(image.height * width / image.width)
        cells.append((label, image.resize((width, height), Image.Resampling.LANCZOS)))
    label_height = 42
    cell_height = max(image.height for _, image in cells) + label_height
    sheet = Image.new("RGB", (width * len(cells), cell_height), "#161616")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=22)
    for index, (label, image) in enumerate(cells):
        x = index * width
        sheet.paste(image, (x, label_height))
        draw.text((x + 12, 9), label, fill="white", font=font)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, quality=94)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--target", type=Path)
    parser.add_argument("--inverse", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    images_dir = args.bundle / "images"
    source = load_rgb(images_dir / IMAGE_FILES["A"])
    height, width = source.shape[:2]
    source_y = luma(source)
    source_chroma = source.max(axis=-1) - source.min(axis=-1)
    neutral = (
        (source_y >= 0.18)
        & (source_y <= 0.96)
        & (source_chroma <= 0.095)
    )
    masks = {
        name: load_mask(args.bundle / "masks" / filename, (width, height))
        for name, filename in MASK_FILES.items()
    }

    report: dict[str, object] = {
        "schema": 1,
        "source_dimensions": [width, height],
        "definition": {
            "neutral_source_luminance": [0.18, 0.96],
            "neutral_source_rgb_chroma_max": 0.095,
            "failure_threshold_mean_shift": -0.065,
            "note": "Full-resolution evidence; Swift production QC samples a 112px-wide Core Image render.",
        },
        "mask_coverage": {name: float(mask.mean()) for name, mask in masks.items()},
        "candidates": {},
    }

    args.output.mkdir(parents=True, exist_ok=True)
    for identifier, filename in IMAGE_FILES.items():
        path = images_dir / filename
        if not path.exists() or identifier == "A":
            continue
        candidate = load_rgb(path)
        report["candidates"][identifier] = analyze_candidate(source, candidate, neutral, masks)
        shift = luma(candidate) - source_y
        overlay_loss(source, shift, neutral, masks).save(
            args.output / f"{identifier}_neutral_loss_map.jpg", quality=94
        )

    (args.output / "neutral_loss_attribution.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    contact_items = [
        ("A original", images_dir / IMAGE_FILES["A"]),
        ("B formal", images_dir / IMAGE_FILES["B"]),
        ("D Build 33", images_dir / IMAGE_FILES["D"]),
    ]
    if args.target and args.target.exists():
        contact_items.append(("T registered reference", args.target))
    if args.inverse and args.inverse.exists():
        contact_items.append(("R inverse render", args.inverse))
    make_contact_sheet(contact_items, args.output / "A_B_D_T_R_contact_sheet.jpg")

    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
