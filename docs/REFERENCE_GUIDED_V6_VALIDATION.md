# Reference-guided V6 validation

## Scope

The seven user-supplied JPEGs are finished reference works, not original/edited pairs. Two
portrait files also contain white page margins and gallery UI. They are therefore used to
derive photographic constraints, never as LUT sources or as proof that MasterCamera can
recreate the same image.

## Measured reference envelope

Metrics were measured from 128-pixel-long-edge sRGB decodes using the same luminance
thresholds as `PhotoAnalyzer`.

| Reference | Mean luma | 5–95% range | Shadow ratio | Highlight ratio | Saturation |
|---|---:|---:|---:|---:|---:|
| bridge still life | 0.210 | 0.420 | 0.550 | 0.000 | 0.350 |
| blue-hour portrait 1* | 0.320 | 0.980 | 0.470 | 0.110 | 0.360 |
| blue-hour portrait 2* | 0.410 | 1.000 | 0.230 | 0.100 | 0.330 |
| night path | 0.140 | 0.420 | 0.730 | 0.000 | 0.530 |
| urban night | 0.230 | 0.480 | 0.420 | 0.000 | 0.180 |
| desk still life | 0.220 | 0.750 | 0.630 | 0.020 | 0.460 |
| warm bedroom | 0.210 | 0.500 | 0.450 | 0.010 | 0.450 |

`*` White page margins and gallery UI contaminate the global histogram. Portrait metrics
must not become numeric targets.

## Visual constraints translated into the engine

- Mature night work can legitimately retain 42–73% shadow pixels. Quality validation must
  compare against the source instead of rejecting darkness by a fixed threshold.
- Important lamps occupy small, concentrated regions. Highlight recovery should be driven
  by connected bright regions and luminance masks; synthetic bloom stays optional and tiny.
- Interiors preserve warm practical lights while neutral surfaces remain credible. Mixed-light
  detection limits global split toning.
- Blue-hour portraits preserve the cool environment while face exposure and orange/skin HSL
  remain independent from the sky and clothing.
- Professional depth comes from spatial light ratios, leading lines, subject placement and
  controlled local contrast—not universal saturation, crushed blacks or cyan shadows.

## What this validation proves

It proves that the reference constraints were measured and encoded into analysis, recipe
selection and quality checks. It does **not** prove final photographic quality because the
references have no corresponding unedited inputs. Final acceptance still requires importing
real Original files into the app's sample re-test entry and comparing the generated output.

