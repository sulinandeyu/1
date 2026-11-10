#!/usr/bin/env python3
"""Render a Windows-only projection of PT-AESTHETIC-009.

The inference phase reads only A and the masks exported by the same iPhone
diagnostic run.  The optional professional target is opened *after* the output
has been written and is used only for evaluation.  This is not Core Image and
must never be reported as an iPhone rendering result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps


REGION_FILES = {
    "ground": "蒙版-地面道路.jpg",
    "vegetation": "蒙版-植被.jpg",
    "sky": "蒙版-天空.jpg",
    "architecture": "蒙版-建筑.jpg",
    "subject": "蒙版-显著性原始.jpg",
}


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def save_rgb(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.uint8(np.clip(image, 0, 1) * 255 + 0.5), "RGB").save(
        path, quality=95, subsampling=0
    )


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0, 1)
    return np.where(value <= 0.0031308, value * 12.92, 1.055 * value ** (1 / 2.4) - 0.055)


def luma(image: np.ndarray) -> np.ndarray:
    return image[..., 0] * 0.2126 + image[..., 1] * 0.7152 + image[..., 2] * 0.0722


def saturation(image: np.ndarray) -> np.ndarray:
    maximum = image.max(axis=-1)
    minimum = image.min(axis=-1)
    return np.divide(maximum - minimum, maximum, out=np.zeros_like(maximum), where=maximum > 1e-6)


def hue(image: np.ndarray) -> np.ndarray:
    red, green, blue = image[..., 0], image[..., 1], image[..., 2]
    maximum = image.max(axis=-1)
    minimum = image.min(axis=-1)
    delta = maximum - minimum
    result = np.zeros_like(maximum)
    valid = delta > 1e-6
    red_max = valid & (maximum == red)
    green_max = valid & (maximum == green)
    blue_max = valid & (maximum == blue)
    result[red_max] = np.mod((green[red_max] - blue[red_max]) / delta[red_max], 6)
    result[green_max] = (blue[green_max] - red[green_max]) / delta[green_max] + 2
    result[blue_max] = (red[blue_max] - green[blue_max]) / delta[blue_max] + 4
    return np.mod(result / 6, 1)


def load_masks(mask_dir: Path, size: tuple[int, int]) -> dict[str, np.ndarray]:
    width, height = size
    masks: dict[str, np.ndarray] = {}
    for name, filename in REGION_FILES.items():
        path = mask_dir / filename
        if not path.exists():
            continue
        masks[name] = np.asarray(
            Image.open(path).convert("L").resize((width, height), Image.Resampling.BILINEAR),
            dtype=np.float32,
        ) / 255.0
    # Match the iPhone regional path: non-subject adjustments exclude the
    # exported salient subject mask.  This is protection, not object identity.
    subject = masks.get("subject")
    if subject is not None:
        for name in ("ground", "vegetation", "sky", "architecture"):
            if name in masks:
                masks[name] *= 1 - subject
    return masks


def weighted_mean(values: np.ndarray, mask: np.ndarray) -> float:
    weight = float(mask.sum())
    return float((values * mask).sum() / max(weight, 1e-6))


def region_measurements(image: np.ndarray, masks: dict[str, np.ndarray]) -> dict[str, dict[str, float]]:
    lum = luma(image)
    sat = saturation(image)
    return {
        name: {
            "coverage": float(np.mean(mask)),
            "luminance": weighted_mean(lum, mask),
            "saturation": weighted_mean(sat, mask),
            "shadowRatio": weighted_mean((lum < 0.08).astype(np.float32), mask),
            "highlightRatio": weighted_mean((lum > 0.92).astype(np.float32), mask),
        }
        for name, mask in masks.items()
    }


def smooth_hue_band(h: np.ndarray, center: float, half_width: float) -> np.ndarray:
    distance = np.abs((h - center + 0.5) % 1.0 - 0.5)
    return np.clip(1 - distance / half_width, 0, 1) ** 2


def apply_masked_exposure(image: np.ndarray, mask: np.ndarray, ev: float) -> np.ndarray:
    linear = srgb_to_linear(image)
    adjusted = linear * np.float32(2.0**ev)
    return linear_to_srgb(adjusted * mask[..., None] + linear * (1 - mask[..., None]))


def apply_masked_saturation_band(
    image: np.ndarray, mask: np.ndarray, center: float, half_width: float, amount: float
) -> np.ndarray:
    h = hue(image)
    band = smooth_hue_band(h, center, half_width) * mask
    lum = luma(image)[..., None]
    adjusted = lum + (image - lum) * (1 + amount)
    return np.clip(adjusted * band[..., None] + image * (1 - band[..., None]), 0, 1)


def infer_from_source_only(source: np.ndarray, masks: dict[str, np.ndarray]) -> tuple[dict[str, float], dict]:
    before = region_measurements(source, masks)
    ground = before.get("ground")
    vegetation = before.get("vegetation")
    if ground is None or vegetation is None:
        return {}, {
            "status": "technical-continuity-no-reliable-hierarchy",
            "reason": "ground-or-vegetation-mask-missing",
            "parameters": {},
            "measurements": before,
        }

    # Mirrors PT-AESTHETIC-009 without reading a scene name or target image.
    luminance_dominance = np.clip(
        max(0.0, ground["luminance"] - vegetation["luminance"]) / 0.22, 0, 1
    )
    saturation_advantage = np.clip(
        max(0.0, vegetation["saturation"] - ground["saturation"]) / 0.25, 0, 1
    )
    coverage_balance = min(ground["coverage"], vegetation["coverage"]) / max(
        0.001, max(ground["coverage"], vegetation["coverage"])
    )
    # Exported masks have already passed the app's usable-mask gate.  The
    # projection records a conservative reliability rather than claiming to
    # reproduce the private Vision confidence calculation.
    exported_mask_reliability = 0.84
    global_shadow = float(np.mean(luma(source) < 0.08))
    noise_proxy = min(0.25, global_shadow * 1.7 + 0.06)
    noise_protection = max(0.22, 1 - noise_proxy * 2.8)
    evidence = float(
        (
            luminance_dominance * 0.36
            + saturation_advantage * 0.44
            + coverage_balance * 0.20
        )
        * exported_mask_reliability
        * noise_protection
    )
    active = evidence >= 0.28 and saturation_advantage >= 0.24 and luminance_dominance >= 0.16
    if not active:
        return {}, {
            "status": "technical-continuity-no-reliable-hierarchy",
            "reason": "measured-evidence-below-gate",
            "evidence": evidence,
            "parameters": {},
            "measurements": before,
        }

    target_delta = -float(np.clip(0.035 + evidence * 0.105, 0.035, 0.12))
    vegetation_target = float(np.clip(max(vegetation["luminance"] - 0.01, 0.545), 0.22, 0.62))
    ground_target = float(np.clip(vegetation_target + target_delta, 0.21, 0.62))
    ground_ev = float(np.clip(math.log2(ground_target / max(ground["luminance"], 0.02)), -0.58, 0.28))
    vegetation_ev = float(
        np.clip(math.log2(vegetation_target / max(vegetation["luminance"], 0.02)), -0.42, 0.25)
    )
    sky_ev = 0.0
    if "sky" in before:
        sky_target = float(np.clip(min(before["sky"]["luminance"], 0.90), 0.62, 0.90))
        sky_ev = float(
            np.clip(math.log2(sky_target / max(before["sky"]["luminance"], 0.02)), -0.32, 0.08)
        )
    yellow_presence = float(np.clip(vegetation["saturation"] / 0.35, 0, 1))
    yellow_saturation = float(
        np.clip(yellow_presence * max(0, 0.46 - vegetation["saturation"]) * 0.65, 0, 0.17)
    )

    parameters = {
        "ground.exposureEV": ground_ev,
        "vegetation.exposureEV": vegetation_ev,
        "vegetation.yellowSaturation": yellow_saturation,
        "sky.exposureEV": sky_ev,
    }
    return parameters, {
        "status": "measured-hierarchy-hypothesis-human-review-required",
        "targetImageReadDuringInference": False,
        "evidence": evidence,
        "inputs": {
            "luminanceDominance": float(luminance_dominance),
            "saturationAdvantage": float(saturation_advantage),
            "coverageBalance": float(coverage_balance),
            "exportedMaskReliability": exported_mask_reliability,
            "noiseProxy": noise_proxy,
        },
        "targets": {
            "groundMinusVegetationLuminance": target_delta,
            "groundLuminance": ground_target,
            "vegetationLuminance": vegetation_target,
        },
        "parameters": parameters,
        "measurements": before,
    }


def extract_old_d_parameters(bundle: Path, vegetation_saturation: float) -> dict[str, float]:
    evidence_path = bundle / "evidence" / "candidate_states_and_parameters.json"
    text = evidence_path.read_text(encoding="utf-8", errors="replace")
    result: dict[str, float] = {}
    patterns = {
        "ground.exposureEV": r"地面/道路：已执行（D 动态实测；[^）]*?EV=([+-]?\d+\.\d+)",
        "vegetation.exposureEV": r"植被：已执行（D 动态实测；[^）]*?EV=([+-]?\d+\.\d+)",
        "sky.exposureEV": r"天空：已执行（D 动态实测；[^）]*?EV=([+-]?\d+\.\d+)",
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            result[key] = float(match.group(1))
    separation = re.search(r"\[D\] 审美目标=.*?colorSeparation=(\d+\.\d+)", text)
    old_focus = float(separation.group(1)) if separation else 0.0
    saturation_headroom = float(np.clip((0.46 - vegetation_saturation) / 0.46, 0, 1))
    # Same current-photo formula used by the Swift regional planner.  This
    # estimates only the already-rendered D contribution so the projection can
    # add the delta instead of stacking the whole pipeline twice.
    result["vegetation.yellowSaturation"] = saturation_headroom * (
        0.06 + old_focus * 1.2 + 0.084
    )
    return result


def project_parameter_delta_on_actual_d(
    actual_old_d: np.ndarray,
    masks: dict[str, np.ndarray],
    old_parameters: dict[str, float],
    new_parameters: dict[str, float],
) -> tuple[np.ndarray, dict[str, float]]:
    output = actual_old_d.copy()
    deltas: dict[str, float] = {}
    for region in ("ground", "vegetation", "sky"):
        key = f"{region}.exposureEV"
        if region not in masks or key not in old_parameters or key not in new_parameters:
            continue
        delta = float(new_parameters[key] - old_parameters[key])
        # PT-AESTHETIC-009 changes the ground/vegetation relationship only;
        # sky remains the already-rendered D value in this experiment.
        if region == "sky":
            delta = 0.0
        deltas[key] = delta
        output = apply_masked_exposure(output, masks[region], delta)
    old_yellow = old_parameters.get("vegetation.yellowSaturation", 0.0)
    new_yellow = new_parameters.get("vegetation.yellowSaturation", 0.0)
    yellow_delta = max(0.0, new_yellow - old_yellow)
    deltas["vegetation.yellowSaturation"] = yellow_delta
    if "vegetation" in masks and yellow_delta > 1e-5:
        output = apply_masked_saturation_band(
            output, masks["vegetation"], center=0.155, half_width=0.09, amount=yellow_delta
        )
    return output, deltas


def image_metrics(source: np.ndarray, candidate: np.ndarray, masks: dict[str, np.ndarray]) -> dict:
    source_luma = luma(source)
    candidate_luma = luma(candidate)
    result = {
        "averageLuminance": float(candidate_luma.mean()),
        "contrastRange": float(np.quantile(candidate_luma, 0.95) - np.quantile(candidate_luma, 0.05)),
        "shadowRatio": float(np.mean(candidate_luma < 0.08)),
        "highlightRatio": float(np.mean(candidate_luma > 0.92)),
        "rgbMAEFromA": float(np.mean(np.abs(candidate - source))),
        "regions": region_measurements(candidate, masks),
    }
    neutral = (source_luma >= 0.18) & (source_luma <= 0.96) & ((source.max(-1) - source.min(-1)) <= 0.095)
    subject = masks.get("subject", np.zeros_like(source_luma)) >= 0.5
    architecture = masks.get("architecture", np.zeros_like(source_luma)) >= 0.5
    intentional = (
        (masks.get("ground", np.zeros_like(source_luma)) >= 0.5)
        | (masks.get("sky", np.zeros_like(source_luma)) >= 0.5)
    ) & ~(subject | architecture)
    protected = neutral & ~intentional
    intentional_neutral = neutral & intentional
    shift = candidate_luma - source_luma
    result["neutralAttribution"] = {
        "protectedCoverage": float(protected.mean()),
        "protectedMeanLuminanceShift": float(shift[protected].mean()) if protected.any() else 0,
        "intentionalToneCoverage": float(intentional_neutral.mean()),
        "intentionalToneMeanLuminanceShift": float(shift[intentional_neutral].mean()) if intentional_neutral.any() else 0,
        "thresholdUnchanged": -0.065,
    }
    return result


def make_contact_sheet(items: list[tuple[str, Path]], output: Path) -> None:
    images = [(label, ImageOps.contain(Image.open(path).convert("RGB"), (700, 940))) for label, path in items]
    width, height = 700, 990
    sheet = Image.new("RGB", (width * len(images), height), "#181818")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=24)
    for index, (label, image) in enumerate(images):
        x = index * width
        sheet.paste(image, (x + (width - image.width) // 2, 42))
        draw.text((x + 20, 10), label, fill="white", font=font)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, quality=92)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target", type=Path)
    parser.add_argument("--inverse", type=Path)
    args = parser.parse_args()

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    source_path = args.bundle / "images" / "A_original.jpg"
    old_d_path = args.bundle / "images" / "D_automatic_diagnostic.jpg"
    source = load_rgb(source_path)
    masks = load_masks(args.bundle / "masks", (source.shape[1], source.shape[0]))

    # Inference is deliberately completed and persisted before T is opened.
    old_d = load_rgb(old_d_path)
    new_parameters, evidence = infer_from_source_only(source, masks)
    old_parameters = extract_old_d_parameters(
        args.bundle,
        evidence.get("measurements", {}).get("vegetation", {}).get("saturation", 0.0),
    )
    projected, parameter_deltas = project_parameter_delta_on_actual_d(
        old_d, masks, old_parameters, new_parameters
    )
    evidence["projectionBase"] = "actual Build 33 D Core Image pixels; only newly solved parameter deltas are simulated"
    evidence["oldExecutedParameters"] = old_parameters
    evidence["projectedParameterDeltas"] = parameter_deltas
    projected_path = output / "D_new_windows_projection.jpg"
    save_rgb(projected_path, projected)
    evidence["sourceSHA256"] = sha256(source_path)
    evidence["outputSHA256"] = sha256(projected_path)
    evidence["renderingStatus"] = "windows_projection_not_core_image"
    evidence["quality"] = image_metrics(source, projected, masks)
    (output / "D_new_inference_evidence.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    candidates: list[tuple[str, Path]] = [
        ("A original", source_path),
        ("old D (Build 33 Core Image)", old_d_path),
        ("new D Windows projection", projected_path),
    ]
    evaluation: dict = {
        "newDWasRenderedBeforeTargetRead": True,
        "source": str(source_path),
        "oldD": str(old_d_path),
        "newD": str(projected_path),
        "metrics": {
            "A": image_metrics(source, source, masks),
            "oldD": image_metrics(source, load_rgb(old_d_path), masks),
            "newDWindowsProjection": image_metrics(source, projected, masks),
        },
    }

    if args.target and args.target.exists():
        target = load_rgb(args.target)
        evaluation["target"] = str(args.target)
        evaluation["targetSHA256"] = sha256(args.target)
        evaluation["metrics"]["T"] = image_metrics(source, target, masks)
        evaluation["targetComparison"] = {
            "oldD_RGB_MAE": float(np.mean(np.abs(load_rgb(old_d_path) - target))),
            "newD_RGB_MAE": float(np.mean(np.abs(projected - target))),
            "note": "Pixel fit is an engineering comparison, not an aesthetic score.",
        }
        candidates.append(("T registered target (evaluation only)", args.target))
    if args.inverse and args.inverse.exists():
        inverse = load_rgb(args.inverse)
        evaluation["inverseResearch"] = str(args.inverse)
        evaluation["metrics"]["inverseResearch"] = image_metrics(source, inverse, masks)
        candidates.append(("inverse research R (not auto D)", args.inverse))

    (output / "A_T_oldD_newD_R_metrics.json").write_text(
        json.dumps(evaluation, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    make_contact_sheet(candidates, output / "A_T_oldD_newD_R_contact_sheet.jpg")


if __name__ == "__main__":
    main()
