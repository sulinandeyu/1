import Foundation

struct QualityCheckResult: Equatable, Sendable {
    let status: QualityStatus
    let issues: [QualityIssue]
    let measuredAnalysis: PhotoAnalysis
    let fallbackApplied: Bool

    var passed: Bool {
        status == .passed
    }

    var summaryText: String {
        let prefix = fallbackApplied ? "已使用安全成片 · " : ""

        if issues.isEmpty {
            return "\(prefix)质量检查通过"
        }

        return "\(prefix)\(issues.map(\.title).joined(separator: ", "))"
    }

    func applyingFallback() -> QualityCheckResult {
        QualityCheckResult(
            status: status,
            issues: issues,
            measuredAnalysis: measuredAnalysis,
            fallbackApplied: true
        )
    }
}

enum QualityStatus: String, Equatable, Sendable {
    case passed
    case warning
    case failed

    func isBetter(than other: QualityStatus) -> Bool {
        rank < other.rank
    }

    private var rank: Int {
        switch self {
        case .passed:
            return 0
        case .warning:
            return 1
        case .failed:
            return 2
        }
    }
}

enum QualityIssue: String, Equatable, Sendable {
    case tooDark
    case tooBright
    case tooFlat
    case tooHarsh
    case possibleRenderFallback

    var title: String {
        switch self {
        case .tooDark:
            return "成片过暗"
        case .tooBright:
            return "成片过亮"
        case .tooFlat:
            return "层次偏平"
        case .tooHarsh:
            return "对比过强"
        case .possibleRenderFallback:
            return "成片未变化"
        }
    }
}

