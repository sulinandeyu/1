# Photography Parameter Inverse Solver

This is an isolated Windows research tool. It answers one narrow question:
given a source photograph and a registered professional target made from the
same frame, can the parameter vocabulary currently exposed by `CoreImageRenderer`
approximate the target without copying target pixels into the result?

It does **not** run in the camera, select a look for a new photograph, train a
model, or prove iPhone/Core Image parity. The rendered result is always produced
from the source photo through the declared tone, colour and mask operations.

## Autumn-street experiment

```powershell
C:\Users\suqing\AppData\Local\Python\bin\python.exe `
  PhotographyInverseSolver\inverse_solver.py `
  --source "Build27_真机测试\01_原图.jpg" `
  --target "Build27_真机测试\03_抖音博主后期参考.jpg" `
  --mask-dir "tmp\build29_diagnostic_411c710221\masks" `
  --output "output\inverse_solver\autumn_street" `
  --max-evaluations 150
```

The output directory contains the registered A/T pair, the global-only and
global-plus-local renders, parameters, region metrics, registration evidence,
valid masks and an A/T/R contact sheet.

## Fidelity boundary

The tool reproduces the public mathematics visible in the Swift source:

- extended-linear sRGB working values and sRGB output;
- `CIExposureAdjust`'s EV scale;
- the declared black-point polynomial;
- the seven-anchor tone mapper sampled into the same 32³ cube and Core Image's
  linear lattice interpolation;
- the continuous HSL hue weights used by `ProfessionalHSLProcessor`;
- mask feathering, regional exposure/contrast/saturation and alpha blending.

HSL uses the app's perceptual 32³ cube: each extended-linear lattice point is
encoded to sRGB for HSV adjustment, converted back to linear, and then sampled
with trilinear interpolation. Local blending remains in the linear working
domain, with sRGB encoding only at output. `CIColorControls`,
`CIHighlightShadowAdjust`, `CITemperatureAndTint`, and
`CIToneCurve` are Apple implementations whose full transfer functions are not
available on Windows. The inverse experiment therefore keeps highlight/shadow
and white balance neutral and labels colour-controls parity as provisional.
An Apple/Core Image pixel-parity test is required before moving solved values
into an iPhone diagnostic recipe.

