# MasterCamera Development Requirements

## 1. Product Positioning

MasterCamera is an AI automatic photographer camera app.

The user should only need to:

1. Frame the subject.
2. Tap the shutter.

After capture, the app analyzes the photo, decides what a professional photographer would adjust, and outputs two images:

- `Original`: the untouched captured photo.
- `AI Edited`: a natural, professionally processed version.

The product must feel like computational photography, not like a generative image toy.

## 2. Core Principle

### Real Photo First

MasterCamera must preserve the real photo as the foundation.

The first-class workflow is:

```text
Capture photo
Analyze image content
Create editing recipe
Apply deterministic image processing
Quality check
Save Original + AI Edited
```

The app must not be designed as:

```text
Capture photo
Send whole image to diffusion model
Regenerate a new picture
```

Generative AI may be added later only as a local, limited repair or enhancement tool when traditional computational photography cannot solve a specific issue.

## 3. MVP Goal

The MVP should prove one thing:

A normal user can take an ordinary phone photo, and MasterCamera can automatically produce a visibly better but still natural result.

The MVP does not need accounts, cloud sync, social sharing, paid subscriptions, community feeds, or complex editing UI.

## 4. Target Platform

- Platform: iOS
- Minimum OS: iOS 17+
- Language: Swift
- UI: SwiftUI
- Camera: AVFoundation
- Image processing: Core Image
- Future GPU path: Metal
- Architecture: MVVM plus Service / Engine layering
- Third-party dependencies: none in Phase 1

## 5. High-Level Architecture

```text
MasterCamera
├── App
├── Camera
├── Models
├── Views
├── ViewModels
├── ImageEngine
├── Storage
├── Utilities
├── Analysis              # Later phase
├── PhotographerAI        # Later phase
└── Rendering             # Later phase
```

### Camera

Owns AVFoundation capture setup, camera permission, session lifecycle, preview, camera switching, focus, exposure, and photo capture.

### Analysis

Later module. It will inspect scene type, face regions, subject, sky, exposure, white balance, lighting, noise, blur, and composition.

### PhotographerAI

Later module. It will convert image analysis into a structured editing recipe.

Example:

```text
Outdoor backlit portrait:
- Protect sky highlights
- Lift face exposure locally
- Warm skin tone slightly
- Avoid global HDR look
- Add subtle contrast curve
```

### ImageEngine

Executes image adjustments with Core Image first, and later Metal where performance or precision requires it.

### Storage

Saves original and edited images, with metadata that can link both outputs to the same capture.

## 6. Phase 1 Scope: Camera Foundation

Phase 1 must establish a stable native iOS camera foundation.

It must not implement:

- AI analysis
- AI APIs
- Generative image editing
- Beauty filters
- Manual editing tools
- Social features
- Accounts
- Subscriptions

### Phase 1 Required Features

- Request camera permission.
- Show a live camera preview.
- Start the rear camera by default.
- Switch between front and rear cameras.
- Capture a still photo.
- Display the captured photo in a preview screen.
- Save the original photo to the user's photo library.
- Keep UI responsive while the capture session runs.
- Handle denied camera permission.
- Keep code organized for future AI and image engine modules.

### Phase 1 Nice-To-Have Features

- Tap to focus.
- Tap to expose.
- Capture animation.
- Basic error messaging.
- Simple logging.

## 7. Phase 1 Directory Structure

```text
MasterCamera/
├── App/
│   └── MasterCameraApp.swift
├── Camera/
│   ├── CameraManager.swift
│   ├── CameraPermissionManager.swift
│   ├── CameraPreview.swift
│   └── PhotoCaptureService.swift
├── ImageEngine/
│   └── CoreImageRenderer.swift
├── Models/
│   ├── CameraState.swift
│   └── CapturedPhoto.swift
├── Storage/
│   └── PhotoLibraryManager.swift
├── Utilities/
│   └── Logger.swift
├── ViewModels/
│   └── CameraViewModel.swift
└── Views/
    ├── CameraView.swift
    └── PhotoPreviewView.swift
```

## 8. Phase 1 Acceptance Criteria

The phase is complete when:

