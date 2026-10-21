import Foundation

enum ToneCurveStyle: String, Equatable, Sendable {
    case neutral
    case portrait
    case landscape
    case cinematic
    case softHighlights
    case interior
    case workspace
}

enum CinematicIntensity: String, Equatable, Sendable {
    case natural
    case standard
    case dramatic

    var title: String {
        switch self {
        case .natural: return "CINEMATIC NATURAL"
        case .standard: return "CINEMATIC STANDARD"
        case .dramatic: return "CINEMATIC DRAMATIC"
        }
    }
}

enum CinematicToneStyle: String, Equatable, Sendable {
    case natural
    case bright
    case lowKey
}

struct AutomaticEditingRecipe: Equatable, Sendable {
    var exposureEV: Float
    var highlightAmount: Float
    var shadowAmount: Float
    var brightness: Float
    var contrast: Float
    var blackPoint: Float
    var cinematicIntensity: CinematicIntensity
    var cinematicToneStyle: CinematicToneStyle
    var shadowRollOff: Float
    var lowerMidtoneLift: Float
    var midtoneBias: Float
    var upperMidtoneSeparation: Float
    var highlightRollOff: Float
    var whitePoint: Float
    var localContrastAmount: Float
    var saturation: Float
    var vibrance: Float
    var temperatureShift: Float
    var tintShift: Float
    var toneCurveAmount: Float
    var toneCurveStyle: ToneCurveStyle
    var shadowCoolAmount: Float
    var midtoneWarmAmount: Float
    var highlightWarmAmount: Float
    var colorGradeIntensity: Float
    var colorContrast: Float
    var noiseReductionAmount: Float
    var sharpeningAmount: Float
    var skinTextureProtection: Float
    var vignetteIntensity: Float
    var subjectExposureEV: Float
    var faceExposureEV: Float
    var skyExposureEV: Float
    var skyHighlightAmount: Float
    var skySaturation: Float
    var grainAmount: Float
    var bloomIntensity: Float
    var halationIntensity: Float
    var backgroundSeparation: Float

    static let naturalEnhancement = AutomaticEditingRecipe(
        exposureEV: 0.0,
        highlightAmount: 1.0,
        shadowAmount: 0.0,
        brightness: 0.0,
        contrast: 1.0,
        blackPoint: 0.0,
        cinematicIntensity: .natural,
        cinematicToneStyle: .natural,
        shadowRollOff: 0.0,
        lowerMidtoneLift: 0.0,
        midtoneBias: 0.0,
        upperMidtoneSeparation: 0.0,
        highlightRollOff: 0.0,
        whitePoint: 1.0,
        localContrastAmount: 0.0,
        saturation: 1.0,
        vibrance: 0.0,
        temperatureShift: 0.0,
        tintShift: 0.0,
        toneCurveAmount: 0.0,
        toneCurveStyle: .neutral,
        shadowCoolAmount: 0.0,
        midtoneWarmAmount: 0.0,
        highlightWarmAmount: 0.0,
        colorGradeIntensity: 0.0,
        colorContrast: 0.0,
        noiseReductionAmount: 0.0,
        sharpeningAmount: 0.0,
        skinTextureProtection: 0.0,
        vignetteIntensity: 0.0,
        subjectExposureEV: 0.0,
        faceExposureEV: 0.0,
        skyExposureEV: 0.0,
        skyHighlightAmount: 1.0,
        skySaturation: 1.0,
        grainAmount: 0.0,
        bloomIntensity: 0.0,
        halationIntensity: 0.0,
        backgroundSeparation: 0.0
    )

