# MasterCamera Cinematic Imaging Engine V3

## Default output target

The automatic output target is now **CINEMATIC AUTO**. The decision engine chooses one of three internal strengths for every image:

- `CINEMATIC NATURAL`: portraits, daily records and already-balanced originals.
- `CINEMATIC STANDARD`: the default for interiors, workspaces, architecture, outdoor daylight and landscapes.
- `CINEMATIC DRAMATIC`: only for suitable night, sunset, street and high-contrast images.

The user does not choose a preset. Scene, dynamic range, clipping risk, saturation and noise risk determine the strength.

## Full-resolution pipeline

1. Decode with EXIF orientation and an extended-linear-sRGB working space.
2. Analyze scene, exposure, dynamic range, color distribution, faces and available masks.
3. Build a per-image editing recipe.
4. Exposure plus recoverable highlight/shadow adjustment.
5. Black-point control and legacy scene curve.
6. Seven-anchor cinematic tone mapping: black, shadow roll-off, lower midtone, midtone, upper midtone, highlight roll-off and white point.
7. White balance and basic color controls.
8. Soft-mask shadow/midtone/highlight color grading and restrained color contrast.
9. Existing subject/face relighting and sky protection.
10. Mask-backed subject/background separation; skipped when Vision has no reliable mask.
11. Local material contrast, adaptive denoise/sharpen and skin texture protection.
12. Highlight-only bloom, restrained warm halation, optional vignette and luminance-weighted monochrome grain.
13. Full-resolution sRGB JPEG rendering with preserved compatible metadata and baked orientation 1.

## Safety rules

- Bloom and halation are reduced when highlights are already clipped.
- Grain, sharpening and local contrast are reduced when noise risk is detected.
- Background separation is disabled without a valid Vision person/saliency mask.
- No object deletion, background reconstruction, identity changes or generative redraw is performed.
- Original and edited files remain separate and are validated through file hashes and decoded pixel diagnostics.

## Validation limitation

The previously supplied living-room and computer-desk files are screenshots of the comparison UI, not original JPEG/HEIC pairs. They remain useful evidence that V2 was too subtle, but cannot provide trustworthy source EXIF or V3 full-resolution quality measurements. Use the in-app “样片复测” entry to import the original files. Portrait, backlight, night and landscape still require real-device visual acceptance.
