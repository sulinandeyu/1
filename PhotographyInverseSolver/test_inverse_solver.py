import unittest

import numpy as np

from inverse_solver import (
    GLOBAL_NEUTRAL,
    LOCAL_NEUTRAL,
    apply_measured_cool_cinematic_grade,
    apply_local_controls,
    apply_hsl,
    cinematic_outputs,
    core_image_cube_curve_map,
    render_global,
    srgb_to_linear,
    linear_to_srgb,
)


class InverseSolverTests(unittest.TestCase):
    def test_measured_cool_grade_separates_dark_neutral_and_protects_bright_neutral(self):
        source = np.zeros((32, 32, 3), np.float32)
        source[:16] = 0.30
        source[16:] = 0.88
        output = apply_measured_cool_cinematic_grade(
            source,
            intensity=0.52,
            shadow_cool=0.42,
            midtone_cool=0.30,
            highlight_warm=0.0,
            neutral_highlight_protection=0.90,
            color_contrast=0.0,
        )
        dark_shift = float(np.mean(output[:16, :, 2] - output[:16, :, 0]))
        bright_shift = float(np.mean(output[16:, :, 2] - output[16:, :, 0]))
        self.assertGreater(dark_shift, 0.006)
        self.assertLess(abs(bright_shift), dark_shift * 0.55)

    def test_srgb_round_trip(self):
        values = np.linspace(0, 1, 1024, dtype=np.float32)
        restored = linear_to_srgb(srgb_to_linear(values))
        self.assertLess(float(np.max(np.abs(values - restored))), 2e-6)

    def test_neutral_global_does_not_change_pixels(self):
        rng = np.random.default_rng(4)
        image = rng.random((31, 27, 3), dtype=np.float32)
        rendered = render_global(image, GLOBAL_NEUTRAL)
        self.assertLess(float(np.max(np.abs(image - rendered))), 4e-6)

    def test_neutral_local_does_not_change_pixels(self):
        rng = np.random.default_rng(7)
        image = rng.random((17, 13, 3), dtype=np.float32)
        masks = {"ground": np.ones((17, 13), np.float32)}
        rendered = apply_local_controls(image, LOCAL_NEUTRAL, masks)
        self.assertLess(float(np.max(np.abs(image - rendered))), 3e-6)

    def test_core_image_curve_uses_sampled_cube_interpolation(self):
        params = GLOBAL_NEUTRAL.copy()
        params[5] = -0.1681298
        params[6] = -0.25
        params[8] = 0.0944355
        params[9] = 0.9560542
        value = np.array([0.1517], dtype=np.float32)
        output = core_image_cube_curve_map(value, cinematic_outputs(params))
        self.assertAlmostEqual(float(output[0]), 0.084, delta=0.005)

    def test_hsl_cube_is_neutral_when_hsl_parameters_are_neutral(self):
        rng = np.random.default_rng(11)
        linear = rng.random((17, 13, 3), dtype=np.float32)
        output = apply_hsl(linear, GLOBAL_NEUTRAL)
        self.assertLess(float(np.max(np.abs(linear - output))), 4e-6)


if __name__ == "__main__":
    unittest.main()
