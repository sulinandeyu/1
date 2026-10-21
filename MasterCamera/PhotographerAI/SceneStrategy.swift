import Foundation

enum SceneStrategy: String, Equatable, Sendable {
    case portrait
    case backlitPortrait
    case landscape
    case night
    case food
    case architecture
    case sunset
    case indoor
    case workspace
    case lowLight
    case brightOutdoor
    case flatScene
    case highContrast
    case general

    var title: String {
        switch self {
        case .portrait:
            return "人像"
        case .backlitPortrait:
            return "逆光人像"
        case .landscape:
            return "风景"
        case .night:
            return "夜景"
        case .food:
            return "美食"
        case .architecture:
            return "建筑"
        case .sunset:
            return "日落/日出"
        case .indoor:
            return "室内"
        case .workspace:
            return "电脑桌/工作区"
        case .lowLight:
            return "弱光"
        case .brightOutdoor:
            return "明亮户外"
        case .flatScene:
            return "层次偏平"
        case .highContrast:
            return "高对比"
        case .general:
            return "通用"
        }
    }

    static func choose(
        for analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> SceneStrategy {
        if problems.contains(.backlitSubject) {
            return .backlitPortrait
        }

        switch analysis.semanticScene {
        case .portrait:
            return .portrait
        case .backlitPortrait:
            return .backlitPortrait
        case .landscape:
            return .landscape
        case .night:
            return .night
        case .food:
            return .food
        case .architecture:
            return .architecture
        case .sunset:
            return .sunset
        case .indoor:
            return .indoor
        case .workspace:
            return .workspace
        case .general:
            break
        }

        if problems.contains(.underexposed) {
            return .lowLight
        }

        if problems.contains(.overexposed) || problems.contains(.clippedHighlights) {
            return .brightOutdoor
        }

        if problems.contains(.flatContrast) {
            return .flatScene
        }

        if problems.contains(.harshContrast) {
            return .highContrast
        }

        return .general
    }
}

