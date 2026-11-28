import importlib.util
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

MODULE_PATH = Path(__file__).parents[1] / "import_authorized_pairs.py"
SPEC = importlib.util.spec_from_file_location("authorized_importer", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class AuthorisedPairImporterTests(unittest.TestCase):
    def make_pair(self, root: Path, prefix: str = "", jpeg_quality: int | None = None):
        rng = np.random.default_rng(7)
        pixels = rng.integers(0, 256, (64, 64, 3), dtype=np.uint8)
        suffix = ".jpg" if jpeg_quality else ".png"
        original = root / f"{prefix}a{suffix}"
        target = root / f"{prefix}t{suffix}"
        save_options = {"quality": jpeg_quality} if jpeg_quality else {}
        Image.fromarray(pixels).save(original, **save_options)
        Image.fromarray(np.clip(pixels.astype(np.int16) + 12, 0, 255).astype(np.uint8)).save(
            target, **save_options
        )
        return original.name, target.name

    def record(self, original_path: str = "a.png", target_path: str = "t.png"):
        return {
            "schema_version": 2,
            "pair_id": "authorised-1", "original_path": original_path, "target_path": target_path,
            "same_capture_verified": True, "target_type": "independent_professional_edit",
            "usage_scope": "product_training_candidate", "split": "train", "scene_family": "street",
            "capture_provenance": {
                "status": "verified",
                "verification_method": "original_asset_id_and_edit_history",
                "source_asset_id": "asset-1",
                "verifier": "dataset reviewer",
                "verified_at": "2026-11-28T00:00:00Z",
                "evidence_reference": "LOCAL-PROVENANCE-1",
            },
            "edit_intent": "independent professional tonal hierarchy",
            "actual_operations": [
                {"operation": "tone curve", "purpose": "midtone hierarchy", "tool": "Lightroom"},
                {"operation": "HSL", "purpose": "separate existing colours", "tool": "Lightroom"},
            ],
            "target_authorship": {
                "editor_id": "editor-1",
                "editor_display_name": "contracted editor",
                "independent_from_oracle": True,
                "is_algorithm_output": False,
                "identity_verification": {
                    "status": "verified",
                    "verifier": "dataset reviewer",
                    "evidence_reference": "LOCAL-EDITOR-1",
                },
            },
            "rights": {"source": "self-owned", "original_rights_holder": "owner", "target_rights_holder": "editor",
                       "commercial_training_allowed": True, "model_distribution_allowed": True,
                       "privacy_release_status": "not_required",
                       "rights_assertion_reference": "LOCAL-ASSERTION-1",
                       "authorization_verification": {
                           "status": "verified", "verification_basis": "signed_contract",
                           "verifier": "rights reviewer", "verified_at": "2026-11-28T00:00:00Z",
                           "evidence_reference": "LOCAL-GRANT-1",
                       }}
        }

    def test_accepts_complete_authorised_pair(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            result = MODULE.validate_record(self.record(), root)
            self.assertTrue(result["eligible_for_product_training"])
            self.assertEqual(result["original_metadata"]["dimensions"], [64, 64])

    def test_rejects_oracle_as_product_target(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record(); record["target_type"] = "oracle_output"
            record["target_authorship"]["independent_from_oracle"] = False
            record["target_authorship"]["is_algorithm_output"] = True
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                MODULE.validate_record(record, root)

    def test_rejects_missing_model_distribution_grant(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record(); record["rights"]["model_distribution_allowed"] = False
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                MODULE.validate_record(record, root)

    def test_rejects_identical_a_t_bytes(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            (root / "t.png").write_bytes((root / "a.png").read_bytes())
            with self.assertRaisesRegex(ValueError, "bytes are identical"):
                MODULE.validate_record(self.record(), root)

    def test_rejects_blank_editor_identity_through_schema(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record(); record["target_authorship"]["editor_display_name"] = ""
            with self.assertRaisesRegex(ValueError, "schema validation failed.*editor_display_name"):
                MODULE.validate_record(record, root)

    def test_arbitrary_grant_string_cannot_replace_verified_authorization(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record()
            del record["rights"]["authorization_verification"]
            record["rights"]["grant_evidence"] = "trust me"
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                MODULE.validate_record(record, root)

    def test_pending_authorization_is_not_eligible_even_with_complete_assertion(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record()
            record["rights"]["authorization_verification"]["status"] = "pending"
            with self.assertRaisesRegex(ValueError, "lacks independent professional target or explicit rights"):
                MODULE.validate_record(record, root)

    def test_rejects_incomplete_structured_edit_operation(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record(); record["actual_operations"] = [{"operation": "curve"}]
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                MODULE.validate_record(record, root)

    def test_schema_version_is_actually_validated(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record(); record["schema_version"] = 1
            with self.assertRaisesRegex(ValueError, "schema validation failed.*schema_version"):
                MODULE.validate_record(record, root)

    def test_reencoded_same_content_cannot_cross_splits(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            a1, t1 = self.make_pair(root, prefix="one-", jpeg_quality=96)
            # Re-encode the same source and independently altered target at a
            # different JPEG quality so byte SHA-256 values no longer match.
            with Image.open(root / a1) as image:
                image.save(root / "two-a.jpg", quality=72)
            with Image.open(root / t1) as image:
                image.save(root / "two-t.jpg", quality=72)
            train_record = self.record(a1, t1)
            validation_record = self.record("two-a.jpg", "two-t.jpg")
            validation_record["pair_id"] = "authorised-2"
            validation_record["split"] = "validation"
            validation_record["capture_provenance"]["source_asset_id"] = "asset-2"
            first = MODULE.validate_record(train_record, root)
            second = MODULE.validate_record(validation_record, root)
            self.assertNotEqual(first["original_sha256"], second["original_sha256"])
            with self.assertRaisesRegex(ValueError, "perceptual content leakage"):
                MODULE.validate_split_isolation([first, second])


if __name__ == "__main__":
    unittest.main()
