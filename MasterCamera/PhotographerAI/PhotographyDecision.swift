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

    func replacingRecipe(with recipe: AutomaticEditingRecipe) -> PhotographyDecision {
        PhotographyDecision(
            sceneStrategy: sceneStrategy,
            context: context,
            aestheticTarget: aestheticTarget,
            intent: intent,
            actions: actions,
            treatmentPlan: treatmentPlan,
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

