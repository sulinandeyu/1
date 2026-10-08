import Foundation

enum SaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)

    var isSaving: Bool {
        self == .saving
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .saving:
            return "正在保存原图和 AI 成片..."
        case .saved:
            return "原图和 AI 成片已保存。"
        case .failed(let message):
            return message
        }
    }
}

