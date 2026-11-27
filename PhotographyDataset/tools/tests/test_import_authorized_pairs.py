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
    def make_pair(self, root: Path):
        rng = np.random.default_rng(7)
        pixels = rng.integers(0, 256, (64, 64, 3), dtype=np.uint8)
        Image.fromarray(pixels).save(root / "a.png")
        Image.fromarray(np.clip(pixels.astype(np.int16) + 4, 0, 255).astype(np.uint8)).save(root / "t.png")

    def record(self):
        return {
            "pair_id": "authorised-1", "original_path": "a.png", "target_path": "t.png",
            "same_capture_verified": True, "target_type": "independent_professional_edit",
            "usage_scope": "product_training_candidate", "split": "train", "scene_family": "street",
            "edit_intent": "independent professional tonal hierarchy", "actual_operations": ["tone curve", "HSL"],
            "target_authorship": {"editor": "contracted editor", "independent_from_oracle": True, "is_algorithm_output": False},
            "rights": {"source": "self-owned", "original_rights_holder": "owner", "target_rights_holder": "editor",
                       "commercial_training_allowed": True, "model_distribution_allowed": True,
                       "privacy_release_status": "not_required", "grant_evidence": "signed grant id TEST"}
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
            with self.assertRaisesRegex(ValueError, "lacks independent professional"):
                MODULE.validate_record(record, root)

    def test_rejects_missing_model_distribution_grant(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); self.make_pair(root)
            record = self.record(); record["rights"]["model_distribution_allowed"] = False
            with self.assertRaisesRegex(ValueError, "explicit rights"):
                MODULE.validate_record(record, root)


if __name__ == "__main__":
    unittest.main()
