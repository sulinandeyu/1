import Foundation

struct PhotoProblemReport: Equatable, Sendable {
    let problems: [PhotoProblem]

    var isEmpty: Bool {
        problems.isEmpty
    }

    func contains(_ kind: PhotoProblemKind) -> Bool {
        problems.contains { $0.kind == kind }
    }

    func severity(of kind: PhotoProblemKind) -> PhotoProblemSeverity? {
        problems.first { $0.kind == kind }?.severity
    }
}

struct PhotoProblem: Equatable, Sendable {
    let kind: PhotoProblemKind
    let severity: PhotoProblemSeverity
    let evidence: String
}

enum PhotoProblemKind: String, Equatable, Sendable {
    case underexposed
    case overexposed
    case clippedHighlights
    case blockedShadows
    case flatContrast
    case harshContrast
    case coolCast
    case warmCast
    case greenCast
    case oversaturated
    case noiseRisk
    case backlitSubject

    var title: String {
        switch self {
        case .underexposed: return "整体欠曝"
        case .overexposed: return "整体过亮"
        case .clippedHighlights: return "高光溢出风险"
        case .blockedShadows: return "暗部堵塞"
        case .flatContrast: return "层次偏平"
        case .harshContrast: return "反差过强"
        case .coolCast: return "非场景性偏冷"
        case .warmCast: return "非场景性偏暖"
        case .greenCast: return "非场景性偏绿"
        case .oversaturated: return "饱和度过高"
        case .noiseRisk: return "暗部噪点风险"
        case .backlitSubject: return "逆光主体"
        }
    }
}

enum PhotoProblemSeverity: Int, Equatable, Sendable {
    case mild = 1
    case moderate = 2
    case strong = 3

    var title: String {
        switch self {
        case .mild: return "轻微"
        case .moderate: return "中等"
        case .strong: return "明显"
        }
    }
}

final class PhotoProblemDetector {
    func detect(in analysis: PhotoAnalysis) -> PhotoProblemReport {
        var problems: [PhotoProblem] = []

        detectExposureProblems(in: analysis, problems: &problems)
        detectContrastProblems(in: analysis, problems: &problems)
        detectColorProblems(in: analysis, problems: &problems)
        detectSceneSpecificProblems(in: analysis, problems: &problems)

        return PhotoProblemReport(problems: problems)
    }

    private func detectExposureProblems(
        in analysis: PhotoAnalysis,
        problems: inout [PhotoProblem]
    ) {
        if analysis.averageLuminance < 0.32 {
            append(
                .underexposed,
                severity: analysis.averageLuminance < 0.22 ? .strong : .moderate,
                evidence: "平均亮度为 \(analysis.averageLuminance.percentText)，低于自然曝光参考范围。",
                to: &problems
            )
        } else if analysis.averageLuminance > 0.72 {
            append(
                .overexposed,
                severity: analysis.averageLuminance > 0.82 ? .strong : .moderate,
                evidence: "平均亮度为 \(analysis.averageLuminance.percentText)，画面整体偏亮。",
                to: &problems
            )
        }

        if analysis.highlightRatio > 0.1 {
            append(
                .clippedHighlights,
                severity: analysis.highlightRatio > 0.22 ? .strong : .moderate,
                evidence: "高光区域占 \(analysis.highlightRatio.percentText)，需要保护亮部细节。",
                to: &problems
            )
        }

        if analysis.shadowRatio > 0.34 {
            append(
                .blockedShadows,
                severity: analysis.shadowRatio > 0.58 ? .strong : .moderate,
                evidence: "暗部区域占 \(analysis.shadowRatio.percentText)，但是否提亮仍需结合夜景和主体判断。",
                to: &problems
            )
        }
    }

    private func detectContrastProblems(
        in analysis: PhotoAnalysis,
        problems: inout [PhotoProblem]
    ) {
        if analysis.contrastRange < 0.34 {
            append(
                .flatContrast,
                severity: analysis.contrastRange < 0.22 ? .strong : .moderate,
                evidence: "5%–95% 亮度跨度仅为 \(analysis.contrastRange.percentText)。",
                to: &problems
            )
        } else if analysis.contrastRange > 0.78 {
            append(
                .harshContrast,
                severity: analysis.contrastRange > 0.88 ? .strong : .moderate,
                evidence: "5%–95% 亮度跨度达到 \(analysis.contrastRange.percentText)。",
                to: &problems
            )
        }
    }

    private func detectColorProblems(
        in analysis: PhotoAnalysis,
        problems: inout [PhotoProblem]
    ) {
        if analysis.averageSaturation > 0.55 {
            append(
                .oversaturated,
                severity: analysis.averageSaturation > 0.68 ? .strong : .moderate,
                evidence: "平均饱和度为 \(analysis.averageSaturation.percentText)，存在颜色失真风险。",
                to: &problems
            )
        }

        let facets = Set(analysis.photographyContext.sceneFacets)
        let environmentalColorIsIntentional = !facets.isDisjoint(with: [
            .sky, .nature, .mountain, .water, .coast, .forest, .city, .street, .nightCity
        ])
        let isControlledInterior = facets.contains(.interior) || facets.contains(.workspace)
        let isClosePortrait = facets.contains(.portrait)
            && !environmentalColorIsIntentional
            && analysis.largestFaceCoverage >= 0.035
        let canDiagnoseNeutralColor = isControlledInterior || isClosePortrait
        guard canDiagnoseNeutralColor else { return }

        switch analysis.colorCast {
        case .cool:
            append(.coolCast, evidence: "蓝色通道明显高于红色通道，且当前场景不要求保留冷色。", to: &problems)
        case .warm:
            append(.warmCast, evidence: "红色通道明显高于蓝色通道，且当前场景不要求保留暖色。", to: &problems)
        case .green:
            append(.greenCast, evidence: "绿色通道相对红蓝通道偏高，且并非自然风景记忆色。", to: &problems)
        default:
            break
        }
    }

    private func detectSceneSpecificProblems(
        in analysis: PhotoAnalysis,
        problems: inout [PhotoProblem]
    ) {
        if analysis.semanticScene == .backlitPortrait {
            let faceText = analysis.faceAverageLuminance?.percentText ?? "未知"
            let backgroundText = analysis.backgroundAverageLuminance?.percentText ?? "未知"
            append(
                .backlitSubject,
                severity: .strong,
                evidence: "人脸亮度为 \(faceText)，背景亮度为 \(backgroundText)，确认主体明显暗于背景。",
                to: &problems
            )
        }

        if analysis.noiseEstimate > 0.12 || analysis.semanticScene == .night ||
            (analysis.averageLuminance < 0.3 && analysis.shadowRatio > 0.3) {
            append(
                .noiseRisk,
                severity: analysis.noiseEstimate > 0.2 || analysis.shadowRatio > 0.58 ? .strong : .moderate,
                evidence: "高频残差估计为 \(analysis.noiseEstimate.percentText)，结合暗部占比判断提亮后的噪点风险。",
                to: &problems
            )
        }
    }

    private func append(
        _ kind: PhotoProblemKind,
        severity: PhotoProblemSeverity = .mild,
        evidence: String,
        to problems: inout [PhotoProblem]
    ) {
        problems.append(PhotoProblem(kind: kind, severity: severity, evidence: evidence))
    }
}

private extension Float {
    var percentText: String {
        "\(Int((self * 100).rounded()))%"
    }
}
