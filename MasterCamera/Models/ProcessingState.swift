import Foundation

enum ProcessingState: Equatable {
    case idle
    case analyzing
    case rendering
    case finalizing

    var isProcessing: Bool {
        self != .idle
    }

    var title: String {
        switch self {
        case .idle:
            return ""
        case .analyzing:
            return "正在分析照片"
        case .rendering:
            return "正在生成 AI 成片"
        case .finalizing:
            return "正在完成处理"
        }
    }

    var subtitle: String {
        switch self {
        case .idle:
            return ""
        case .analyzing:
            return "正在识别光线、色彩、对比度和人脸。"
        case .rendering:
            return "正在应用自然的摄影级后期。"
        case .finalizing:
            return "正在检查质量并准备预览。"
        }
    }
}

