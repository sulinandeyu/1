import Foundation

struct PhotographyDecision: Equatable, Sendable {
    let sceneStrategy: SceneStrategy
    let context: PhotographyContext
    let aestheticTarget: AestheticTarget
    let intent: String
    let actions: [PhotographyAction]
    let treatmentPlan: PhotographyTreatmentPlan
    let recipe: AutomaticEditingRecipe
    let parameterEvidence: [PhotographyParameterEvidence]

    var summaryText: String {
        let actionText = actions.map(\.title).joined(separator: ", ")
        return "\(sceneStrategy.title): \(actionText)"
    }

    func replacingRecipe(
        with recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis
    ) -> PhotographyDecision {
        let refreshedTreatments = treatmentPlan.regionalTreatments.compactMap { treatment -> RegionalTreatment? in
            guard [.subject, .ground, .vegetation, .water, .architecture].contains(treatment.region) else {
                if treatment.region == .sky {
                    let requested = abs(recipe.skyExposureEV) > 0.001
                        || recipe.skyHighlightAmount < 0.999
                        || abs(recipe.skySaturation - 1) > 0.001
                    guard requested else { return nil }
                    return RegionalTreatment(
                        region: .sky,
                        objective: treatment.objective,
                        reason: treatment.reason,
                        parameters: String(
                            format: "sky EV=%+.3f highlights=%.3f saturation=%.3f",
                            recipe.skyExposureEV,
                            recipe.skyHighlightAmount,
                            recipe.skySaturation
                        ),
                        maximumSafeAdjustment: treatment.maximumSafeAdjustment,
                        confidence: treatment.confidence,
                        fallback: treatment.fallback
                    )
                }
                return treatment
            }
            guard let adjustment = RegionalPixelAdjustment.make(
                region: treatment.region,
                analysis: analysis,
                recipe: recipe
            ) else { return nil }
            return RegionalTreatment(
                region: treatment.region,
                objective: treatment.objective,
                reason: adjustment.reason,
                parameters: adjustment.traceSummary,
                maximumSafeAdjustment: treatment.maximumSafeAdjustment,
                confidence: adjustment.confidence,
                fallback: adjustment.fallback
            )
        }
        return PhotographyDecision(
            sceneStrategy: sceneStrategy,
            context: context,
            aestheticTarget: aestheticTarget,
            intent: intent,
            actions: actions,
            treatmentPlan: PhotographyTreatmentPlan(
                finalLook: treatmentPlan.finalLook,
                lightingDesign: treatmentPlan.lightingDesign,
                regionalTreatments: refreshedTreatments,
                portraitProtection: treatmentPlan.portraitProtection
            ),
            recipe: recipe,
            parameterEvidence: parameterEvidence.map { $0.refreshingActualValue(from: recipe) }
        )
    }
}

/// V9 keeps the reason for every important pixel parameter beside the executable
/// recipe. This is intentionally typed data instead of a free-form prompt so the
/// diagnostic UI can show measurement -> target -> bounded value without claiming
/// that a generated plan was rendered when it was not.
enum PhotographyParameterKey: String, Equatable, Sendable {
    case exposure
    case highlights
    case shadows
    case contrast
    case toneCurve
    case whitePoint
    case blackPoint
    case temperature
    case tint
    case saturation
    case vibrance
    case localContrast
    case noiseReduction
    case sharpening
    case luminanceMask
    case orangeHSL
    case greenHSL
    case blueHSL
}

struct PhotographyParameterEvidence: Equatable, Sendable {
    let key: PhotographyParameterKey
    let purpose: String
    let inputEvidence: String
    let target: String
    let minimumValue: Float
    let maximumValue: Float
    let actualValue: Float
    let expectedResult: String
    let fallbackBehavior: String

    func refreshingActualValue(from recipe: AutomaticEditingRecipe) -> PhotographyParameterEvidence {
        PhotographyParameterEvidence(
            key: key,
            purpose: purpose,
            inputEvidence: inputEvidence,
            target: target,
            minimumValue: minimumValue,
            maximumValue: maximumValue,
            actualValue: Self.actualValue(for: key, recipe: recipe),
            expectedResult: expectedResult,
            fallbackBehavior: fallbackBehavior
        )
    }

