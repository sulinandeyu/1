# MasterCamera project state

## Shipped baseline

- iOS 17+, SwiftUI, AVFoundation, Core Image, Vision and one bundled semantic Core ML model.
- Camera capture, front/back switching, original preservation, edited JPEG, comparison UI,
  Photos import re-test and Photo Library saving are working.
- TestFlight build 18 contains the Phase 2 diagnostics baseline at commit `9a5488e`.
- The 2026-10-25 environment-portrait and regional-statistics repair is currently a local working-tree
  change and has not yet been compiled or uploaded to TestFlight.

## Effective capture-to-output chain

`CameraManager` → `CameraViewModel` → `PhotoProcessingPipeline` → `PhotoAnalyzer` →
`PhotoProblemDetector` → `PhotographyDirector`/`PhotographyDecisionEngine` → `CoreImageRenderer` →
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
- Structured scene facets and lighting now select the primary strategy before the legacy single
  `SemanticScene` fallback; generic `outdoor` no longer masks coast or architecture evidence.
- Analysis, initial recipe, renderer input and final post-quality recipe now have one continuous
  log trace. The diagnostics recipe is the recipe that actually produced the final JPEG.
- The director now emits an auditable final-look, lighting and regional-treatment plan while the
  connected recipe remains the executable pixel contract.
- Human protection is a final decision guardrail: face-only relighting is disabled, person
  relighting requires a valid person mask, and portrait detail/color changes are bounded.
- Quality control now compares face-region luminance/chroma and texture-energy changes against the
  rest of the image; unsafe portrait edits enter one bounded correction or are rejected.

## 2026-10-22 scene-adaptation repair (working tree)

- Root cause, three real screenshot-pair measurements, code evidence and phone acceptance steps
  are recorded in `docs/SCENE_ADAPTATION_AUDIT.md`.
- The shared cinematic grade is now bounded by photographic context instead of dominating every
  standard scene with the same cool-shadow/warm-highlight baseline.
- Sky exposure/highlight/saturation are continuous functions of measured headroom, contrast and
  saturation; overcast evidence prevents automatic blue enhancement.
- A standalone Swift decision-core test package covers generic-label precedence, semantic recipe
  divergence and overcast-versus-clear sky behavior. CI runs it before the iOS build.
- Local Windows validation is limited to source/static checks. Xcode/Core Image and original-file
  visual acceptance remain pending until the branch runs on macOS and the app re-tests original
  JPEG/HEIC files.

## Important limitations

- Reliable masks exist for person, face, skin capture, sky and saliency. There are no verified
  semantic masks for hair, road, water, vegetation or buildings.
- The primary strategy remains a compatibility enum, but it is now selected from multi-label
  facets and lighting; recipes still need more original-file calibration across all scene types.
- Quality validation permits one bounded issue-specific correction, not iterative aesthetic search.
- The repository has finished references but no committed matching unedited originals. Recovered
  user attachments are App screenshots, so end-to-end photographic acceptance remains a phone test.
- There is no generative retouch model in the app. Current output is deterministic on-device Core
  Image/Vision/Core ML processing; non-person AI restoration remains a future, separately gated phase.

The same-scene Original/MasterCamera/reference pixel audit and the current repair boundary are recorded
in `docs/V6_REAL_IMAGE_REPAIR_2026-10-25.md`.

The 2026-10-24 product-position audit and staged implementation plan are recorded in
`docs/AI_AUTONOMOUS_PHOTOGRAPHER_AUDIT.md`.

