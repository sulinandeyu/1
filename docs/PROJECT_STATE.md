# MasterCamera project state

## Shipped baseline

- iOS 17+, SwiftUI, AVFoundation, Core Image, Vision and one bundled semantic Core ML model.
- Camera capture, front/back switching, original preservation, edited JPEG, comparison UI,
  Photos import re-test and Photo Library saving are working.
- TestFlight build 13 contains the reference-guided V6 engine at commit `3162a6c`.

## Effective capture-to-output chain

`CameraManager` → `CameraViewModel` → `PhotoProcessingPipeline` → `PhotoAnalyzer` →
`PhotoProblemDetector` → `PhotographyDecisionEngine` → `CoreImageRenderer` →
`QualityCheckService` → diagnostics/stage previews → user-confirmed save.

Every renderer parameter listed in the recipe is connected to a pixel operation. Preview and
JPEG export share `CoreImageRenderer.processImage`; the original is never overwritten.

## Current verified capabilities

- Oriented full-resolution sRGB rendering with canvas checks and metadata preservation.
- Global exposure, highlight/shadow, black/white shaping and two tone-curve stages.
- White balance, vibrance, global saturation, three-way grade and hue-range HSL.
- Vision face/person/saliency masks, semantic sky mask, subject/face relighting and sky treatment.
- Luminance-zone highlight protection and recoverable-shadow lift.
- Noise/detail proxies, scene labels, spatial light zones, bright-source connected components.
- Quality checks for geometry, black coverage, highlight spread, color cast, noise amplification,
  over-sharpening and expanded white clipping.

## Important limitations

- Scene understanding is still flattened into one `SemanticScene`/`SceneStrategy`; Vision labels
  are retained but not modeled as a structured multi-label context.
- Lighting condition, direction and photographic style are inferred indirectly inside decision
  rules instead of represented as first-class data.
- Reliable masks exist for person, face, skin capture, sky and saliency. There are no verified
  semantic masks for hair, road, water, vegetation or buildings.
- Quality validation performs one safe fallback, not bounded parameter-specific reprocessing.
- The repository has finished reference images but no matching unedited originals. Reference
  metrics are real; end-to-end photographic acceptance remains a phone test.

