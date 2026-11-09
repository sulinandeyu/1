import unittest

import numpy as np

from inverse_solver import (
    GLOBAL_NEUTRAL,
    LOCAL_NEUTRAL,
    apply_local_controls,
    render_global,
    srgb_to_linear,
    linear_to_srgb,
)


class InverseSolverTests(unittest.TestCase):
    def test_srgb_round_trip(self):
        values = np.linspace(0, 1, 1024, dtype=np.float32)
        restored = linear_to_srgb(srgb_to_linear(values))
        self.assertLess(float(np.max(np.abs(values - restored))), 2e-6)

    def test_neutral_global_does_not_change_pixels(self):
        rng = np.random.default_rng(4)
        image = rng.random((31, 27, 3), dtype=np.float32)
        rendered = render_global(image, GLOBAL_NEUTRAL)
        self.assertLess(float(np.max(np.abs(image - rendered))), 3e-6)

    def test_neutral_local_does_not_change_pixels(self):
        rng = np.random.default_rng(7)
        image = rng.random((17, 13, 3), dtype=np.float32)
        masks = {"ground": np.ones((17, 13), np.float32)}
        rendered = apply_local_controls(image, LOCAL_NEUTRAL, masks)
        self.assertLess(float(np.max(np.abs(image - rendered))), 3e-6)


if __name__ == "__main__":
    unittest.main()
