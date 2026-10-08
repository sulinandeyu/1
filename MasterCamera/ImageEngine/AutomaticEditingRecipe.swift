import Foundation

struct AutomaticEditingRecipe: Equatable, Sendable {
    var exposureEV: Float
    var highlightAmount: Float
    var shadowAmount: Float
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var vibrance: Float
    var noiseReductionAmount: Float
    var sharpeningAmount: Float
    var faceExposureEV: Float

    static let naturalEnhancement = AutomaticEditingRecipe(
        exposureEV: 0.08,
        highlightAmount: 0.72,
        shadowAmount: 0.34,
        brightness: 0.0,
        contrast: 1.045,
        saturation: 1.035,
        vibrance: 0.18,
        noiseReductionAmount: 0.018,
        sharpeningAmount: 0.24,
        faceExposureEV: 0.0
    )

    static let safeFallback = AutomaticEditingRecipe(
        exposureEV: 0.04,
        highlightAmount: 0.74,
        shadowAmount: 0.28,
        brightness: 0.0,
        contrast: 1.02,
        saturation: 1.01,
        vibrance: 0.08,
        noiseReductionAmount: 0.012,
        sharpeningAmount: 0.14,
        faceExposureEV: 0.0
    )

    func clamped() -> AutomaticEditingRecipe {
        AutomaticEditingRecipe(
            exposureEV: exposureEV.clamped(to: -0.35...0.35),
            highlightAmount: highlightAmount.clamped(to: 0.32...0.92),
            shadowAmount: shadowAmount.clamped(to: 0.16...0.68),
            brightness: brightness.clamped(to: -0.06...0.06),
            contrast: contrast.clamped(to: 0.96...1.14),
            saturation: saturation.clamped(to: 0.96...1.08),
            vibrance: vibrance.clamped(to: 0.05...0.32),
            noiseReductionAmount: noiseReductionAmount.clamped(to: 0.0...0.06),
            sharpeningAmount: sharpeningAmount.clamped(to: 0.08...0.34),
            faceExposureEV: faceExposureEV.clamped(to: 0.0...0.28)
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
