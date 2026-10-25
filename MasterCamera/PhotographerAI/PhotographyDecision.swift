import Foundation

struct PhotographyDecision: Equatable, Sendable {
    let sceneStrategy: SceneStrategy
    let context: PhotographyContext
    let aestheticTarget: AestheticTarget
    let intent: String
    let actions: [PhotographyAction]
    let treatmentPlan: PhotographyTreatmentPlan
    let recipe: AutomaticEditingRecipe

    var summaryText: String {
        let actionText = actions.map(\.title).joined(separator: ", ")
        return "\(sceneStrategy.title): \(actionText)"
    }

    func replacingRecipe(
        with recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis
    ) -> PhotographyDecision {
        let refreshedTreatments = treatmentPlan.regionalTreatments.compactMap { treatment -> RegionalTreatment? in
            guard [.ground, .vegetation, .water, .architecture].contains(treatment.region) else {
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
            recipe: recipe
        )
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

