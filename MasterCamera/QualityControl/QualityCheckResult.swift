import Foundation

struct QualityCheckResult: Equatable, Sendable {
    let status: QualityStatus
    let issues: [QualityIssue]
    let measuredAnalysis: PhotoAnalysis
    let fallbackApplied: Bool
    let processingImpact: ProcessingImpactMetrics

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
            fallbackApplied: true,
            processingImpact: processingImpact
        )
    }
}

struct ProcessingImpactMetrics: Equatable, Sendable {
    let normalizedMeanAbsoluteRGBDifference: Float
    let changedPixelRatio: Float
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

enum QualityIssue: String, Equatable, Hashable, Sendable {
    case tooDark
    case tooBright
    case tooFlat
    case tooHarsh
    case clippedHighlights
    case crushedShadows
    case oversaturated
    case possibleRenderFallback
    case insufficientProcessingImpact
    case canvasMismatch
    case abnormalBlackCoverage
    case excessiveHighlightSpread
    case abnormalColorCast
    case amplifiedNoise
    case overprocessedDetail
    case expandedPureWhite
    case portraitRegionOverAltered
    case portraitTextureAltered
    case localMaskBoundaryArtifact
    case missingExpectedSceneTreatment

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
        case .clippedHighlights:
            return "新增高光溢出"
        case .crushedShadows:
            return "新增暗部死黑"
        case .oversaturated:
            return "色彩过饱和"
        case .possibleRenderFallback:
            return "成片未变化"
        case .insufficientProcessingImpact:
            return "后期处理视觉影响过小"
        case .canvasMismatch:
            return "输出画布异常"
        case .abnormalBlackCoverage:
            return "出现异常大面积死黑"
        case .excessiveHighlightSpread:
            return "高光扩散范围异常"
        case .abnormalColorCast:
            return "出现明显异常偏色"
        case .amplifiedNoise:
            return "暗部噪点被放大"
        case .overprocessedDetail:
            return "细节增强过硬"
        case .expandedPureWhite:
            return "纯白溢出区域扩大"
        case .portraitRegionOverAltered:
            return "人物面部被局部过度改变"
        case .portraitTextureAltered:
            return "人物皮肤纹理变化异常"
        case .localMaskBoundaryArtifact:
            return "局部蒙版边界变化异常"
        case .missingExpectedSceneTreatment:
            return "计划中的场景局部处理未实际执行"
        }
    }
}