    static func actualValue(
        for key: PhotographyParameterKey,
        recipe: AutomaticEditingRecipe
    ) -> Float {
        switch key {
        case .exposure: return recipe.exposureEV
        case .highlights: return recipe.highlightAmount
        case .shadows: return recipe.shadowAmount
        case .contrast: return recipe.contrast
        case .toneCurve: return recipe.toneCurveAmount
        case .whitePoint: return recipe.whitePoint
        case .blackPoint: return recipe.blackPoint
        case .temperature: return recipe.temperatureShift
        case .tint: return recipe.tintShift
        case .saturation: return recipe.saturation
        case .vibrance: return recipe.vibrance
        case .localContrast: return recipe.localContrastAmount
        case .noiseReduction: return recipe.noiseReductionAmount
        case .sharpening: return recipe.sharpeningAmount
        case .luminanceMask: return recipe.luminanceMaskStrength
        case .orangeHSL: return recipe.hsl.orangeSaturation
        case .greenHSL: return recipe.hsl.greenSaturation
        case .blueHSL: return recipe.hsl.blueSaturation
        }
    }
}

/// 摄影总监给渲染链路的可审计制作计划。它不是提示词或独立 JSON：
/// `recipe` 仍是实际执行的像素参数，而本计划记录每个参数服务的摄影目标和硬保护边界。
struct PhotographyTreatmentPlan: Equatable, Sendable {
    let finalLook: String
    let lightingDesign: String
    let regionalTreatments: [RegionalTreatment]
    let portraitProtection: PortraitProtectionPolicy
}

struct RegionalTreatment: Equatable, Sendable {
    let region: TreatmentRegion
    let objective: String
    let reason: String
    let parameters: String
    let maximumSafeAdjustment: String
    let confidence: Float
    let fallback: String

    init(
        region: TreatmentRegion,
        objective: String,
        reason: String = "由当前照片实测数据触发。",
        parameters: String = "见最终像素配方。",
        maximumSafeAdjustment: String = "受配方安全范围限制。",
        confidence: Float = 1,
        fallback: String = "证据不足时跳过该区域。"
    ) {
        self.region = region
        self.objective = objective
        self.reason = reason
        self.parameters = parameters
        self.maximumSafeAdjustment = maximumSafeAdjustment
        self.confidence = confidence
        self.fallback = fallback
    }
}

enum TreatmentRegion: String, Equatable, Sendable {
    case global
    case sky
    case person
    case background
    case subject
    case ground
    case vegetation
    case water
    case architecture
}

/// 人物保护是决策层的硬约束，不由某个风格或场景配方覆盖。
struct PortraitProtectionPolicy: Equatable, Sendable {
    let isActive: Bool
    let allowsFaceSpecificRelighting: Bool
    let allowsGeometryChanges: Bool
    let allowsGenerativeChanges: Bool
    let preservesSkinTexture: Bool

    static let inactive = PortraitProtectionPolicy(
        isActive: false,
        allowsFaceSpecificRelighting: false,
        allowsGeometryChanges: false,
        allowsGenerativeChanges: false,
        preservesSkinTexture: false
    )

    static let strict = PortraitProtectionPolicy(
        isActive: true,
        allowsFaceSpecificRelighting: false,
        allowsGeometryChanges: false,
        allowsGenerativeChanges: false,
        preservesSkinTexture: true
    )
}

enum AestheticTarget: String, Equatable, Sendable {
    case naturalPortrait
    case protectedBacklightPortrait
    case luminousLandscape
    case cinematicNight
    case cinematicStreet
    case cinematicOutdoor
    case appetizingNatural
    case architecturalClarity
    case warmSunset
    case balancedIndoor
    case workspaceClarity
    case neutral

    var title: String {
        switch self {
        case .naturalPortrait: return "自然人像"
        case .protectedBacklightPortrait: return "保留环境的逆光人像"
        case .luminousLandscape: return "通透且有层次的风景"
        case .cinematicNight: return "保留氛围的夜景"
        case .cinematicStreet: return "冷暖分离的街头电影感"
        case .cinematicOutdoor: return "明亮自然的户外电影感"
        case .appetizingNatural: return "自然诱人的食物色彩"
        case .architecturalClarity: return "清晰克制的建筑质感"
        case .warmSunset: return "保护暖色与太阳高光"
        case .balancedIndoor: return "色温自然的室内观感"
        case .workspaceClarity: return "保留黑位与材质的桌面质感"
        case .neutral: return "忠实自然"
        }
    }
}

struct PhotographyAction: Equatable, Sendable {
    let title: String
    let reason: String
}

enum PhotographyCandidateIntent: String, CaseIterable, Equatable, Hashable, Sendable {
    case natural = "自然保守"
    case dimensional = "层次增强"
    case targeted = "问题定向"
}