- The app has a native SwiftUI entry point.
- The camera permission flow is implemented.
- The camera preview is backed by `AVCaptureVideoPreviewLayer`.
- A real `AVCaptureSession` is configured.
- The app can capture JPEG photo data through `AVCapturePhotoOutput`.
- Captured photos can be previewed in-app.
- Captured original photos can be saved to the photo library.
- The code has clear boundaries between View, ViewModel, Camera service, and Storage service.
- No AI, filter, beauty, or generation logic is mixed into the camera foundation.

## 9. Future Development Phases

### Phase 2: First Image Engine

- Add deterministic auto enhancement.
- Implement exposure, highlights, shadows, contrast, white balance, vibrance, sharpening, and denoising.
- Output `Original` and `AI Edited`.

#### Phase 2 Scope Detail

Phase 2 introduces the first non-generative image pipeline.

It must still not use:

- External AI APIs
- Diffusion models
- Face reshaping
- Beauty filters
- Manual editing sliders

The Phase 2 pipeline should:

1. Keep the original JPEG data untouched.
2. Create a separate edited JPEG using Core Image.
3. Apply a conservative default recipe that improves the photo without making it look artificial.
4. Save both images as independent assets.
5. Keep the output natural enough that it reads as a better photo, not an AI-generated image.

The first recipe is intentionally simple. In Phase 4 and later, `PhotographerAI` owns recipe selection and explains the decision.

Recommended default recipe:

- Exposure: slight lift.
- Highlights: modest recovery.
- Shadows: modest lift.
- Saturation: slight increase.
- Vibrance: moderate increase.
- Contrast: slight increase.
- Noise reduction: light.
- Sharpening: light.

Phase 2 acceptance criteria:

- A capture produces both `Original` and `AI Edited` data.
- The preview can switch between the original and edited result.
- Saving writes both images to the photo library.
- The original image data remains unchanged.
- The image engine code remains separate from camera capture code.

### Phase 3: Scene Analysis

- Add Vision/Core Image based scene and quality analysis.
- Detect faces, subject areas, exposure issues, blur, noise, and dominant color cast.

#### Phase 3 Scope Detail

Phase 3 introduces the first local analysis layer. It is not a general visual intelligence system yet.

It should analyze:

- Average luminance.
- Rough contrast range.
- Red / green / blue channel balance.
- Basic color cast.
- Face count through Vision face detection.

The analysis output should be a structured model that later modules can reuse.

Phase 3 acceptance criteria:

- Captured photos are analyzed before rendering `AI Edited`.
- The edit recipe is generated from the analysis result.
- Underexposed photos receive more lift than balanced photos.
- Overexposed photos receive more highlight protection.
- Low contrast photos receive slightly stronger contrast and detail.
- Face-containing photos receive conservative saturation and sharpening.
- Analysis code remains separate from camera capture and UI code.

### Phase 4: Photographer Decision Engine

- Convert analysis results into structured editing recipes.
- Add scene strategies for portrait, food, landscape, night, indoor, backlit, and architecture.

#### Phase 4 Scope Detail

Phase 4 introduces the first `PhotographerAI` decision layer.

The decision layer should sit between `Analysis` and `ImageEngine`:

```text
PhotoAnalysis
PhotographyDecisionEngine
PhotographyDecision
AutomaticEditingRecipe
CoreImageRenderer
```

The decision should include:

- Scene strategy.
- Editing intent.
- Human-readable actions and reasons.
- Final `AutomaticEditingRecipe`.

Phase 4 acceptance criteria:

- `ImageEngine` does not decide why to edit.
- `PhotographerAI` owns scene strategy and recipe selection.
- The preview can expose a concise decision summary for debugging.
- The decision model is structured enough to support future AB testing and tuning.

### Phase 5: Local Adjustments

- Add face-aware exposure, skin-tone protection, sky protection, subject/background masks, and localized contrast.

#### Phase 5 Scope Detail

Phase 5 introduces the first local adjustment system.

Initial scope:

- Store face bounding regions from Vision analysis.
- Add a soft mask-based face relighting pass.
- Keep relighting subtle and photographic.
- Apply local face relighting before global tone/color processing.

Out of scope for the first local adjustment pass:

- Face reshaping.
- Skin smoothing.
- Eye enlargement.
- Full portrait segmentation.
- Generative relighting.

