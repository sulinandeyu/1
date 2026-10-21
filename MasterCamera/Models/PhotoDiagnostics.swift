import Foundation

struct PhotoDiagnostics: Equatable, Sendable {
    let sections: [PhotoDiagnosticSection]

    init(photo: CapturedPhoto) {
        var sections: [PhotoDiagnosticSection] = []

        if let analysis = photo.analysis {
            sections.append(.analysis(analysis))
        }

        if let problemReport = photo.problemReport {
            sections.append(.problems(problemReport))
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
                PhotoDiagnosticItem(label: "暗部占比", value: analysis.shadowRatio.percentText),
                PhotoDiagnosticItem(label: "高光占比", value: analysis.highlightRatio.percentText),
                PhotoDiagnosticItem(label: "层次", value: analysis.contrastProfile.title),
                PhotoDiagnosticItem(label: "对比范围", value: analysis.contrastRange.percentText),
                PhotoDiagnosticItem(label: "平均饱和度", value: analysis.averageSaturation.percentText),
                PhotoDiagnosticItem(label: "色彩倾向", value: analysis.colorCast.title),
                PhotoDiagnosticItem(label: "人脸", value: analysis.faceCount.faceCountText),
                PhotoDiagnosticItem(
                    label: "人脸测光",
                    value: analysis.faceAverageLuminance.optionalPercentText
                ),
                PhotoDiagnosticItem(
                    label: "背景测光",
                    value: analysis.backgroundAverageLuminance.optionalPercentText
                ),
                PhotoDiagnosticItem(
                    label: "人脸/背景亮度差",
                    value: analysis.faceToBackgroundLuminanceDelta.optionalSignedPercentText
                ),
                PhotoDiagnosticItem(label: "人物蒙版", value: analysis.personMask.maskSummary),
                PhotoDiagnosticItem(label: "主体蒙版", value: analysis.salientSubjectMask.maskSummary),
                PhotoDiagnosticItem(label: "皮肤蒙版", value: analysis.skinMask.maskSummary),
                PhotoDiagnosticItem(
                    label: "天空蒙版",
                    value: analysis.skyMask == nil
                        ? "未检测到"
                        : "\(analysis.skyMask.maskSummary) · 占画面 \(analysis.skyCoverage.percentText)"
                ),
                PhotoDiagnosticItem(label: "语义标签", value: analysis.semanticLabels.labelSummary)
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
                PhotoDiagnosticItem(label: "审美目标", value: decision.aestheticTarget.title),
                PhotoDiagnosticItem(label: "意图", value: decision.intent),
                PhotoDiagnosticItem(
                    label: "明暗参数",
                    value: String(
                        format: "曝光 %+.2f EV · 高光 %.2f · 阴影 %.2f",
                        decision.recipe.exposureEV,
                        decision.recipe.highlightAmount,
                        decision.recipe.shadowAmount
                    )
                ),
                PhotoDiagnosticItem(
                    label: "色彩参数",
                    value: String(
                        format: "色温 %+.0fK · 色调 %+.1f · 饱和 %.2f · 自然饱和 %.2f",
                        decision.recipe.temperatureShift,
                        decision.recipe.tintShift,
                        decision.recipe.saturation,
                        decision.recipe.vibrance
                    )
                ),
                PhotoDiagnosticItem(
                    label: "细节参数",
                    value: String(
                        format: "曲线 %.2f · 降噪 %.3f · 锐化 %.2f · 肤质保护 %.2f · 主体 %+.2f EV · 人脸 %+.2f EV",
                        decision.recipe.toneCurveAmount,
                        decision.recipe.noiseReductionAmount,
                        decision.recipe.sharpeningAmount,
                        decision.recipe.skinTextureProtection,
                        decision.recipe.subjectExposureEV,
                        decision.recipe.faceExposureEV
                    )
                ),
                PhotoDiagnosticItem(
                    label: "天空参数",
                    value: String(
                        format: "曝光 %+.2f EV · 高光 %.2f · 饱和 %.2f",
                        decision.recipe.skyExposureEV,
                        decision.recipe.skyHighlightAmount,
                        decision.recipe.skySaturation
                    )
                )
            ] + actionItems
        )
    }

    static func problems(_ report: PhotoProblemReport) -> PhotoDiagnosticSection {
        let items = report.isEmpty
            ? [PhotoDiagnosticItem(label: "结论", value: "未发现需要主动修正的明显问题")]
            : report.problems.enumerated().map { index, problem in
                PhotoDiagnosticItem(
                    label: "问题 \(index + 1) · \(problem.severity.title)",
                    value: "\(problem.kind.title)：\(problem.evidence)"
                )
            }

        return PhotoDiagnosticSection(
            id: "problems",
            title: "摄影问题诊断",
            items: items
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

private extension Optional where Wrapped == Float {
    var optionalPercentText: String {
        guard let value = self else { return "未测得" }
        return value.percentText
    }

    var optionalSignedPercentText: String {
        guard let value = self else { return "未测得" }
        return String(format: "%+.0f%%", value * 100)
    }
}

private extension Int {
    var faceCountText: String {
        self == 0 ? "未检测到" : "\(self) 张"
    }
}

private extension Array where Element == SceneLabel {
    var labelSummary: String {
        guard !isEmpty else { return "未识别" }
        return prefix(4)
            .map { "\($0.identifier) \(Int(($0.confidence * 100).rounded()))%" }
            .joined(separator: "、")
    }
}

private extension Optional where Wrapped == NormalizedPhotoMask {
    var maskSummary: String {
        guard let mask = self, mask.isValid else { return "未检测到" }
        return "已生成 \(mask.width)×\(mask.height)"
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

