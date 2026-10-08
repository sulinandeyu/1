import Foundation

enum SceneStrategy: String, Equatable, Sendable {
    case portrait
    case lowLight
    case brightOutdoor
    case flatScene
    case highContrast
    case general

    var title: String {
        switch self {
        case .portrait:
            return "人像"
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

    static func choose(for analysis: PhotoAnalysis) -> SceneStrategy {
        if analysis.containsFaces {
            return .portrait
        }

        if analysis.exposureProfile == .underexposed {
            return .lowLight
        }

        if analysis.exposureProfile == .overexposed {
            return .brightOutdoor
        }

        if analysis.contrastProfile == .flat {
            return .flatScene
        }

        if analysis.contrastProfile == .highContrast {
            return .highContrast
        }

        return .general
    }
}

