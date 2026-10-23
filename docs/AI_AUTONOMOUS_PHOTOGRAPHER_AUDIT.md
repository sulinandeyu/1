# MasterCamera AI Autonomous Photographer — architecture audit

Date: 2026-10-24

## Product boundary

MasterCamera is an automatic photography and controlled photographic post-production system. It
must preserve the captured scene, the original file and human identity. It is not a beauty camera
and must not turn a photograph into generated artwork.

The supplied reference JPEGs are used only to extract photographic principles. They are not LUTs,
training data or generation inputs, and their people, objects and backgrounds must never be copied
into a user's photograph.

## Current executable chain

`CameraManager` → `CameraViewModel` → `PhotoProcessingPipeline.process` →
`PhotoAnalyzer.analyze` → `PhotoProblemDetector.detect` → `PhotographyDirector.direct` →
`CoreImageRenderer.processImage` → `QualityCheckService.check` → one bounded corrective render →
diagnostics/preview → user-confirmed save.

The renderer really executes exposure, highlight/shadow recovery, two curve systems, white balance,
HSL, three-way color grading, luminance-zone work, person/subject relighting, sky treatment,
background separation, local contrast, denoise, sharpen, texture restoration and limited lens
character. The original `Data` is retained separately and is never overwritten.

## Reference-derived photographic principles

The measurements below were computed locally from 128 × 128 downsampled versions of the supplied
JPEGs. They are evidence for scene diversity, not target values to copy.

| Reference | Mean luminance | Shadow ratio | Mean saturation | Mean RGB | Useful principle |
| --- | ---: | ---: | ---: | --- | --- |
| autumn night path | 0.139 | 0.599 | 0.534 | 0.159/0.138/0.091 | keep night black; use warm practical light and path depth |
| waterfront bridge night | 0.208 | 0.331 | 0.351 | 0.242/0.202/0.169 | protect point lights and reflections; do not flatten water |
| dense city night | 0.233 | 0.292 | 0.184 | 0.225/0.234/0.252 | preserve cool urban structure and layered distance |
| warm bedroom | 0.209 | 0.309 | 0.454 | 0.249/0.202/0.159 | retain practical-lamp warmth while controlling screen/lamp highlights |
| desk detail | 0.220 | 0.372 | 0.460 | 0.255/0.214/0.175 | distinguish material, black level and local light pools |
| blue-hour portraits* | 0.324 / 0.411 | 0.365 / 0.200 | 0.360 / 0.332 | cool-biased | preserve the cool environment and real identity; no face beautification |

\* The portrait files contain white gallery borders/UI, so their whole-frame highlight ratios are
not used as camera-scene measurements.

## Gap audit

### Already reusable

- Capture, original preservation, edited output, comparison and save flows.
- Local numeric analysis, Vision scene labels, face/person/saliency masks and sky segmentation.
- Evidence-driven problem diagnosis and continuously variable scene recipes.
- A single renderer used by final JPEG and stage preview, preventing a “JSON says one thing,
  output does another” split.
- Relative quality checks and a single issue-specific corrective render.

### Critical gaps against the new positioning

1. **The director was implicit.** `PhotographyDecisionEngine` selected parameters, but there was no
   explicit contract for final look, lighting design, regional objectives and non-negotiable human
   protection. This made it difficult to audit why a parameter existed.
2. **Face-specific brightening contradicted the product rule.** `applySceneStrategy` and
   `applyContextStrategy` could set `faceExposureEV` merely because a face was detected. Even though
   the operation was photographic exposure rather than geometry, the new requirement explicitly
   disallows automatic face brightening.
3. **Human protection was mainly a renderer technique, not a final policy.** Texture restoration
   existed, but later scene/context decisions could still request face-local exposure, high detail
   or orange luminance changes.
4. **Quality control was global.** It checked clipping, color cast, noise and detail, but did not
   compare face-region changes against the rest of the frame. It therefore could not reject a
   portrait that passed whole-image metrics while disproportionately changing the face.
