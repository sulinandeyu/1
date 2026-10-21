import Foundation

struct AutomaticEditingRecipe: Equatable, Sendable {
    var exposureEV: Float
    var highlightAmount: Float
    var shadowAmount: Float
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var vibrance: Float
    var temperatureShift: Float
    var tintShift: Float
    var toneCurveAmount: Float
    var noiseReductionAmount: Float
    var sharpeningAmount: Float
    var skinTextureProtection: Float
    var vignetteIntensity: Float
    var subjectExposureEV: Float
    var faceExposureEV: Float

    static let naturalEnhancement = AutomaticEditingRecipe(
        exposureEV: 0.0,
        highlightAmount: 1.0,
        shadowAmount: 0.0,
        brightness: 0.0,
        contrast: 1.0,
        saturation: 1.0,
        vibrance: 0.0,
        temperatureShift: 0.0,
        tintShift: 0.0,
        toneCurveAmount: 0.0,
        noiseReductionAmount: 0.0,
        sharpeningAmount: 0.0,
        skinTextureProtection: 0.0,
        vignetteIntensity: 0.0,
        subjectExposureEV: 0.0,
        faceExposureEV: 0.0
    )

    static let safeFallback = AutomaticEditingRecipe(
        exposureEV: 0.0,
        highlightAmount: 0.92,
        shadowAmount: 0.08,
        brightness: 0.0,
        contrast: 1.01,
        saturation: 1.0,
        vibrance: 0.03,
        temperatureShift: 0.0,
        tintShift: 0.0,
        toneCurveAmount: 0.08,
        noiseReductionAmount: 0.006,
        sharpeningAmount: 0.08,
        skinTextureProtection: 0.0,
        vignetteIntensity: 0.0,
        subjectExposureEV: 0.0,
        faceExposureEV: 0.0
    )

    func clamped() -> AutomaticEditingRecipe {
        AutomaticEditingRecipe(
            exposureEV: exposureEV.clamped(to: -0.35...0.35),
            highlightAmount: highlightAmount.clamped(to: 0.32...1.0),
            shadowAmount: shadowAmount.clamped(to: 0.0...0.68),
            brightness: brightness.clamped(to: -0.06...0.06),
            contrast: contrast.clamped(to: 0.96...1.14),
            saturation: saturation.clamped(to: 0.96...1.08),
            vibrance: vibrance.clamped(to: 0.0...0.32),
            temperatureShift: temperatureShift.clamped(to: -600.0...600.0),
            tintShift: tintShift.clamped(to: -15.0...15.0),
            toneCurveAmount: toneCurveAmount.clamped(to: 0.0...1.0),
            noiseReductionAmount: noiseReductionAmount.clamped(to: 0.0...0.06),
            sharpeningAmount: sharpeningAmount.clamped(to: 0.0...0.34),
            skinTextureProtection: skinTextureProtection.clamped(to: 0.0...0.8),
            vignetteIntensity: vignetteIntensity.clamped(to: 0.0...0.35),
            subjectExposureEV: subjectExposureEV.clamped(to: 0.0...0.22),
            faceExposureEV: faceExposureEV.clamped(to: 0.0...0.28)
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