enum PhotographyAdjustmentType: String, Equatable, Sendable {
    case globalExposure
    case localExposure
    case highlightRecovery
    case shadowRecovery
    case tonalCurve
    case whiteBalance
    case saturation
    case vibrance
    case localContrast
    case texture
    case noiseReduction
    case sharpening
    case dodgeAndBurn
    case filmGrain
}

struct PhotographyPlannedAdjustment: Equatable, Sendable {
    let targetRegion: TreatmentRegion
    let adjustmentType: PhotographyAdjustmentType
    let intensity: Float
    let confidence: Float
    let reason: String
    let minimumValue: Float
    let maximumValue: Float
    let expectedEffect: String
    let fallbackBehavior: String
}

struct PhotographyEditPlan: Equatable, Sendable {
    let id: String
    let intent: PhotographyCandidateIntent
    let adjustments: [PhotographyPlannedAdjustment]
    let recipe: AutomaticEditingRecipe
    let rationale: String
    let parameterEvidence: [PhotographyParameterEvidence]
}

enum CandidateEvaluationStatus: String, Equatable, Sendable {
    case passed
    case warning
    case rejected
    case skipped
}

struct PhotographyCandidateEvaluation: Equatable, Sendable {
    let planID: String
    let title: String
    let status: CandidateEvaluationStatus
    let score: Float
    let problemImprovement: Float
    let preservationScore: Float
    let subjectPriorityScore: Float
    let harmonyScore: Float
    let issues: [String]
    let regionImpacts: [PhotographyRegionImpact]
    let reason: String
    let durationMilliseconds: Int
    let selected: Bool

    init(
        planID: String,
        title: String,
        status: CandidateEvaluationStatus,
        score: Float,
        problemImprovement: Float,
        preservationScore: Float,
        subjectPriorityScore: Float = 0,
        harmonyScore: Float = 0,
        issues: [String],
        regionImpacts: [PhotographyRegionImpact] = [],
        reason: String,
        durationMilliseconds: Int,
        selected: Bool
    ) {
        self.planID = planID
        self.title = title
        self.status = status
        self.score = score
        self.problemImprovement = problemImprovement
        self.preservationScore = preservationScore
        self.subjectPriorityScore = subjectPriorityScore
        self.harmonyScore = harmonyScore
        self.issues = issues
        self.regionImpacts = regionImpacts
        self.reason = reason
        self.durationMilliseconds = durationMilliseconds
        self.selected = selected
    }

    func markingSelected() -> PhotographyCandidateEvaluation {
        PhotographyCandidateEvaluation(
            planID: planID,
            title: title,
            status: status,
            score: score,
            problemImprovement: problemImprovement,
            preservationScore: preservationScore,
            subjectPriorityScore: subjectPriorityScore,
            harmonyScore: harmonyScore,
            issues: issues,
            regionImpacts: regionImpacts,
            reason: reason,
            durationMilliseconds: durationMilliseconds,
            selected: true
        )
    }
}

struct PhotographyRegionImpact: Equatable, Sendable {
    let region: TreatmentRegion
    let maskCoverage: Float
    let luminanceDelta: Float
    let colorDelta: Float
    let contrastDelta: Float
    let changedPixelRatio: Float
}

struct PhotographyCandidateSelector {
    func select(from evaluations: [PhotographyCandidateEvaluation]) -> PhotographyCandidateEvaluation? {
        let rendered = evaluations.filter { $0.status != .skipped }
        guard !rendered.isEmpty else { return nil }
        let acceptable = rendered.filter { $0.status != .rejected }
        if acceptable.isEmpty {
            return rendered.first { $0.planID == PhotographyCandidateIntent.natural.rawValue }
                ?? rendered.max { $0.preservationScore < $1.preservationScore }
        }
        return acceptable.max { left, right in
            if abs(left.score - right.score) > 0.001 {
                return left.score < right.score
            }
            if abs(left.preservationScore - right.preservationScore) > 0.001 {
                return left.preservationScore < right.preservationScore
            }
            return left.durationMilliseconds > right.durationMilliseconds
        }
    }
}