Phase 5 acceptance criteria:

- Face regions are stored in `PhotoAnalysis`.
- `PhotographerAI` can request a local face exposure lift.
- `ImageEngine` applies local face relighting through a mask.
- Non-face photos are not affected by the local face path.

### Phase 6: Quality Control

- Add a post-render quality check.
- Detect obviously failed edits.
- Detect images that remain too dark, too bright, too flat, or too harsh after processing.
- Keep the quality result structured for later automatic fallback.

#### Phase 6 Scope Detail

The first quality control layer should not try to judge artistic taste.

It should check:

- Edited image can be decoded and analyzed.
- Average luminance is within a usable range.
- Contrast range is not obviously too low or too high.
- Edited data is not identical to original data.

Phase 6 acceptance criteria:

- Captured photos can carry a `QualityCheckResult`.
- The processing pipeline runs quality control after rendering.
- The preview can show a concise quality status.
- Quality control remains separate from `PhotographerAI` and `ImageEngine`.

### Phase 7: Safe Fallback

- If the first AI edit fails quality control, render a conservative fallback edit.
- Prefer the fallback only when its quality status is better than the initial result.
- Mark fallback usage in `QualityCheckResult`.

Phase 7 acceptance criteria:

- Failed initial edits can trigger a safer second render.
- The app does not silently replace a warning or passing edit.
- The preview can indicate when a fallback was used.

### Phase 8: Processing Pipeline Refactor

- Move capture post-processing orchestration out of `CameraViewModel`.
- Introduce a dedicated processing service for analysis, decision, rendering, quality control, and fallback.
- Keep UI state management separate from image processing policy.

Phase 8 acceptance criteria:

- `CameraViewModel` only coordinates UI state and calls the processing service.
- `PhotoProcessingPipeline` owns the end-to-end post-capture workflow.
- Safe fallback behavior remains unchanged after the refactor.

### Phase 9: Processing State UI

- Show a clear processing overlay after capture while the edited image is generated.
- Disable shutter and camera switching during processing.
- Keep progress copy concise and user-facing.

Phase 9 acceptance criteria:

- `CameraViewModel` exposes a processing state.
- `CameraView` shows a processing overlay.
- Capture controls are disabled while processing.
- Preview is presented only after processing completes.

### Phase 10: Compare Preview UX

- Keep `AI Edited` as the default preview.
- Let the user press and hold the edited photo to temporarily view `Original`.
- Preserve the segmented control for explicit switching.
- Keep analysis, decision, and quality information visible as debug pills while the product is still in development.

Phase 10 acceptance criteria:

- The preview supports quick original/edited comparison.
- The comparison interaction does not change saved output.
- The user can still explicitly switch between `Original` and `AI Edited`.

### Phase 11: Save State UX

- Show a clear saving state when writing original and edited photos to the photo library.
- Disable repeated save taps while saving is in progress.
- Show saved and failed states in Chinese.

Phase 11 acceptance criteria:

- `CameraViewModel` exposes a save state.
- `PhotoPreviewView` disables the save button while saving.
- Save success and failure messages are visible on the preview page.

### Phase 12: Preview Debug Info Toggle

- Hide analysis, decision, and quality debug pills by default on the preview page.
- Add an info button to manually show or hide development details.
- Keep save status visible regardless of debug visibility.

Phase 12 acceptance criteria:

- Preview defaults to a clean product-like result view.
- Debug information remains available for development and tuning.
- The info toggle uses Chinese accessibility labels.

### Phase 13: Diagnostics Panel

- Show structured analysis, decision, and quality information in the preview page.
- Keep the panel hidden by default.
- Use Chinese copy for all user-facing diagnostic text.
- Support later real-photo tuning without changing the main camera flow.

### Phase 14: Advanced Lighting

- Add depth-aware or mask-aware relighting.
- Keep results subtle and photographic.

## 10. Non-Negotiable Product Rules

- Do not alter a person's identity.
- Do not reshape faces by default.
- Do not erase natural skin texture.
- Do not make every output look like the same filter.
- Do not create obvious AI artifacts.
- Do not over-process photos that are already good.
- Always preserve the original capture.