    static let safeFallback = AutomaticEditingRecipe(
        exposureEV: 0.0,
        highlightAmount: 0.92,
        shadowAmount: 0.08,
        brightness: 0.0,
        contrast: 1.01,
        blackPoint: 0.0,
        cinematicIntensity: .natural,
        cinematicToneStyle: .natural,
        shadowRollOff: 0.08,
        lowerMidtoneLift: 0.005,
        midtoneBias: 0.0,
        upperMidtoneSeparation: 0.01,
        highlightRollOff: 0.08,
        whitePoint: 0.985,
        localContrastAmount: 0.04,
        saturation: 1.0,
        vibrance: 0.03,
        temperatureShift: 0.0,
        tintShift: 0.0,
        toneCurveAmount: 0.08,
        toneCurveStyle: .softHighlights,
        shadowCoolAmount: 0.0,
        midtoneWarmAmount: 0.0,
        highlightWarmAmount: 0.0,
        colorGradeIntensity: 0.0,
        colorContrast: 0.0,
        noiseReductionAmount: 0.006,
        sharpeningAmount: 0.08,
        skinTextureProtection: 0.0,
        vignetteIntensity: 0.0,
        subjectExposureEV: 0.0,
        faceExposureEV: 0.0,
        skyExposureEV: 0.0,
        skyHighlightAmount: 1.0,
        skySaturation: 1.0,
        grainAmount: 0.0,
        bloomIntensity: 0.0,
        halationIntensity: 0.0,
        backgroundSeparation: 0.0
    )

    func clamped() -> AutomaticEditingRecipe {
        AutomaticEditingRecipe(
            exposureEV: exposureEV.clamped(to: -0.35...0.35),
            highlightAmount: highlightAmount.clamped(to: 0.32...1.0),
            shadowAmount: shadowAmount.clamped(to: 0.0...0.68),
            brightness: brightness.clamped(to: -0.06...0.06),
            contrast: contrast.clamped(to: 0.96...1.14),
            blackPoint: blackPoint.clamped(to: 0.0...0.035),
            cinematicIntensity: cinematicIntensity,
            cinematicToneStyle: cinematicToneStyle,
            shadowRollOff: shadowRollOff.clamped(to: 0.0...1.0),
            lowerMidtoneLift: lowerMidtoneLift.clamped(to: -0.08...0.12),
            midtoneBias: midtoneBias.clamped(to: -0.08...0.08),
            upperMidtoneSeparation: upperMidtoneSeparation.clamped(to: -0.06...0.1),
            highlightRollOff: highlightRollOff.clamped(to: 0.0...1.0),
            whitePoint: whitePoint.clamped(to: 0.88...1.0),
            localContrastAmount: localContrastAmount.clamped(to: 0.0...0.45),
            saturation: saturation.clamped(to: 0.96...1.08),
            vibrance: vibrance.clamped(to: 0.0...0.32),
            temperatureShift: temperatureShift.clamped(to: -600.0...600.0),
            tintShift: tintShift.clamped(to: -15.0...15.0),
            toneCurveAmount: toneCurveAmount.clamped(to: 0.0...1.0),
            toneCurveStyle: toneCurveStyle,
            shadowCoolAmount: shadowCoolAmount.clamped(to: 0.0...1.0),
            midtoneWarmAmount: midtoneWarmAmount.clamped(to: 0.0...1.0),
            highlightWarmAmount: highlightWarmAmount.clamped(to: 0.0...1.0),
            colorGradeIntensity: colorGradeIntensity.clamped(to: 0.0...1.0),
            colorContrast: colorContrast.clamped(to: 0.0...0.5),
            noiseReductionAmount: noiseReductionAmount.clamped(to: 0.0...0.06),
            sharpeningAmount: sharpeningAmount.clamped(to: 0.0...0.34),
            skinTextureProtection: skinTextureProtection.clamped(to: 0.0...0.8),
            vignetteIntensity: vignetteIntensity.clamped(to: 0.0...0.35),
            subjectExposureEV: subjectExposureEV.clamped(to: 0.0...0.3),
            faceExposureEV: faceExposureEV.clamped(to: 0.0...0.42),
            skyExposureEV: skyExposureEV.clamped(to: -0.2...0.08),
            skyHighlightAmount: skyHighlightAmount.clamped(to: 0.4...1.0),
            skySaturation: skySaturation.clamped(to: 0.96...1.08),
            grainAmount: grainAmount.clamped(to: 0.0...0.12),
            bloomIntensity: bloomIntensity.clamped(to: 0.0...0.18),
            halationIntensity: halationIntensity.clamped(to: 0.0...0.1),
            backgroundSeparation: backgroundSeparation.clamped(to: 0.0...0.18)
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
