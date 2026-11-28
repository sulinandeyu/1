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
from PIL import Image, ImageCms

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError as error:  # pragma: no cover - exercised by the CLI environment check
    raise RuntimeError(
        "jsonschema is required for authorised-pair import; install "
        "PhotographyDataset/requirements.txt"
    ) from error


ELIGIBLE_PRIVACY = {"not_required", "model_release_obtained", "property_and_model_releases_obtained"}
VALID_SPLITS = {"train", "validation", "test"}
SCHEMA_PATH = Path(__file__).parents[1] / "schemas" / "authorized-pair-v2.schema.json"
PERCEPTUAL_LEAKAGE_MAX_DISTANCE = 0.035


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


def schema_validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


def validate_schema(record: dict[str, Any]) -> None:
    errors = sorted(
        schema_validator().iter_errors(record),
        key=lambda item: [str(part) for part in item.absolute_path],
    )
    if not errors:
        return
    error = errors[0]
    location = ".".join(str(part) for part in error.absolute_path) or "<root>"
    pair_id = record.get("pair_id", "<unknown>")
    raise ValueError(f"{pair_id}: schema validation failed at {location}: {error.message}")


def perceptual_content_fingerprint(path: Path) -> dict[str, str]:
    """Structure fingerprints used only to detect cross-split near duplicates.

    They are deliberately not source-provenance proof.  Re-encoding usually
    changes file SHA-256 while leaving these grayscale structural signatures
    nearly unchanged.
    """
    with Image.open(path) as source:
        gray = np.asarray(
            source.convert("L").resize((17, 16), Image.Resampling.LANCZOS),
            dtype=np.float32,
        )
    differences = gray[:, 1:] >= gray[:, :-1]
    mean_bits = gray[:, :16] >= float(gray[:, :16].mean())

    def pack(bits: np.ndarray) -> str:
        return np.packbits(bits.reshape(-1).astype(np.uint8)).tobytes().hex()

    return {"difference_hash_256": pack(differences), "average_hash_256": pack(mean_bits)}


def fingerprint_distance(lhs: dict[str, str], rhs: dict[str, str]) -> float:
    distances: list[float] = []
    for key in ("difference_hash_256", "average_hash_256"):
        left = bytes.fromhex(lhs[key])
        right = bytes.fromhex(rhs[key])
        differing = sum((a ^ b).bit_count() for a, b in zip(left, right, strict=True))
        distances.append(differing / (len(left) * 8))
    return min(distances)