/// Scores only measured improvement. An unchanged image earns zero rather than a
/// neutral-looking default score, so candidate selection cannot claim progress
/// merely because a render completed.
struct PhotographyProblemImprovementScorer {
    func score(
        problems: PhotoProblemReport,
        source: PhotoAnalysis,
        edited: PhotoAnalysis,
        regionImpacts: [PhotographyRegionImpact]
    ) -> Float {
        guard !problems.isEmpty else { return 0 }
        var total: Float = 0
        var weight: Float = 0
        for problem in problems.problems {
            let itemWeight = Float(problem.severity.rawValue) * problem.confidence
            let improvement: Float
            switch problem.kind {
            case .underexposed:
                improvement = normalizedImprovement(
                    edited.averageLuminance - source.averageLuminance,
                    scale: 0.09
                )
            case .overexposed:
                improvement = normalizedImprovement(
                    source.averageLuminance - edited.averageLuminance,
                    scale: 0.09
                )
            case .clippedHighlights:
                improvement = normalizedImprovement(
                    source.highlightRatio - edited.highlightRatio,
                    scale: 0.07
                )
            case .blockedShadows:
                improvement = normalizedImprovement(
                    source.shadowRatio - edited.shadowRatio,
                    scale: 0.1
                )
            case .flatContrast:
                improvement = normalizedImprovement(
                    edited.contrastRange - source.contrastRange,
                    scale: 0.12
                )
            case .harshContrast:
                improvement = normalizedImprovement(
                    source.contrastRange - edited.contrastRange,
                    scale: 0.12
                )
            case .oversaturated:
                improvement = normalizedImprovement(
                    source.averageSaturation - edited.averageSaturation,
                    scale: 0.1
                )
            case .noiseRisk:
                improvement = normalizedImprovement(
                    source.noiseEstimate - edited.noiseEstimate,
                    scale: 0.05
                )
            case .coolCast, .warmCast, .greenCast:
                improvement = colorNeutralityImprovement(source: source, edited: edited)
            case .backlitSubject:
                improvement = personRelightingImprovement(regionImpacts)
            case .regionalUnderexposure:
                improvement = regionalImprovement(
                    for: problem,
                    impacts: regionImpacts,
                    keyPath: \.luminanceDelta,
                    scale: 0.06
                )
            case .regionalFlatness:
                improvement = regionalImprovement(
                    for: problem,
                    impacts: regionImpacts,
                    keyPath: \.contrastDelta,
                    scale: 0.025
                )
            case .regionalHighlightRisk:
                improvement = regionalImprovement(
                    for: problem,
                    impacts: regionImpacts,
                    keyPath: \.luminanceDelta,
                    scale: -0.05
                )
            }
            total += improvement * itemWeight
            weight += itemWeight
        }
        return weight > 0 ? min(1, max(0, total / weight)) : 0
    }

    private func normalizedImprovement(_ value: Float, scale: Float) -> Float {
        min(1, max(0, value / max(0.001, scale)))
    }

    private func regionalImprovement(
        for problem: PhotoProblem,
        impacts: [PhotographyRegionImpact],
        keyPath: KeyPath<PhotographyRegionImpact, Float>,
        scale: Float
    ) -> Float {
        guard
            let region = problem.affectedRegions.first,
            let impact = impacts.first(where: { $0.region == region })
        else { return 0 }
        let directionalValue = impact[keyPath: keyPath] * (scale < 0 ? -1 : 1)
        return normalizedImprovement(directionalValue, scale: abs(scale))
    }

    private func personRelightingImprovement(
        _ impacts: [PhotographyRegionImpact]
    ) -> Float {
        guard let impact = impacts.first(where: { $0.region == .person })
            ?? impacts.first(where: { $0.region == .subject })
        else { return 0 }
        return normalizedImprovement(impact.luminanceDelta, scale: 0.05)
    }

    private func colorNeutralityImprovement(
        source: PhotoAnalysis,
        edited: PhotoAnalysis
    ) -> Float {
        let sourceSpread = max(source.redAverage, max(source.greenAverage, source.blueAverage))
            - min(source.redAverage, min(source.greenAverage, source.blueAverage))
        let editedSpread = max(edited.redAverage, max(edited.greenAverage, edited.blueAverage))
            - min(edited.redAverage, min(edited.greenAverage, edited.blueAverage))
        return normalizedImprovement(sourceSpread - editedSpread, scale: 0.06)
    }
}

struct PhotographyAestheticProgress: Equatable, Sendable {
    let subjectPriority: Float
    let regionalHarmony: Float

    var hasMeaningfulProgress: Bool {
        max(subjectPriority, regionalHarmony) >= 0.14
    }
}

/// Candidate-level evidence that complements technical quality gates. It never
/// rewards raw pixel difference by itself: direction, relative subject separation,
/// regional balance and bounded magnitudes must all agree.
struct PhotographyAestheticProgressScorer {
    func score(
        source: PhotoAnalysis,
        regionImpacts: [PhotographyRegionImpact]
    ) -> PhotographyAestheticProgress {
        let subjectScore = scoreSubject(source: source, impacts: regionImpacts)
        let harmonyScore = scoreHarmony(source: source, impacts: regionImpacts)
        return PhotographyAestheticProgress(
            subjectPriority: subjectScore,
            regionalHarmony: harmonyScore
        )
    }

