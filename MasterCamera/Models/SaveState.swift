import Foundation

enum SaveState: Equatable {
    case idle
    case saving
    case savingOriginalOnly
    case saved
    case savedOriginalOnly
    case savedOriginalMemoryRescue
    case savedDiagnosticBundle
    case processingFailedOriginalAvailable
    case originalRetentionFailed(String)
    case needsReconciliation(String)
    case failed(String)

    var isSaving: Bool {
        self == .saving || self == .savingOriginalOnly
    }

    var isCompleted: Bool {
        switch self {
        case .saved, .savedOriginalOnly, .savedOriginalMemoryRescue, .savedDiagnosticBundle:
            return true
        default:
            return false
        }
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .saving:
            return "正在保存原图和 AI 成片..."
        case .savingOriginalOnly:
            return "正在保存可恢复原图..."
        case .saved:
            return "原图和 AI 成片已保存。"
        case .savedOriginalOnly:
            return "原图已保存；本次没有可保存的正式成片。"
        case .savedOriginalMemoryRescue:
            return "内存中的原图已抢救到系统相册；App 私有暂存此前未成功。"
        case .savedDiagnosticBundle:
            return "诊断输出已按 A/B/C/D/E1/E2/M 可用项分别保存。"
        case .processingFailedOriginalAvailable:
            return "AI 后期失败，原图安全副本仍可查看和保存。"
        case .originalRetentionFailed(let message):
            return "原图私有暂存失败：\(message)；当前仅保留内存抢救路径。"
        case .needsReconciliation(let message):
            return "相册事务需要确认：\(message)"
        case .failed(let message):
            return message
        }
    }
}

