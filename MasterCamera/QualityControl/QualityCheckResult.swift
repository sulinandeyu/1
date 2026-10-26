import Foundation

struct QualityCheckResult: Equatable, Sendable {
    let status: QualityStatus
    let issues: [QualityIssue]
    let measuredAnalysis: PhotoAnalysis
    let fallbackApplied: Bool
    let processingImpact: ProcessingImpactMetrics
    let colorIntegrity: ColorIntegrityMetrics

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
            processingImpact: processingImpact,
            colorIntegrity: colorIntegrity
        )
    }
}

struct ProcessingImpactMetrics: Equatable, Sendable {
    let normalizedMeanAbsoluteRGBDifference: Float
    let changedPixelRatio: Float
}

/// Source-relative color safety evidence. It never assumes one ideal skin color
/// or one universal grey point; it measures whether pixels that were skin-like
/// or neutral in the original were pushed away from their own recorded color.
struct ColorIntegrityMetrics: Equatable, Sendable {
    let neutralCoverage: Float
    let neutralChromaIncrease: Float
    let neutralWarmShift: Float
    let neutralGreenShift: Float
    let neutralLuminanceShift: Float
    let skinCoverage: Float
    let skinColorDifference: Float
    let skinWarmShift: Float

    static let neutral = ColorIntegrityMetrics(
        neutralCoverage: 0,
        neutralChromaIncrease: 0,
        neutralWarmShift: 0,
        neutralGreenShift: 0,
        neutralLuminanceShift: 0,
        skinCoverage: 0,
        skinColorDifference: 0,
        skinWarmShift: 0
    )

    var riskPenalty: Float {
        let neutralRisk: Float = neutralCoverage >= 0.015
            ? max(0, neutralChromaIncrease - 0.012) * 9
                + max(0, abs(neutralWarmShift) - 0.012) * 7
                + max(0, abs(neutralGreenShift) - 0.012) * 7
                + max(0, -neutralLuminanceShift - 0.025) * 5
            : 0
        let skinRisk: Float = skinCoverage >= 0.004
            ? max(0, skinColorDifference - 0.016) * 8
                + max(0, abs(skinWarmShift) - 0.014) * 7
            : 0
        return min(
            1,
            neutralRisk + skinRisk
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
    case skinToneDrift
    case neutralColorDrift
    case neutralLuminanceLoss
    case globalWarmCast
    case globalGreenCast
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
        case .skinToneDrift:
            return "人物肤色相对原图发生异常漂移"
        case .neutralColorDrift:
            return "白色或灰色材质出现异常染色"
        case .neutralLuminanceLoss:
            return "中性亮部被不必要压暗"
        case .globalWarmCast:
            return "画面新增明显橙黄偏色"
        case .globalGreenCast:
            return "画面新增明显黄绿色偏色"
        case .localMaskBoundaryArtifact:
            return "局部蒙版边界变化异常"
        case .missingExpectedSceneTreatment:
            return "计划中的场景局部处理未实际执行"
        }
    }
}

