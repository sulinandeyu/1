# Development roadmap

## V7 stages and acceptance

1. **Audit and documentation** — trace every call and state proven limitations. Acceptance:
   documents match code and never claim unavailable masks or tests.
2. **Structured understanding** — introduce multi-label scene, lighting, subject, quality and
   aesthetic records. Acceptance: diagnostics expose them and decision consumes them.
3. **Dynamic global processing** — compute parameters from measurements plus goals, not preset
   tables alone. Acceptance: parameter sensitivity tests cover brightness/highlights/color cast.
4. **Local processing** — use verified person/face/skin/sky masks and luminance masks; explicitly
   record skipped unavailable semantics. Acceptance: module log names the mask and adjustment.
5. **Portrait** — retain identity and texture, face-metered exposure and skin-range protection.
   Acceptance: no geometry-changing operation exists and sharpening is texture constrained.
6. **Feedback validation** — map quality issues to one bounded recipe correction. Acceptance:
   retry count is capped and failures remain explicit.
7. **Real samples** — Original/Edited/recipe/local log/quality result for required scenes.
   Acceptance: no UI screenshot is used as an Original; unsupported scenes remain unverified.

## Performance budget

- One full Vision/Core ML analysis per input.
- At most two full-resolution renders after quality feedback.
- Reuse `CIContext`; avoid intermediate bitmap materialization.
- Keep masks at analysis resolution and scale only as lazy CIImages.
- Record elapsed time and physical footprint on device.

