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

/// 专业分区调色参数。数值是相对调整量，0 表示不改变该色域。
struct ProfessionalHSLAdjustment: Equatable, Sendable {
    var orangeSaturation: Float
    var orangeLuminance: Float
    var yellowSaturation: Float
    var yellowLuminance: Float
    var greenSaturation: Float
    var greenLuminance: Float
    var cyanSaturation: Float
    var cyanLuminance: Float
    var blueSaturation: Float
    var blueLuminance: Float

    static let neutral = ProfessionalHSLAdjustment(
        orangeSaturation: 0, orangeLuminance: 0,
        yellowSaturation: 0, yellowLuminance: 0,
        greenSaturation: 0, greenLuminance: 0,
        cyanSaturation: 0, cyanLuminance: 0,
        blueSaturation: 0, blueLuminance: 0
    )

    func clamped() -> ProfessionalHSLAdjustment {
        ProfessionalHSLAdjustment(
            orangeSaturation: orangeSaturation.clamped(to: -0.18...0.18),
            orangeLuminance: orangeLuminance.clamped(to: -0.08...0.08),
            yellowSaturation: yellowSaturation.clamped(to: -0.18...0.18),
            yellowLuminance: yellowLuminance.clamped(to: -0.08...0.08),
            greenSaturation: greenSaturation.clamped(to: -0.2...0.2),
            greenLuminance: greenLuminance.clamped(to: -0.08...0.08),
            cyanSaturation: cyanSaturation.clamped(to: -0.2...0.16),
            cyanLuminance: cyanLuminance.clamped(to: -0.08...0.08),
            blueSaturation: blueSaturation.clamped(to: -0.2...0.16),
            blueLuminance: blueLuminance.clamped(to: -0.08...0.08)
        )
    }
}

/// A measured, mask-backed local adjustment. This is intentionally derived from
/// the current photo rather than stored as a scene preset. Both the director and
/// renderer call the same factory so the documented plan cannot drift from the
/// pixels that are actually rendered.
struct RegionalPixelAdjustment: Equatable, Sendable {
    let region: TreatmentRegion
    let exposureEV: Float
    let highlightAmount: Float
    let shadowAmount: Float
    let contrast: Float
    let saturation: Float
    let temperatureShift: Float
    let clarity: Float
    let confidence: Float
    let reason: String
    let fallback: String

