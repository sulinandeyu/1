import Foundation

struct PhotographyDecision: Equatable, Sendable {
    let sceneStrategy: SceneStrategy
    let intent: String
    let actions: [PhotographyAction]
    let recipe: AutomaticEditingRecipe

    var summaryText: String {
        let actionText = actions.map(\.title).joined(separator: ", ")
        return "\(sceneStrategy.title): \(actionText)"
    }
}

struct PhotographyAction: Equatable, Sendable {
    let title: String
    let reason: String
}

