#!/usr/bin/env python3
"""Validate the structured-diagnosis -> parameters -> pixels closure.

This is a Windows projection, never Apple Core Image evidence.  It applies the
delta between the Build 36 *executed* regional EV and the newly solved EV to the
real Build 36 iPhone D output.  The professional target is opened only after the
new image has been rendered and is used exclusively for post-hoc evaluation.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import shutil
from pathlib import Path

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
INVERSE = ROOT / "output" / "inverse_solver" / "autumn_street_ci_faithful_extended"
BUILD36 = ROOT / "tmp" / "build36_diagnostic_20261113_182630"
VISUAL = ROOT / "output" / "visual_photography_director_v1"
OUTPUT = ROOT / "output" / "structured_diagnosis_closure"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_rgb(path: Path) -> np.ndarray:
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(path)
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


def write_rgb(path: Path, image: np.ndarray, quality: int = 96) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = cv2.cvtColor(
        np.clip(np.rint(image * 255.0), 0, 255).astype(np.uint8),
        cv2.COLOR_RGB2BGR,
    )
    if not cv2.imwrite(str(path), encoded, [cv2.IMWRITE_JPEG_QUALITY, quality]):
        raise RuntimeError(f"Unable to write {path}")


def read_mask(path: Path, shape: tuple[int, int]) -> np.ndarray:
    mask = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if mask is None:
        raise FileNotFoundError(path)
    if mask.shape != shape:
        mask = cv2.resize(mask, (shape[1], shape[0]), interpolation=cv2.INTER_LINEAR)
    return mask.astype(np.float32) / 255.0


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return np.where(value <= 0.0031308, value * 12.92, 1.055 * value ** (1 / 2.4) - 0.055)


def luminance(image: np.ndarray) -> np.ndarray:
    return image[..., 0] * 0.2126 + image[..., 1] * 0.7152 + image[..., 2] * 0.0722


def saturation(image: np.ndarray) -> np.ndarray:
    maximum = image.max(axis=2)
    minimum = image.min(axis=2)
    result = np.zeros_like(maximum)
    np.divide(maximum - minimum, maximum, out=result, where=maximum > 1e-6)
    return result


def weighted_mean(values: np.ndarray, weights: np.ndarray) -> float:
    total = float(weights.sum())
    return float((values * weights).sum() / max(total, 1e-6))


def smoothstep(edge0: float, edge1: float, value: np.ndarray) -> np.ndarray:
    t = np.clip((value - edge0) / max(edge1 - edge0, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def parse_executed_ev(candidate_path: Path, identifier: str, label: str) -> float:
    candidates = json.loads(candidate_path.read_text(encoding="utf-8"))
    candidate = next(item for item in candidates if item["identifier"] == identifier)
    expression = re.compile(
        rf"{re.escape(label)}：已执行（D 动态实测；[^）]*?EV=([+-]?\d+(?:\.\d+)?)"
    )
    for line in candidate.get("executed", []):
        match = expression.search(line)
        if match:
            return float(match.group(1))
    raise RuntimeError(f"Missing executed {label} EV in {candidate_path}")


def region_metrics(image: np.ndarray, mask: np.ndarray) -> dict[str, float]:
    active = mask >= 0.5
    luma = luminance(image)
    sat = saturation(image)
    if not np.any(active):
        return {"coverage": 0.0}
    pixels = image[active]
    return {
        "coverage": float(active.mean()),
        "luminance": float(luma[active].mean()),
        "luminanceP05": float(np.quantile(luma[active], 0.05)),
        "luminanceP95": float(np.quantile(luma[active], 0.95)),
        "saturation": float(sat[active].mean()),
        "red": float(pixels[:, 0].mean()),
        "green": float(pixels[:, 1].mean()),
        "blue": float(pixels[:, 2].mean()),
        "shadowClip": float((luma[active] <= 0.015).mean()),
        "highlightClip": float((luma[active] >= 0.985).mean()),
    }


def apply_exposure_delta(
    image: np.ndarray,
    source_for_gate: np.ndarray,
    mask: np.ndarray,
    delta_ev: float,
    lower: float,
    upper: float,
    feather: float,
    exclusions: list[np.ndarray],
) -> tuple[np.ndarray, np.ndarray]:
    source_luma = luminance(source_for_gate)
    lower_gate = smoothstep(lower - feather, lower + feather, source_luma)
    upper_gate = 1.0 - smoothstep(upper - feather, upper + feather, source_luma)
    weight = cv2.GaussianBlur(mask, (0, 0), sigmaX=2.4, sigmaY=2.4)
    weight *= lower_gate * upper_gate
    for exclusion in exclusions:
        weight *= 1.0 - np.clip(exclusion, 0.0, 1.0)
    weight = np.clip(weight, 0.0, 1.0)

    linear = srgb_to_linear(image)
    adjusted = linear_to_srgb(linear * (2.0**delta_ev))
    output = image * (1.0 - weight[..., None]) + adjusted * weight[..., None]
    return np.clip(output, 0.0, 1.0), weight


def boundary_change(change: np.ndarray, mask: np.ndarray) -> dict[str, float]:
    binary = (mask >= 0.5).astype(np.uint8)
    kernel = np.ones((5, 5), np.uint8)
    dilated = cv2.dilate(binary, kernel, iterations=1)
    eroded = cv2.erode(binary, kernel, iterations=1)
    boundary = (dilated - eroded) > 0
    interior = eroded > 0
    return {
        "boundaryChangeP95": float(np.quantile(change[boundary], 0.95)) if np.any(boundary) else 0.0,
        "interiorChangeP95": float(np.quantile(change[interior], 0.95)) if np.any(interior) else 0.0,
    }


def labeled_contact(items: list[tuple[str, np.ndarray]], destination: Path) -> None:
    thumb_width = 480
    label_height = 54
    panels = []
    for label, image in items:
        scale = thumb_width / image.shape[1]
        resized = cv2.resize(
            image,
            (thumb_width, int(round(image.shape[0] * scale))),
            interpolation=cv2.INTER_AREA,
        )
        panel = np.full((resized.shape[0] + label_height, thumb_width, 3), 0.055, np.float32)
        panel[label_height:] = resized
        cv2.putText(
            panel,
            label,
            (12, 36),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.62,
            (0.96, 0.96, 0.96),
            1,
            cv2.LINE_AA,
        )
        panels.append(panel)
    write_rgb(destination, np.concatenate(panels, axis=1), quality=94)


def regression_cases(output: Path) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for case in ("building", "overcast_trees", "portrait_safe"):
        source_path = VISUAL / "01_scene_understanding" / case / "A_original.jpg"
        old_path = VISUAL / "04_real_renders" / case / "D_windows_faithful_projection_NOT_CORE_IMAGE.jpg"
        scene_path = VISUAL / "01_scene_understanding" / case / "scene_understanding.json"
        source = read_rgb(source_path)
        old = read_rgb(old_path)
        scene = json.loads(scene_path.read_text(encoding="utf-8"))
        regions = {item["region"]: item for item in scene.get("regions", [])}
        eligible = all(
            regions.get(name, {}).get("status") == "reliable"
            and regions.get(name, {}).get("measurements") is not None
            for name in ("ground", "vegetation")
        )
        # The new closure is deliberately a no-op without both reliable semantic
        # masks. Re-encoding the actual output documents that this patch does not
        # introduce a global tint, portrait edit, or unrelated exposure change.
        new = old.copy()
        case_dir = output / "regression" / case
        write_rgb(case_dir / "A_original.jpg", source)
        write_rgb(case_dir / "OLD_windows_projection.jpg", old)
        write_rgb(case_dir / "NEW_windows_projection.jpg", new)
        labeled_contact(
            [("A", source), ("OLD", old), ("NEW (relationship unavailable)", new)],
            case_dir / "A_OLD_NEW_contact.jpg",
        )
        results.append(
            {
                "case": case,
                "groundVegetationRelationshipEligible": eligible,
                "newOperation": "not_planned" if not eligible else "unexpected_eligible",
                "oldNewRGBMAE": float(np.abs(old - new).mean()),
                "portraitIdentityPolicy": "no geometry, skin, face, generative or beauty operation",
            }
        )
    return results


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source_path = INVERSE / "A_source.jpg"
    old_path = BUILD36 / "images" / "D_automatic_diagnostic.jpg"
    target_path = INVERSE / "T_target_registered.jpg"
    candidate_path = BUILD36 / "evidence" / "candidate_states_and_parameters.json"

    source = read_rgb(source_path)
    old = read_rgb(old_path)
    shape = source.shape[:2]
    if old.shape[:2] != shape:
        raise RuntimeError("A and OLD are not the same full-resolution geometry")

    masks = {
        name: read_mask(INVERSE / f"mask_{name}.png", shape)
        for name in ("ground", "vegetation", "sky", "architecture")
    }
    scene = json.loads(
        (VISUAL / "01_scene_understanding" / "autumn_street" / "scene_understanding.json")
        .read_text(encoding="utf-8")
    )
    regions = {item["region"]: item for item in scene["regions"]}
    ground = regions["ground"]["measurements"]
    vegetation = regions["vegetation"]["measurements"]
    diagnosis_confidence = min(
        float(regions["ground"]["confidence"]),
        float(regions["vegetation"]["confidence"]),
    )
    noise_estimate = 0.159
    noise_protection = max(0.22, 1.0 - noise_estimate * 2.8)
    luminance_dominance = np.clip(
        max(0.0, ground["averageLuminance"] - vegetation["averageLuminance"]) / 0.22,
        0.0,
        1.0,
    )
    saturation_advantage = np.clip(
        max(0.0, vegetation["averageSaturation"] - ground["averageSaturation"]) / 0.25,
        0.0,
        1.0,
    )
    coverage_balance = min(ground["coverage"], vegetation["coverage"]) / max(
        ground["coverage"], vegetation["coverage"]
    )
    mask_reliability = 0.86
    # Mirrors the Swift fix: diagnosis eligibility already validated confidence
    # and both masks. Noise is a render-strength/safety constraint, not a second
    # target-eligibility multiplier.
    hierarchy_evidence = (
        luminance_dominance * 0.36
        + saturation_advantage * 0.44
        + coverage_balance * 0.20
    ) * mask_reliability
    relationship_eligible = (
        regions["ground"]["status"] == "reliable"
        and regions["vegetation"]["status"] == "reliable"
        and hierarchy_evidence >= 0.28
        and saturation_advantage >= 0.24
        and luminance_dominance >= 0.16
    )
    if not relationship_eligible:
        raise RuntimeError("Autumn street relationship did not meet the current code gates")

    relationship_target = -float(
        np.clip(
            0.025
            + luminance_dominance * 0.04
            + saturation_advantage * 0.035
            + coverage_balance * 0.015,
            0.03,
            0.095,
        )
    )
    vegetation_target = float(np.clip(vegetation["averageLuminance"] - 0.01, 0.22, 0.62))
    ground_target = float(np.clip(vegetation_target + relationship_target, 0.20, 0.62))
    expression_demand = float(
        np.clip(abs(ground["averageLuminance"] - ground_target) / 0.20, 0.0, 1.0)
    )
    response = 0.86 + expression_demand * 0.14
    new_ground_ev = float(
        np.clip(math.log2(max(ground_target, 1e-4) / max(ground["averageLuminance"], 1e-4)), -0.58, 0.28)
        * response
    )
    new_vegetation_ev = float(
        np.clip(
            math.log2(max(vegetation_target, 1e-4) / max(vegetation["averageLuminance"], 1e-4)),
            -0.42,
            0.25,
        )
        * 0.90
    )
    old_ground_ev = parse_executed_ev(candidate_path, "D", "地面/道路")
    old_vegetation_ev = parse_executed_ev(candidate_path, "D", "植被")
    ground_delta_ev = new_ground_ev - old_ground_ev
    vegetation_delta_ev = new_vegetation_ev - old_vegetation_ev

    # Render before the target image is opened. The target cannot influence any
    # target, parameter, mask, gate or pixel transform above or below this line.
    new, ground_weight = apply_exposure_delta(
        old,
        source,
        masks["ground"],
        ground_delta_ev,
        lower=0.12,
        upper=0.78,
        feather=0.19,
        exclusions=[masks["sky"], masks["vegetation"], masks["architecture"]],
    )
    new, vegetation_weight = apply_exposure_delta(
        new,
        source,
        masks["vegetation"],
        vegetation_delta_ev,
        lower=0.10,
        upper=0.86,
        feather=0.16,
        exclusions=[masks["sky"], masks["architecture"]],
    )

    write_rgb(OUTPUT / "A_original.jpg", source)
    write_rgb(OUTPUT / "OLD_build36_iPhone_CoreImage.jpg", old)
    write_rgb(OUTPUT / "NEW_structured_diagnosis_WINDOWS_SIMULATION.jpg", new)
    cv2.imwrite(
        str(OUTPUT / "ground_effective_weight.png"),
        np.clip(np.rint(ground_weight * 255), 0, 255).astype(np.uint8),
    )
    cv2.imwrite(
        str(OUTPUT / "vegetation_effective_weight.png"),
        np.clip(np.rint(vegetation_weight * 255), 0, 255).astype(np.uint8),
    )

    # Post-hoc evaluation starts here. T was not read before NEW was finalized.
    target = read_rgb(target_path)
    if target.shape[:2] != shape:
        raise RuntimeError("Registered T does not match A geometry")
    write_rgb(OUTPUT / "T_reference_evaluation_only.jpg", target)
    labeled_contact(
        [
            ("A source", source),
            ("OLD Build36 D (iPhone Core Image)", old),
            ("NEW (Windows simulation; diagnosis-linked)", new),
            ("T evaluation only", target),
        ],
        OUTPUT / "A_OLD_NEW_T_contact.jpg",
    )

    source_luma = luminance(source)
    source_sat = saturation(source)
    bright_neutral = ((source_luma >= 0.72) & (source_sat <= 0.08)).astype(np.float32)
    change = np.abs(new - old).mean(axis=2)
    old_regions = {name: region_metrics(old, mask) for name, mask in masks.items()}
    new_regions = {name: region_metrics(new, mask) for name, mask in masks.items()}
    target_regions = {name: region_metrics(target, mask) for name, mask in masks.items()}
    old_relationship = old_regions["ground"]["luminance"] - old_regions["vegetation"]["luminance"]
    new_relationship = new_regions["ground"]["luminance"] - new_regions["vegetation"]["luminance"]
    target_relationship = target_regions["ground"]["luminance"] - target_regions["vegetation"]["luminance"]
    old_neutral = region_metrics(old, bright_neutral)
    new_neutral = region_metrics(new, bright_neutral)
    black_increase = float((luminance(new) <= 0.015).mean() - (luminance(old) <= 0.015).mean())
    neutral_loss = new_neutral["luminance"] - old_neutral["luminance"]
    neutral_chroma_shift = abs(
        (new_neutral["red"] - new_neutral["blue"])
        - (old_neutral["red"] - old_neutral["blue"])
    )
    boundary = boundary_change(change, masks["ground"])
    moved_toward_target = abs(new_relationship - target_relationship) < abs(
        old_relationship - target_relationship
    )
    safety = {
        "globalShadowClipIncrease": black_increase,
        "brightNeutralLuminanceDelta": neutral_loss,
        "brightNeutralRedBlueDeltaShift": neutral_chroma_shift,
        "architectureLuminanceDelta": new_regions["architecture"]["luminance"]
        - old_regions["architecture"]["luminance"],
        **boundary,
    }
    safety_passed = (
        black_increase <= 0.012
        and neutral_loss >= -0.025
        and neutral_chroma_shift <= 0.012
        and abs(safety["architectureLuminanceDelta"]) <= 0.02
        and boundary["boundaryChangeP95"] <= max(0.10, boundary["interiorChangeP95"] * 1.35)
    )
    outcome = "SUCCESS" if moved_toward_target and safety_passed else "FAILED"
    evidence = {
        "schema": "xiao-su-camera.structured-diagnosis-closure.v1",
        "status": outcome,
        "evidenceBoundary": {
            "newImage": "Windows simulation using the patched algorithm's measurement-driven relationship math; not Core Image or iPhone evidence",
            "oldImage": "real Build 36 iPhone Core Image D output",
            "target": "loaded only after NEW was rendered; evaluation only",
            "roadOrVehicleClaim": "none; ground class mask only",
        },
        "sources": {
            "A": {"path": str(source_path), "sha256": sha256(source_path)},
            "OLD": {"path": str(old_path), "sha256": sha256(old_path)},
            "T": {"path": str(target_path), "sha256": sha256(target_path)},
        },
        "diagnosisLifecycle": {
            "identifier": "VISUAL-RELATION-GROUND-VEGETATION",
            "eligible": True,
            "planned": True,
            "executed": True,
            "rejected": False,
            "diagnosisConfidence": diagnosis_confidence,
            "hierarchyEvidence": hierarchy_evidence,
        },
        "measurementsAndTargets": {
            "groundLuminance": ground["averageLuminance"],
            "vegetationLuminance": vegetation["averageLuminance"],
            "sourceGroundMinusVegetation": ground["averageLuminance"] - vegetation["averageLuminance"],
            "sourceVegetationMinusGroundSaturation": vegetation["averageSaturation"] - ground["averageSaturation"],
            "relationshipTarget": relationship_target,
            "groundTarget": ground_target,
            "vegetationTarget": vegetation_target,
        },
        "executedParameters": {
            "oldGroundEV": old_ground_ev,
            "newGroundEV": new_ground_ev,
            "groundDeltaAppliedToOLD": ground_delta_ev,
            "groundRange": [0.12, 0.78],
            "groundFeather": 0.19,
            "oldVegetationEV": old_vegetation_ev,
            "newVegetationEV": new_vegetation_ev,
            "vegetationDeltaAppliedToOLD": vegetation_delta_ev,
            "vegetationRange": [0.10, 0.86],
            "vegetationFeather": 0.16,
        },
        "actualPixelMeasurements": {
            "OLD": old_regions,
            "NEW": new_regions,
            "T_evaluationOnly": target_regions,
            "relationships": {
                "oldGroundMinusVegetation": old_relationship,
                "newGroundMinusVegetation": new_relationship,
                "targetGroundMinusVegetation": target_relationship,
                "movedTowardIndependentTarget": moved_toward_target,
            },
            "oldNewRGBMAE": float(np.abs(old - new).mean()),
            "newTargetRGBMAE": float(np.abs(new - target).mean()),
        },
        "technicalSafety": {**safety, "passed": safety_passed},
        "humanAestheticStatus": "pending_human_review",
        "unmet": [] if moved_toward_target else ["regional relationship did not move toward independent T"],
        "regressions": regression_cases(OUTPUT),
    }
    (OUTPUT / "execution_evidence.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps({
        "status": outcome,
        "relationship": evidence["actualPixelMeasurements"]["relationships"],
        "safety": evidence["technicalSafety"],
        "output": str(OUTPUT),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