    static func make(
        region: TreatmentRegion,
        analysis: PhotoAnalysis,
        recipe: AutomaticEditingRecipe
    ) -> RegionalPixelAdjustment? {
        guard analysis.faceCount == 0 || analysis.personMask?.isValid == true else {
            return nil
        }
        guard analysis.segmentationDiagnostics.status != .failed else { return nil }

        let mask: NormalizedPhotoMask?
        let statistics: PhotoRegionStatistics?
        switch region {
        case .ground:
            mask = analysis.groundMask
            statistics = analysis.groundStatistics
        case .vegetation:
            mask = analysis.vegetationMask
            statistics = analysis.vegetationStatistics
        case .water:
            mask = analysis.waterMask
            statistics = analysis.waterStatistics
        case .architecture:
            mask = analysis.architectureMask
            statistics = analysis.architectureStatistics
        default:
            return nil
        }

        guard
            let mask,
            mask.isValid,
            mask.activeCoverage >= 0.004,
            mask.activeCoverage <= 0.86,
            let statistics
        else { return nil }

        let facets = Set(analysis.photographyContext.sceneFacets)
        let semanticMatch: Bool
        switch region {
        case .ground:
            semanticMatch = true
        case .vegetation:
            semanticMatch = !facets.isDisjoint(with: [.forest, .countryRoad, .nature])
        case .water:
            semanticMatch = !facets.isDisjoint(with: [.water, .coast])
        case .architecture:
            semanticMatch = !facets.isDisjoint(with: [.architecture, .city, .street, .interior, .workspace])
        default:
            semanticMatch = false
        }
        guard semanticMatch else { return nil }

        let recognitionConfidence: Float
        switch analysis.sceneRecognitionDiagnostics.status {
        case .recognized:
            recognitionConfidence = max(0.55, analysis.sceneRecognitionDiagnostics.topConfidence)
        case .uncertain:
            recognitionConfidence = 0.48
        case .failed:
            recognitionConfidence = 0.42
        case .notEvaluated:
            recognitionConfidence = 0.58
        }
        let coverageConfidence = min(1, max(0.42, mask.activeCoverage * 3.2))
        let confidence = min(1, recognitionConfidence * coverageConfidence)
        let isNight = analysis.photographyContext.lightingConditions.contains(.night)

        var exposureEV: Float = 0
        var highlightAmount: Float = 1
        var shadowAmount: Float = 0
        var contrast: Float = 1
        var saturation: Float = 1
        var temperatureShift: Float = 0
        var clarity: Float = 0
        let reason: String

        switch region {
        case .ground:
            let targetLuminance: Float = isNight ? 0.24 : 0.38
            exposureEV = ((targetLuminance - statistics.averageLuminance) * 0.62)
                .clamped(to: -0.07...0.14)
            shadowAmount = ((statistics.shadowRatio - 0.16) * 0.42)
                .clamped(to: 0...0.2)
            contrast = 1 + ((0.56 - statistics.contrastRange) * 0.16)
                .clamped(to: 0...0.075)
            clarity = min(0.075, max(0, recipe.localContrastAmount * 0.55))
            reason = statistics.averageLuminance < targetLuminance
                ? "地面实测偏暗，恢复可用阴影并建立道路或前景层次。"
                : "地面曝光已足够，仅补充克制的材质层次。"
        case .vegetation:
            let targetLuminance: Float = isNight ? 0.22 : 0.34
            exposureEV = ((targetLuminance - statistics.averageLuminance) * 0.48)
                .clamped(to: -0.055...0.105)
            shadowAmount = ((statistics.shadowRatio - 0.2) * 0.34)
                .clamped(to: 0...0.16)
            contrast = 1 + ((0.54 - statistics.contrastRange) * 0.14)
                .clamped(to: 0...0.065)
            let saturationDelta = ((0.3 - statistics.averageSaturation) * 0.24)
                .clamped(to: -0.065...0.075)
            saturation = isNight ? min(1, 1 + saturationDelta) : 1 + saturationDelta
            temperatureShift = facets.contains(.countryRoad) && !isNight ? 38 : 0
            clarity = min(0.065, max(0, recipe.localContrastAmount * 0.46))
            reason = "依据植被区域自身的亮度、饱和度和纹理余量调整绿黄关系，不对全图统一增绿或增黄。"
        case .water:
            exposureEV = ((0.36 - statistics.averageLuminance) * 0.28)
                .clamped(to: -0.045...0.065)
            highlightAmount = (1 - max(0, statistics.highlightRatio - 0.08) * 1.3)
                .clamped(to: 0.72...1)
            contrast = 1 + ((0.5 - statistics.contrastRange) * 0.11)
                .clamped(to: 0...0.045)
            saturation = 1 + ((0.27 - statistics.averageSaturation) * 0.16)
                .clamped(to: -0.045...0.05)
            temperatureShift = analysis.photographyContext.lightingConditions.contains(.blueHour) ? -28 : 0
            clarity = min(0.04, max(0, recipe.localContrastAmount * 0.28))
            reason = "依据水面自身高光、反射和饱和度控制层次，避免把真实反光压平或统一染蓝。"
        case .architecture:
            let targetLuminance: Float = isNight ? 0.25 : 0.4
            exposureEV = ((targetLuminance - statistics.averageLuminance) * 0.4)
                .clamped(to: -0.06...0.09)
            highlightAmount = (1 - max(0, statistics.highlightRatio - 0.06) * 1.25)
                .clamped(to: 0.7...1)
            shadowAmount = ((statistics.shadowRatio - 0.2) * 0.28)
                .clamped(to: 0...0.13)
            contrast = 1 + ((0.6 - statistics.contrastRange) * 0.16)
                .clamped(to: 0...0.07)
            clarity = min(0.075, max(0, recipe.localContrastAmount * 0.5))
            reason = "依据建筑区域自身的光源、高光和结构对比增强线条与材质，不改变环境真实性。"
        default:
            return nil
        }

        let scaled = RegionalPixelAdjustment(
            region: region,
            exposureEV: exposureEV * confidence,
            highlightAmount: 1 - ((1 - highlightAmount) * confidence),
            shadowAmount: shadowAmount * confidence,
            contrast: 1 + ((contrast - 1) * confidence),
            saturation: 1 + ((saturation - 1) * confidence),
            temperatureShift: temperatureShift * confidence,
            clarity: clarity * confidence,
            confidence: confidence,
            reason: reason,
            fallback: "蒙版或置信度不足时跳过该区域，仅保留全局实测影调处理。"
        )
        return scaled.isActive ? scaled : nil
    }

