import Foundation

struct PhotoDiagnostics: Equatable, Sendable {
    let sections: [PhotoDiagnosticSection]

    init(photo: CapturedPhoto) {
        var sections: [PhotoDiagnosticSection] = []

        if let analysis = photo.analysis {
            sections.append(.analysis(analysis))
        }

        if let decision = photo.decision {
            sections.append(.decision(decision))
        }

        if let qualityCheck = photo.qualityCheck {
            sections.append(.quality(qualityCheck))
        }

        self.sections = sections
    }

    var isEmpty: Bool {
        sections.isEmpty
    }
}

struct PhotoDiagnosticSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let items: [PhotoDiagnosticItem]

    static func analysis(_ analysis: PhotoAnalysis) -> PhotoDiagnosticSection {
        PhotoDiagnosticSection(
            id: "analysis",
            title: "画面分析",
            items: [
                PhotoDiagnosticItem(label: "曝光", value: analysis.exposureProfile.title),
                PhotoDiagnosticItem(label: "亮度", value: analysis.averageLuminance.percentText),
                PhotoDiagnosticItem(label: "层次", value: analysis.contrastProfile.title),
                PhotoDiagnosticItem(label: "对比范围", value: analysis.contrastRange.percentText),
                PhotoDiagnosticItem(label: "色彩倾向", value: analysis.colorCast.title),
                PhotoDiagnosticItem(label: "人脸", value: analysis.faceCount.faceCountText)
            ]
        )
    }

    static func decision(_ decision: PhotographyDecision) -> PhotoDiagnosticSection {
        let actionItems = decision.actions.enumerated().map { index, action in
            PhotoDiagnosticItem(
                label: "动作 \(index + 1)",
                value: "\(action.title)：\(action.reason)"
            )
        }

        return PhotoDiagnosticSection(
            id: "decision",
            title: "AI 摄影决策",
            items: [
                PhotoDiagnosticItem(label: "场景", value: decision.sceneStrategy.title),
                PhotoDiagnosticItem(label: "意图", value: decision.intent)
            ] + actionItems
        )
    }

    static func quality(_ qualityCheck: QualityCheckResult) -> PhotoDiagnosticSection {
        let issueText = qualityCheck.issues.isEmpty
            ? "未发现明显问题"
            : qualityCheck.issues.map(\.title).joined(separator: "、")

        return PhotoDiagnosticSection(
            id: "quality",
            title: "成片质检",
            items: [
                PhotoDiagnosticItem(label: "状态", value: qualityCheck.status.title),
                PhotoDiagnosticItem(label: "问题", value: issueText),
                PhotoDiagnosticItem(label: "安全回退", value: qualityCheck.fallbackApplied ? "已启用" : "未启用"),
                PhotoDiagnosticItem(label: "成片亮度", value: qualityCheck.measuredAnalysis.averageLuminance.percentText),
                PhotoDiagnosticItem(label: "成片对比", value: qualityCheck.measuredAnalysis.contrastRange.percentText)
            ]
        )
    }
}

struct PhotoDiagnosticItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String

    init(label: String, value: String) {
        self.id = "\(label)-\(value)"
        self.label = label
        self.value = value
    }
}

private extension Float {
    var percentText: String {
        "\(Int((self * 100).rounded()))%"
    }
}

private extension Int {
    var faceCountText: String {
        self == 0 ? "未检测到" : "\(self) 张"
    }
}

private extension ExposureProfile {
    var title: String {
        switch self {
        case .underexposed:
            return "偏暗"
        case .balanced:
            return "曝光均衡"
        case .overexposed:
            return "偏亮"
        }
    }
}

private extension ContrastProfile {
    var title: String {
        switch self {
        case .flat:
            return "层次偏平"
        case .balanced:
            return "对比均衡"
        case .highContrast:
            return "高对比"
        }
    }
}

private extension ColorCast {
    var title: String {
        switch self {
        case .cool:
            return "偏冷"
        case .neutral:
            return "色彩自然"
        case .warm:
            return "偏暖"
        case .green:
            return "偏绿"
        }
    }
}

private extension QualityStatus {
    var title: String {
        switch self {
        case .passed:
            return "通过"
        case .warning:
            return "提醒"
        case .failed:
            return "失败"
        }
    }
}