def target_change_metrics(original: Path, target: Path) -> dict[str, float]:
    with Image.open(original) as original_image, Image.open(target) as target_image:
        source = np.asarray(original_image.convert("RGB"), dtype=np.float32) / 255
        edited = np.asarray(target_image.convert("RGB"), dtype=np.float32) / 255
    absolute = np.abs(source - edited)
    return {
        "normalized_rgb_mae": float(absolute.mean()),
        "changed_pixel_ratio": float(np.any(absolute > (2 / 255), axis=2).mean()),
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
    validate_schema(record)
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
    original_hash, target_hash = sha256(original), sha256(target)
    if original_hash == target_hash:
        raise ValueError(f"{pair_id}: A/T bytes are identical; no independent professional edit exists")
    original_meta, target_meta = image_metadata(original), image_metadata(target)
    if original_meta["dimensions"] != target_meta["dimensions"]:
        raise ValueError(f"{pair_id}: A/T canvas mismatch")
    gray_correlation, edge_correlation = structural_correlation(original, target)
    if edge_correlation < .75:
        raise ValueError(f"{pair_id}: edge correlation {edge_correlation:.3f}; images are not aligned enough for review")

    change = target_change_metrics(original, target)
    if change["normalized_rgb_mae"] < 0.002 and change["changed_pixel_ratio"] < 0.05:
        raise ValueError(f"{pair_id}: A/T have no material recorded edit beyond encoding noise")

    rights = record.get("rights") or {}
    authorship = record.get("target_authorship") or {}
    authorization = rights.get("authorization_verification") or {}
    provenance = record.get("capture_provenance") or {}
    professional = record.get("target_type") == "independent_professional_edit"
    rights_complete = all([
        rights.get("commercial_training_allowed") is True,
        rights.get("model_distribution_allowed") is True,
        rights.get("privacy_release_status") in ELIGIBLE_PRIVACY,
        isinstance(rights.get("original_rights_holder"), str) and rights["original_rights_holder"].strip(),
        isinstance(rights.get("target_rights_holder"), str) and rights["target_rights_holder"].strip(),
        authorization.get("status") == "verified",
        authorization.get("verification_basis") in {"signed_contract", "signed_release", "documented_license"},
        bool(authorization.get("verifier")),
        bool(authorization.get("verified_at")),
        bool(authorization.get("evidence_reference")),
    ])
    identity_verification = authorship.get("identity_verification") or {}
    independent = all([
        authorship.get("independent_from_oracle") is True,
        authorship.get("is_algorithm_output") is False,
        bool(authorship.get("editor_id")),
        bool(authorship.get("editor_display_name")),
        identity_verification.get("status") == "verified",
        bool(identity_verification.get("verifier")),
        bool(identity_verification.get("evidence_reference")),
    ])
    operations = record.get("actual_operations") or []
    documented_edit = bool(record.get("edit_intent")) and all(
        isinstance(item, dict)
        and bool(item.get("operation"))
        and bool(item.get("purpose"))
        and bool(item.get("tool"))
        for item in operations
    )
    same_capture_verified = all([
        provenance.get("status") == "verified",
        provenance.get("verification_method") in {
            "original_asset_id_and_edit_history",
            "raw_sidecar_and_export_record",
            "capture_session_record_and_manual_alignment_review",
        },
        bool(provenance.get("source_asset_id")),
        bool(provenance.get("verifier")),
        bool(provenance.get("verified_at")),
        bool(provenance.get("evidence_reference")),
    ])
    eligible = bool(
        professional and rights_complete and independent and documented_edit and same_capture_verified
    )
    requested = record.get("usage_scope") == "product_training_candidate"
    if requested and not eligible:
        raise ValueError(f"{pair_id}: product candidate lacks independent professional target or explicit rights")

    return {
        "pair_id": pair_id,
        "schema_version": 2,
        "original_path": str(original),
        "target_path": str(resolve(root, require_text(record, "target_path"))),
        "original_sha256": original_hash,
        "target_sha256": target_hash,
        "original_content_fingerprint": perceptual_content_fingerprint(original),
        "target_content_fingerprint": perceptual_content_fingerprint(target),
        "original_metadata": original_meta,
        "target_metadata": target_meta,
        "grayscale_correlation": gray_correlation,
        "edge_correlation": edge_correlation,
        "split": split,
        "scene_family": require_text(record, "scene_family"),
        "edit_intent": record.get("edit_intent"),
        "actual_operations": record.get("actual_operations"),
        "rights": rights,
        "target_authorship": authorship,
        "capture_provenance": provenance,
        "target_change_metrics": change,
        "eligible_for_product_training": eligible,
        "import_status": "eligible_product_pair" if eligible else "research_or_pipeline_only",
    }


def validate_split_isolation(pairs: list[dict[str, Any]]) -> None:
    exact_hash_splits: dict[str, str] = {}
    for pair in pairs:
        for key in ("original_sha256", "target_sha256"):
            prior = exact_hash_splits.get(pair[key])
            if prior and prior != pair["split"]:
                raise ValueError(f"exact hash leakage across splits: {pair['pair_id']}")
            exact_hash_splits[pair[key]] = pair["split"]

    for index, left in enumerate(pairs):
        for right in pairs[index + 1:]:
            if left["split"] == right["split"]:
                continue
            distances = [
                fingerprint_distance(left[left_key], right[right_key])
                for left_key in ("original_content_fingerprint", "target_content_fingerprint")
                for right_key in ("original_content_fingerprint", "target_content_fingerprint")
            ]
            if min(distances) <= PERCEPTUAL_LEAKAGE_MAX_DISTANCE:
                raise ValueError(
                    "perceptual content leakage across splits: "
                    f"{left['pair_id']}({left['split']}) vs {right['pair_id']}({right['split']}); "
                    f"distance={min(distances):.4f}"
                )


def run() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--declarations", required=True, type=Path)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--local-manifest", required=True, type=Path)
    parser.add_argument("--redacted-audit", required=True, type=Path)
    args = parser.parse_args()
    records = [json.loads(line) for line in args.declarations.read_text(encoding="utf-8").splitlines() if line.strip()]
    pairs = [validate_record(record, args.project_root.resolve()) for record in records]
    validate_split_isolation(pairs)
    eligible = [pair for pair in pairs if pair["eligible_for_product_training"]]
    manifest = {"schema_version": 2, "pair_count": len(pairs), "eligible_pair_count": len(eligible), "pairs": pairs}
    audit = {
        "schema_version": 2,
        "pair_count": len(pairs),
        "eligible_pair_count": len(eligible),
        "scene_family_counts": {name: sum(p["scene_family"] == name for p in pairs) for name in sorted({p["scene_family"] for p in pairs})},
        "split_counts": {name: sum(p["split"] == name for p in pairs) for name in sorted(VALID_SPLITS)},
        "training_readiness": "ready_for_minimal_experiment" if len(eligible) >= 20 else "insufficient_authorized_pairs",
        "missing_to_20": max(0, 20 - len(eligible)),
        "first_five_intake_status": "ready_for_manual_acceptance" if len(eligible) >= 5 else "insufficient_verified_professional_pairs",
        "missing_to_5": max(0, 5 - len(eligible)),
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
