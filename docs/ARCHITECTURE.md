# Architecture

## Runtime layers

1. **Capture and import** — camera services and PhotosPicker produce immutable original data.
2. **Understanding** — `PhotoAnalyzer` performs one decode and derives technical statistics,
   Vision observations and available semantic masks.
3. **Diagnosis** — `PhotoProblemDetector` converts measurements into evidence-backed problems.
4. **Decision** — `PhotographyDecisionEngine` produces one clamped, explainable recipe.
5. **Rendering** — `CoreImageRenderer` applies ordered full-resolution global/local stages.
6. **Validation** — `QualityCheckService` compares original and edited measurements.
7. **Presentation/storage** — the same edited bytes drive preview and optional Photo Library save.

## Invariants

- Decode orientation once, translate to a zero-origin canvas, and crop every unbounded filter.
- Analysis does not mutate pixels. Decisions do not render. Renderers do not invent semantics.
- Local processing requires a verified mask or a continuous luminance mask.
- Missing semantic evidence degrades to conservative global processing.
- A failed quality result is never silently labelled as a successful AI image.
- Expensive Vision/Core ML work runs once per photo; recipe retries reuse analysis.

## V7 extension points

- `PhotographyContext`: multi-label scene, lighting, subject, quality and aesthetic features.
- `ProfessionalEditingRecipe`: global and explicit local operations derived from the context.
- bounded feedback loop: render → validate → parameter-specific correction → render once more.

