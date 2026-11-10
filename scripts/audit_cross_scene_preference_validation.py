#!/usr/bin/env python3
"""Audit real cross-scene candidate evidence without inventing preference labels.

The script never renders a new photographic candidate.  It verifies the split,
measures actual JPEG pairs already produced by the app, and builds contact sheets
for human review.  Its Windows measurements are diagnostic only and are not a
substitute for Core Image quality checks or human preference.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SPLIT = ROOT / "PhoneValidationDataset" / "cross_scene_split.json"
OUTPUT = ROOT / "output" / "cross_scene_preference_validation"
HISTORICAL = ROOT / "TestPhotos" / "V8_2_FourScenes"
BUILD33 = ROOT / "tmp" / "build33_diagnostic_20261110_103023" / "images"
BUILD33_EVIDENCE = ROOT / "tmp" / "build33_diagnostic_20261110_103023" / "evidence"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rgb(path: Path, width: int = 720) -> tuple[bytes, int, int]:
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    )
    stream = json.loads(probe.stdout)["streams"][0]
    source_width, source_height = int(stream["width"]), int(stream["height"])
    height = max(2, round(source_height * width / source_width / 2) * 2)
    decoded = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"scale={width}:{height}", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"],
        check=True, capture_output=True,
    )
    return decoded.stdout, width, height


def percentile(histogram: list[int], fraction: float) -> float:
    target = sum(histogram) * fraction
    running = 0
    for index, count in enumerate(histogram):
        running += count
        if running >= target:
            return index / 255.0
    return 1.0


def metrics(path: Path) -> dict[str, Any]:
    image, width, height = rgb(path)
    count = max(1, width * height)
    histogram = [0] * 256
    saturation_total = 0.0
    neutral_pixels: list[tuple[int, int, int]] = []
    luminance_values: list[int] = []
    for offset in range(0, len(image), 3):
        red, green, blue = image[offset], image[offset + 1], image[offset + 2]
        luminance = max(0, min(255, round(red * 0.2126 + green * 0.7152 + blue * 0.0722)))
        histogram[luminance] += 1
        luminance_values.append(luminance)
        maximum = max(red, green, blue)
        minimum = min(red, green, blue)
        saturation_total += (maximum - minimum) / max(maximum, 1)
        if maximum - minimum < 14:
            neutral_pixels.append((red, green, blue))
    edge_total = 0
    edge_count = 0
    for y in range(1, height):
        row = y * width
        previous = row - width
        for x in range(1, width):
            current = luminance_values[row + x]
            edge_total += abs(current - luminance_values[row + x - 1]) + abs(current - luminance_values[previous + x])
            edge_count += 2
    edge = edge_total / max(1, edge_count) / 255.0
    neutral_mean = None
    if neutral_pixels:
        neutral_count = len(neutral_pixels)
        neutral_mean = [round(sum(pixel[channel] for pixel in neutral_pixels) / neutral_count / 255.0, 6) for channel in range(3)]
    return {
        "meanLuminance": round(sum(index * value for index, value in enumerate(histogram)) / count / 255.0, 6),
        "luminanceP05": round(percentile(histogram, 0.05), 6),
        "luminanceP95": round(percentile(histogram, 0.95), 6),
        "shadowRatioBelow005": round(sum(histogram[:13]) / count, 6),
        "highlightRatioAbove095": round(sum(histogram[243:]) / count, 6),
        "meanSaturation": round(saturation_total / count, 6),
        "neutralCoverage": round(len(neutral_pixels) / count, 6),
        "neutralMeanRGB": neutral_mean,
        "edgeEnergy": round(edge, 6),
    }


def comparison(source_path: Path, candidate_path: Path) -> dict[str, Any]:
    source, width, height = rgb(source_path)
    candidate, candidate_width, candidate_height = rgb(candidate_path)
    if (candidate_width, candidate_height) != (width, height):
        raise ValueError("decoded pair geometry mismatch")
    absolute_total = 0
    changed = 0
    for offset in range(0, len(source), 3):
        differences = [abs(candidate[offset + channel] - source[offset + channel]) for channel in range(3)]
        absolute_total += sum(differences)
        changed += int(max(differences) > 3)
    rgb_mae = absolute_total / max(1, len(source)) / 255.0
    changed = changed / max(1, width * height)
    source_metrics = metrics(source_path)
    candidate_metrics = metrics(candidate_path)
    return {
        "source": source_metrics,
        "candidate": candidate_metrics,
        "rgbMAE": round(rgb_mae, 6),
        "changedPixelRatio1pct": round(changed, 6),
        "luminanceDelta": round(candidate_metrics["meanLuminance"] - source_metrics["meanLuminance"], 6),
        "saturationDelta": round(candidate_metrics["meanSaturation"] - source_metrics["meanSaturation"], 6),
        "shadowRatioDelta": round(candidate_metrics["shadowRatioBelow005"] - source_metrics["shadowRatioBelow005"], 6),
        "highlightRatioDelta": round(candidate_metrics["highlightRatioAbove095"] - source_metrics["highlightRatioAbove095"], 6),
        "edgeEnergyRatio": round(candidate_metrics["edgeEnergy"] / max(source_metrics["edgeEnergy"], 1e-6), 6),
        "technicalAcceptance": "not_determined_on_windows",
        "humanPreference": "not_evaluated",
    }


def resolve(relative: str) -> Path:
    return (ROOT / "PhoneValidationDataset" / relative).resolve()


def contact_sheet(rows: list[tuple[str, Path, Path]], destination: Path) -> None:
    inputs = [path for _, source, candidate in rows for path in (source, candidate)]
    command = ["ffmpeg", "-y", "-v", "error"]
    for path in inputs:
        command += ["-i", str(path)]
    filters = []
    for index in range(len(inputs)):
        filters.append(f"[{index}:v]scale=520:420:force_original_aspect_ratio=decrease,pad=520:420:(ow-iw)/2:(oh-ih)/2:color=black[p{index}]")
    for row in range(len(rows)):
        filters.append(f"[p{row * 2}][p{row * 2 + 1}]hstack=inputs=2[r{row}]")
    filters.append("".join(f"[r{row}]" for row in range(len(rows))) + f"vstack=inputs={len(rows)}[out]")
    subprocess.run(command + ["-filter_complex", ";".join(filters), "-map", "[out]", "-frames:v", "1", "-q:v", "2", str(destination)], check=True)


def current_contact_sheet(destination: Path) -> list[str]:
    identifiers = [
        ("A", "A_original.jpg"), ("B", "B_formal_output.jpg"),
        ("D", "D_automatic_diagnostic.jpg"), ("E1", "E1_spatial_emphasis.jpg"),
        ("E2", "E2_restrained_depth.jpg"), ("M", "M_manual_render.jpg"),
    ]
    available = [(identifier, BUILD33 / filename) for identifier, filename in identifiers if (BUILD33 / filename).is_file()]
    command = ["ffmpeg", "-y", "-v", "error"]
    for _, path in available:
        command += ["-i", str(path)]
    filters = [f"[{index}:v]scale=520:420:force_original_aspect_ratio=decrease,pad=520:420:(ow-iw)/2:(oh-ih)/2:color=black[p{index}]" for index in range(len(available))]
    filters += ["[p0][p1][p2]hstack=inputs=3[r0]", "[p3][p4][p5]hstack=inputs=3[r1]", "[r0][r1]vstack=inputs=2[out]"]
    subprocess.run(command + ["-filter_complex", ";".join(filters), "-map", "[out]", "-frames:v", "1", "-q:v", "2", str(destination)], check=True)
    return [identifier for identifier, _ in available]


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    split = json.loads(SPLIT.read_text(encoding="utf-8"))
    seen: dict[str, str] = {}
    split_audit: list[dict[str, Any]] = []
    for group in ("development", "blind"):
        for item in split[group]:
            path = resolve(item["path"])
            actual_hash = sha256(path)
            expected_hash = item["sha256"].lower()
            duplicate = seen.get(actual_hash)
            split_audit.append({"id": item["id"], "group": group, "exists": path.is_file(), "hashMatches": actual_hash == expected_hash, "duplicateOf": duplicate})
            if duplicate:
                raise SystemExit(f"split leakage: {item['id']} duplicates {duplicate}")
            seen[actual_hash] = item["id"]

    historical_rows = [
        ("selfie", HISTORICAL / "A_selfie_original.jpg", HISTORICAL / "A_selfie_v81.jpg"),
        ("building", HISTORICAL / "B_building_original.jpg", HISTORICAL / "B_building_v81.jpg"),
        ("vehicle-person", HISTORICAL / "C_vehicle_person_original.jpg", HISTORICAL / "C_vehicle_person_v81.jpg"),
        ("trees", HISTORICAL / "D_trees_original.jpg", HISTORICAL / "D_trees_v81.jpg"),
    ]
    historical_results = [{"id": case_id, **comparison(source, candidate)} for case_id, source, candidate in historical_rows]
    contact_sheet(historical_rows, OUTPUT / "historical_actual_cross_scene_pairs.jpg")
    current_candidates = current_contact_sheet(OUTPUT / "build33_actual_candidate_grid.jpg")
    build33_source = BUILD33 / "A_original.jpg"
    build33_metrics = {
        identifier: comparison(build33_source, BUILD33 / filename)
        for identifier, filename in [
            ("B", "B_formal_output.jpg"), ("D", "D_automatic_diagnostic.jpg"),
            ("E1", "E1_spatial_emphasis.jpg"), ("E2", "E2_restrained_depth.jpg"),
            ("M", "M_manual_render.jpg"),
        ]
        if build33_source.is_file() and (BUILD33 / filename).is_file()
    }
    build33_candidate_records: list[dict[str, Any]] = []
    candidate_record_path = BUILD33_EVIDENCE / "candidate_states_and_parameters.json"
    if candidate_record_path.is_file():
        records = json.loads(candidate_record_path.read_text(encoding="utf-8"))
        build33_candidate_records = [record for record in records if record.get("identifier") in {"D", "E1", "E2", "M"}]

    preference_files = [
        ROOT / "TestPhotos" / "photography_preferences.jsonl",
        ROOT / "PhoneValidationDataset" / "evaluation" / "results",
    ]
    real_preference_count = 0
    if preference_files[0].is_file():
        real_preference_count += sum(1 for line in preference_files[0].read_text(encoding="utf-8").splitlines() if line.strip())
    if preference_files[1].is_dir():
        real_preference_count += len([path for path in preference_files[1].glob("*.json") if path.name != ".gitkeep"])

    evidence = {
        "generatedBy": "scripts/audit_cross_scene_preference_validation.py",
        "scope": "Windows diagnostics over existing actual JPEG outputs; no Core Image rendering is claimed.",
        "splitAudit": split_audit,
        "historicalActualPairs": historical_results,
        "build33ActualCandidateIdentifiers": current_candidates,
        "build33ActualCandidateMetrics": build33_metrics,
        "build33ActualExecutedParameters": build33_candidate_records,
        "currentDCrossSceneStatus": "pending_device_export",
        "realHumanPreferenceRecordCount": real_preference_count,
        "ruleSystemProfessionalTargetSelectionSupported": False,
        "reason": "No real human preference labels exist, and historical visible edits include technical/colour failures. Build 33 has multiple actual candidates for only one heavily studied image.",
    }
    (OUTPUT / "evidence.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"output": str(OUTPUT), "humanPreferences": real_preference_count, "splitCases": len(split_audit), "historicalPairs": len(historical_results)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