    var isActive: Bool {
        abs(exposureEV) > 0.003
            || highlightAmount < 0.997
            || shadowAmount > 0.003
            || abs(contrast - 1) > 0.003
            || abs(saturation - 1) > 0.003
            || abs(temperatureShift) > 1
            || clarity > 0.003
    }

    var traceSummary: String {
        String(
            format: "%@ confidence=%.2f EV=%+.3f highlights=%.3f shadows=%.3f contrast=%.3f saturation=%.3f temp=%+.0f clarity=%.3f",
            region.rawValue,
            confidence,
            exposureEV,
            highlightAmount,
            shadowAmount,
            contrast,
            saturation,
            temperatureShift,
            clarity
        )
    }
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
    var highlightGlowThreshold: Float
    var backgroundSeparation: Float
    var hsl: ProfessionalHSLAdjustment
    var shadowZoneExposureEV: Float
    var highlightZoneExposureEV: Float
    var luminanceMaskStrength: Float

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
        highlightGlowThreshold: 0.92,
        backgroundSeparation: 0.0,
        hsl: .neutral,
        shadowZoneExposureEV: 0,
        highlightZoneExposureEV: 0,
        luminanceMaskStrength: 0
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
        highlightGlowThreshold: 0.95,
        backgroundSeparation: 0.0,
        hsl: .neutral,
        shadowZoneExposureEV: 0.04,
        highlightZoneExposureEV: -0.04,
        luminanceMaskStrength: 0.35
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
            localContrastAmount: localContrastAmount.clamped(to: 0.0...0.28),
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
            sharpeningAmount: sharpeningAmount.clamped(to: 0.0...0.22),
            skinTextureProtection: skinTextureProtection.clamped(to: 0.0...0.8),
            vignetteIntensity: vignetteIntensity.clamped(to: 0.0...0.35),
            subjectExposureEV: subjectExposureEV.clamped(to: 0.0...0.3),
            faceExposureEV: faceExposureEV.clamped(to: 0.0...0.42),
            skyExposureEV: skyExposureEV.clamped(to: -0.2...0.08),
            skyHighlightAmount: skyHighlightAmount.clamped(to: 0.4...1.0),
            skySaturation: skySaturation.clamped(to: 0.96...1.08),
            grainAmount: grainAmount.clamped(to: 0.0...0.12),
            bloomIntensity: bloomIntensity.clamped(to: 0.0...0.025),
            halationIntensity: halationIntensity.clamped(to: 0.0...0.012),
            highlightGlowThreshold: highlightGlowThreshold.clamped(to: 0.84...0.98),
            backgroundSeparation: backgroundSeparation.clamped(to: 0.0...0.18),
            hsl: hsl.clamped(),
            shadowZoneExposureEV: shadowZoneExposureEV.clamped(to: 0.0...0.22),
            highlightZoneExposureEV: highlightZoneExposureEV.clamped(to: -0.24...0.0),
            luminanceMaskStrength: luminanceMaskStrength.clamped(to: 0.0...1.0)
        )
    }

    var traceSummary: String {
        String(
            format: "tone=%@/%.3f cinematic=%@/%@ exposure=%.3f highlight=%.3f shadow=%.3f contrast=%.3f saturation=%.3f vibrance=%.3f wb=%.0f/%.2f grade=%.3f/%.3f/%.3f/%.3f hsl=o%.3f,y%.3f,g%.3f,c%.3f,b%.3f local=subject%.3f,face%.3f,sky%.3f/%.3f/%.3f detail=%.3f/%.3f",
            toneCurveStyle.rawValue,
            toneCurveAmount,
            cinematicIntensity.rawValue,
            cinematicToneStyle.rawValue,
            exposureEV,
            highlightAmount,
            shadowAmount,
            contrast,
            saturation,
            vibrance,
            temperatureShift,
            tintShift,
            colorGradeIntensity,
            shadowCoolAmount,
            midtoneWarmAmount,
            highlightWarmAmount,
            hsl.orangeSaturation,
            hsl.yellowSaturation,
            hsl.greenSaturation,
            hsl.cyanSaturation,
            hsl.blueSaturation,
            subjectExposureEV,
            faceExposureEV,
            skyExposureEV,
            skyHighlightAmount,
            skySaturation,
            noiseReductionAmount,
            sharpeningAmount
        )
    }
}

/// V6 的统一专业配方名称；保留旧名称以兼容现有相机与诊断数据。
typealias ProfessionalEditingRecipe = AutomaticEditingRecipe

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