    private func scoreSubject(
        source: PhotoAnalysis,
        impacts: [PhotographyRegionImpact]
    ) -> Float {
        guard
            source.salientSubjectPriorityConfidence >= 0.54,
            let subject = impacts.first(where: { $0.region == .subject })
        else { return 0 }

        let background = impacts.filter { $0.region != .subject && $0.region != .person }
        let backgroundLuminance = background.isEmpty
            ? 0
            : background.map(\.luminanceDelta).reduce(0, +) / Float(background.count)
        let relativeLift = normalized(subject.luminanceDelta - backgroundLuminance, scale: 0.035)
        let contrast = normalized(subject.contrastDelta, scale: 0.018)
        let colorSeparation = min(1, max(0, subject.colorDelta / 0.035))
        let executionEvidence = min(1, max(0, subject.changedPixelRatio / 0.35))
        let overProcessingPenalty = max(0, abs(subject.luminanceDelta) - 0.11) * 5
            + max(0, subject.colorDelta - 0.09) * 5
        return min(
            1,
            max(
                0,
                relativeLift * 0.38
                    + contrast * 0.27
                    + colorSeparation * 0.2
                    + executionEvidence * 0.15
                    - overProcessingPenalty
            )
        )
    }

    private func scoreHarmony(
        source: PhotoAnalysis,
        impacts: [PhotographyRegionImpact]
    ) -> Float {
        let profile = source.photographyContext.sceneProfile
        let reliable = impacts.filter {
            [.sky, .ground, .vegetation, .water, .architecture].contains($0.region)
        }
        guard !reliable.isEmpty else { return 0 }

        var total: Float = 0
        var weight: Float = 0
        for impact in reliable {
            let regionWeight: Float
            let directional: Float
            switch impact.region {
            case .sky:
                regionWeight = max(0.2, profile.skyPresence)
                if (source.skyStatistics?.highlightRatio ?? 0) > 0.16 {
                    directional = normalized(-impact.luminanceDelta, scale: 0.045)
                } else {
                    directional = min(1, impact.changedPixelRatio / 0.28)
                }
            case .vegetation:
                regionWeight = max(0.25, profile.vegetationDominant)
                let luminanceNeed = (source.vegetationStatistics?.averageLuminance ?? 0.4) < 0.38
                let luminance = luminanceNeed
                    ? normalized(impact.luminanceDelta, scale: 0.045)
                    : min(1, abs(impact.luminanceDelta) / 0.025)
                directional = luminance * 0.5
                    + normalized(impact.contrastDelta, scale: 0.016) * 0.5
            case .ground:
                regionWeight = max(0.2, profile.groundOrRoadPresence)
                let luminanceNeed = (source.groundStatistics?.averageLuminance ?? 0.4) < 0.3
                directional = (luminanceNeed
                    ? normalized(impact.luminanceDelta, scale: 0.045)
                    : min(1, impact.changedPixelRatio / 0.32)) * 0.55
                    + normalized(impact.contrastDelta, scale: 0.018) * 0.45
            case .architecture:
                regionWeight = max(0.12, profile.architecturePresence)
                if profile.urbanArchitectureTendency < 0.45 {
                    directional = min(1, max(0, 0.04 - impact.luminanceDelta) / 0.04)
                } else {
                    directional = normalized(impact.contrastDelta, scale: 0.018)
                }
            case .water:
                regionWeight = max(0.2, profile.waterPresence)
                directional = min(1, impact.changedPixelRatio / 0.3)
            default:
                continue
            }
            let naturalityPenalty = max(0, abs(impact.luminanceDelta) - 0.12) * 4
                + max(0, impact.colorDelta - 0.1) * 4
            let executionEvidence = min(1, impact.changedPixelRatio / 0.3)
            total += max(0, directional * 0.72 + executionEvidence * 0.28 - naturalityPenalty) * regionWeight
            weight += regionWeight
        }
        guard weight > 0 else { return 0 }
        let coordinatedRegions = Float(reliable.filter { $0.changedPixelRatio >= 0.08 }.count)
            / Float(reliable.count)
        return min(1, max(0, (total / weight) * 0.82 + coordinatedRegions * 0.18))
    }

    private func normalized(_ value: Float, scale: Float) -> Float {
        min(1, max(0, value / max(0.001, scale)))
    }
}