5. **Local masks are incomplete.** Person, face, skin, sky and saliency are available; road, ground,
   water, vegetation and building masks are not yet verified. The system cannot honestly claim a
   complete Photoshop-style local workflow for those regions.
6. **No generative retouch model is integrated.** This is currently a safety advantage. The app
   performs deterministic on-device processing only. Any future AI inpainting/restoration must be
   separately selected, licensed, benchmarked and blocked from people by a verified mask. A prompt
   or parameter JSON is not implementation.
7. **Reference acceptance is incomplete.** The supplied images are finished references rather than
   matched unedited/edited pairs. They can validate aesthetic direction and policy, but cannot prove
   end-to-end improvement of an unknown original.

## Phased implementation

### Phase 1 — auditable director and human safety (implemented in this change)

- Add `PhotographyDirector` as the pipeline entry point.
- Add `PhotographyTreatmentPlan` with final look, lighting design, regional objectives and strict
  portrait policy; keep `AutomaticEditingRecipe` as the executable pixel contract.
- Apply a final portrait guardrail after all scene/context rules: disable face-only exposure,
  require a valid person mask for person relighting, cap person exposure/detail processing, remove
  orange-luminance lifting and increase real-texture restoration.
- Add face-region quality checks for disproportionate luminance/chroma changes and abnormal texture
  energy. These failures participate in the existing one-pass bounded correction and can reject an
  unsafe result.
- Expose the director plan and portrait policy in the diagnostic panel.

Acceptance: decision-core tests must prove different real-reference measurements produce different
plans; every face-containing fixture must have `faceExposureEV == 0`, strict non-generative/non-
geometric policy and bounded person exposure.

### Phase 2 — verified semantic local workflow

- Generalize the bundled semantic model adapter from sky-only output to separately validated masks
  for road/ground, water, vegetation and buildings where model labels and edge quality are adequate.
- Introduce per-region tone/color operations with feathering, overlap priority and mask confidence.
- Do not run a regional adjustment when its mask fails coverage, edge-contact or confidence checks.

Acceptance: original-size tests on at least landscape, coast, autumn path, architecture and indoor
photos; save mask previews and regional before/after metrics; reject halos and cross-region leakage.

### Phase 3 — color-management and capture-quality foundation

- Evaluate HEIF/RAW capture paths, wide-gamut/linear working space, lens metadata and device noise
  characteristics. Preserve the current JPEG path as the compatibility baseline.
- Calibrate tone curves, HSL and denoise/sharpen against a versioned original-photo corpus rather
  than finished screenshots.

Acceptance: no geometry/orientation/metadata regressions; stable highlights and color across
supported iPhones; measured performance and memory budgets.

### Phase 4 — optional bounded AI restoration

- Select a concrete on-device model only for non-person micro-defects that deterministic tools
  cannot solve. Record model, license, runtime, device requirements and latency.
- Expand the person/face/skin mask to a fail-closed exclusion zone. If exclusion cannot be proven,
  skip the model.
- Never generate structures, people, plants or scene content.

Acceptance: pixel-level proof that excluded human regions are unchanged, plus human review for
generated artifacts and scene falsification.

### Phase 5 — photographic quality evaluation

- Add scene-specific quality targets, reference-free technical checks and blinded human ranking.
- Keep correction bounded. A failed edit is rejected; the system must not loop until it produces an
overprocessed image.

Acceptance: matched original/output sets covering daylight, overcast, night, indoor, landscape,
architecture and diverse people; report improvements and regressions by scene, not one aggregate.

## Immediate non-claims

- This phase does not claim full AI retouching, road/water/building semantic masks or professional
  quality across all scenes.
- The director plan is valuable because it governs real renderer parameters and safety checks, not
  because it is a richer prompt.
- Final photographic acceptance still requires original camera files and iPhone/TestFlight visual
  review; reference images alone cannot establish the before/after result.
