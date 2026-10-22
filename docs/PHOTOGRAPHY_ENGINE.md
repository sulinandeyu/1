# Photography engine

## What the engine is

An explainable computational-photography pipeline. AI/vision interprets the frame and selects
parameters; Core Image performs deterministic pixel edits. It is not a whole-image generator.

## Processing order

1. Orientation and working color space.
2. Exposure and recoverable dynamic range.
3. Base curve and seven-anchor filmic tone mapping.
4. Continuous luminance-zone shadow/highlight processing.
5. White balance, color controls, vibrance and hue-range HSL.
6. Shadow/midtone/highlight grading.
7. Verified subject, face and sky local adjustments.
8. Spatial separation and restrained local contrast.
9. Noise reduction, output-scale sharpening and skin texture restoration.
10. Optional highlight-only lens character, grain and vignette.
11. Full-resolution JPEG, metadata, diagnostics and quality validation.

## Root-cause audit for V7

| Symptom | Evidence in V6 | Root cause | V7 direction | Acceptance |
|---|---|---|---|---|
| different scenes can look similar | generic `outdoor` could hide coast/building labels | multi-label context was flattened at primary strategy selection | strategy now selects from facets/lighting before the legacy fallback | same technical input with different labels yields different recipes |
| cyan/blue shifts | standard cinematic grade injected the same strong floors after scene rules | the common grade visually dominated smaller scene deltas | context-specific caps now constrain grade and HSL | overcast and architecture do not inherit one landscape-blue look |
| sky/ground separation is inconsistent | sky works only when bundled model returns a valid mask | no ground/road/water masks; fallback is global | report mask availability; luminance-gradient fallback only | sky parameters execute only against sky mask |
| dawn/cloud/night lack specificity | legacy primary scene could reduce dawn city to night | generic darkness rule overrode structured lighting | blue hour/sunrise/dusk participate before the legacy fallback | lighting record changes recipe independently of scene |
| some good photos barely change | conservative quality safety plus weak measured problems | no explicit aesthetic target delta | style intent sets a bounded tonal/color target | diagnostics explain deliberately light edits |
| diagnostic recipe could disagree with final pixels | corrective render used a second recipe but UI retained the initial decision | final recipe was not copied back to `CapturedPhoto` | final decision now carries the recipe that produced the JPEG | renderer/final trace and diagnostic panel agree |

Detailed evidence: `docs/SCENE_ADAPTATION_AUDIT.md`.

## Non-capabilities

Hair, road, water, vegetation and building segmentation are not claimed until a model produces
validated masks within the memory/performance budget. Saliency is not renamed as those semantics.

