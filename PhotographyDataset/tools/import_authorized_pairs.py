#!/usr/bin/env python3
"""Local-only importer for commercially authorised same-capture A/T pairs.

The importer copies no pixels.  It validates local files, records immutable
hashes/metadata and writes a local manifest.  A separate redacted audit contains
counts only and is safe to review without exposing filenames or image bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageCms, ExifTags


ELIGIBLE_PRIVACY = {"not_required", "model_release_obtained", "property_and_model_releases_obtained"}
VALID_SPLITS = {"train", "validation", "test"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return (path if path.is_absolute() else root / path).resolve()


def image_metadata(path: Path) -> dict[str, Any]:
    with Image.open(path) as image:
        exif = image.getexif()
        orientation = int(exif.get(274, 1))
        icc = image.info.get("icc_profile")
        profile_description = None
        if icc:
            try:
                profile_description = ImageCms.getProfileDescription(
                    ImageCms.ImageCmsProfile(__import__("io").BytesIO(icc))
                ).strip()
            except Exception:
                profile_description = "embedded_unreadable_profile"
        return {
            "format": image.format,
            "dimensions": [image.width, image.height],
            "mode": image.mode,
            "orientation": orientation,
            "icc_sha256": hashlib.sha256(icc).hexdigest() if icc else None,
            "icc_description": profile_description,
            "exif_present": bool(exif),
            "capture_time_present": bool(exif.get(36867) or exif.get(306)),
        }


def structural_correlation(a: Path, t: Path) -> tuple[float, float]:
    def sample(path: Path) -> tuple[np.ndarray, np.ndarray]:
        with Image.open(path) as source:
            gray = np.asarray(source.convert("L").resize((256, 256), Image.Resampling.LANCZOS), np.float32) / 255
        gx = np.zeros_like(gray); gy = np.zeros_like(gray)
        gx[:, 1:-1] = (gray[:, 2:] - gray[:, :-2]) * .5
        gy[1:-1, :] = (gray[2:, :] - gray[:-2, :]) * .5
        return gray, np.sqrt(gx * gx + gy * gy)

    def corr(x: np.ndarray, y: np.ndarray) -> float:
        x = x.ravel() - x.mean(); y = y.ravel() - y.mean()
        denominator = float(np.sqrt((x * x).sum() * (y * y).sum()))
        return float((x * y).sum() / denominator) if denominator > 1e-9 else 0.0

    ag, ae = sample(a); tg, te = sample(t)
    return corr(ag, tg), corr(ae, te)


def require_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{record.get('pair_id', '<unknown>')}: {key} is required")
    return value.strip()


def validate_record(record: dict[str, Any], root: Path) -> dict[str, Any]:
    pair_id = require_text(record, "pair_id")
    if record.get("same_capture_verified") is not True:
        raise ValueError(f"{pair_id}: same_capture_verified must be true")
    split = require_text(record, "split")
    if split not in VALID_SPLITS:
        raise ValueError(f"{pair_id}: invalid split {split}")
    original = resolve(root, require_text(record, "original_path"))
    target = resolve(root, require_text(record, "target_path"))
    if not original.is_file() or not target.is_file():
        raise FileNotFoundError(f"{pair_id}: A or T is missing")
    original_meta, target_meta = image_metadata(original), image_metadata(target)
    if original_meta["dimensions"] != target_meta["dimensions"]:
        raise ValueError(f"{pair_id}: A/T canvas mismatch")
    gray_correlation, edge_correlation = structural_correlation(original, target)
    if edge_correlation < .75:
        raise ValueError(f"{pair_id}: edge correlation {edge_correlation:.3f}; not a verified aligned pair")

    rights = record.get("rights") or {}
    target = record.get("target_authorship") or {}
    professional = record.get("target_type") == "independent_professional_edit"
    rights_complete = all([
        rights.get("commercial_training_allowed") is True,
        rights.get("model_distribution_allowed") is True,
        rights.get("privacy_release_status") in ELIGIBLE_PRIVACY,
        isinstance(rights.get("grant_evidence"), str) and rights["grant_evidence"].strip(),
        isinstance(rights.get("original_rights_holder"), str) and rights["original_rights_holder"].strip(),
        isinstance(rights.get("target_rights_holder"), str) and rights["target_rights_holder"].strip(),
    ])
    independent = target.get("independent_from_oracle") is True and target.get("is_algorithm_output") is False
    documented_edit = bool(record.get("edit_intent")) and bool(record.get("actual_operations"))
    eligible = bool(professional and rights_complete and independent and documented_edit)
    requested = record.get("usage_scope") == "product_training_candidate"
    if requested and not eligible:
        raise ValueError(f"{pair_id}: product candidate lacks independent professional target or explicit rights")

    return {
        "pair_id": pair_id,
        "schema_version": 1,
        "original_path": str(original),
        "target_path": str(resolve(root, require_text(record, "target_path"))),
        "original_sha256": sha256(original),
        "target_sha256": sha256(resolve(root, require_text(record, "target_path"))),
        "original_metadata": original_meta,
        "target_metadata": target_meta,
        "grayscale_correlation": gray_correlation,
        "edge_correlation": edge_correlation,
        "split": split,
        "scene_family": require_text(record, "scene_family"),
        "edit_intent": record.get("edit_intent"),
        "actual_operations": record.get("actual_operations"),
        "rights": rights,
        "target_authorship": target,
        "eligible_for_product_training": eligible,
        "import_status": "eligible_product_pair" if eligible else "research_or_pipeline_only",
    }


def run() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--declarations", required=True, type=Path)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--local-manifest", required=True, type=Path)
    parser.add_argument("--redacted-audit", required=True, type=Path)
    args = parser.parse_args()
    records = [json.loads(line) for line in args.declarations.read_text(encoding="utf-8").splitlines() if line.strip()]
    pairs = [validate_record(record, args.project_root.resolve()) for record in records]
    hashes: dict[str, str] = {}
    for pair in pairs:
        for key in ("original_sha256", "target_sha256"):
            prior = hashes.get(pair[key])
            if prior and prior != pair["split"]:
                raise ValueError(f"hash leakage across splits: {pair['pair_id']}")
            hashes[pair[key]] = pair["split"]
    eligible = [pair for pair in pairs if pair["eligible_for_product_training"]]
    manifest = {"schema_version": 1, "pair_count": len(pairs), "eligible_pair_count": len(eligible), "pairs": pairs}
    audit = {
        "schema_version": 1,
        "pair_count": len(pairs),
        "eligible_pair_count": len(eligible),
        "scene_family_counts": {name: sum(p["scene_family"] == name for p in pairs) for name in sorted({p["scene_family"] for p in pairs})},
        "split_counts": {name: sum(p["split"] == name for p in pairs) for name in sorted(VALID_SPLITS)},
        "training_readiness": "ready_for_minimal_experiment" if len(eligible) >= 20 else "insufficient_authorized_pairs",
        "missing_to_20": max(0, 20 - len(eligible)),
        "contains_paths_or_pixels": False,
    }
    args.local_manifest.parent.mkdir(parents=True, exist_ok=True)
    args.redacted_audit.parent.mkdir(parents=True, exist_ok=True)
    args.local_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    args.redacted_audit.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(audit, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
