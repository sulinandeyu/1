import Foundation

struct PhotographyDecision: Equatable, Sendable {
    let sceneStrategy: SceneStrategy
    let aestheticTarget: AestheticTarget
    let intent: String
    let actions: [PhotographyAction]
    let recipe: AutomaticEditingRecipe

    var summaryText: String {
        let actionText = actions.map(\.title).joined(separator: ", ")
        return "\(sceneStrategy.title): \(actionText)"
    }
}

enum AestheticTarget: String, Equatable, Sendable {
    case naturalPortrait
    case protectedBacklightPortrait
    case luminousLandscape
    case cinematicNight
    case appetizingNatural
    case architecturalClarity
    case warmSunset
    case balancedIndoor
    case neutral

    var title: String {
        switch self {
        case .naturalPortrait: return "自然人像"
        case .protectedBacklightPortrait: return "保留环境的逆光人像"
        case .luminousLandscape: return "通透且有层次的风景"
        case .cinematicNight: return "保留氛围的夜景"
        case .appetizingNatural: return "自然诱人的食物色彩"
        case .architecturalClarity: return "清晰克制的建筑质感"
        case .warmSunset: return "保护暖色与太阳高光"
        case .balancedIndoor: return "色温自然的室内观感"
        case .neutral: return "忠实自然"
        }
    }
}

struct PhotographyAction: Equatable, Sendable {
    let title: String
    let reason: String
}

