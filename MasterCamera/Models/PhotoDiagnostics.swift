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

        if let processingDiagnostics = photo.processingDiagnostics {
            sections.append(.processing(processingDiagnostics))
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
                PhotoDiagnosticItem(label: "细节代理", value: analysis.detailScore.percentText),
                PhotoDiagnosticItem(label: "噪点代理", value: analysis.noiseEstimate.percentText),
                PhotoDiagnosticItem(label: "纯黑/纯白", value: "\(analysis.blackRatio.percentText) / \(analysis.whiteRatio.percentText)"),
                PhotoDiagnosticItem(label: "中间调占比", value: analysis.midtoneRatio.percentText),
                PhotoDiagnosticItem(label: "混合光风险", value: analysis.mixedLightScore.percentText),
                PhotoDiagnosticItem(
                    label: "局部亮源",
                    value: "\(analysis.highlightSourceCount) 处 · 集中度 \(analysis.highlightConcentration.percentText) · 位置 \(analysis.highlightCentroidX.percentText)/\(analysis.highlightCentroidY.percentText)"
                ),
                PhotoDiagnosticItem(label: "空间光比", value: analysis.spatialLuminanceVariance.percentText),
                PhotoDiagnosticItem(label: "色彩倾向", value: analysis.colorCast.title),
                PhotoDiagnosticItem(
                    label: "场景识别状态",
                    value: "\(analysis.sceneRecognitionDiagnostics.status.rawValue) · 最高置信度 \(analysis.sceneRecognitionDiagnostics.topConfidence.percentText) · \(analysis.sceneRecognitionDiagnostics.reason ?? "可靠识别")"
                ),
                PhotoDiagnosticItem(
                    label: "局部分割状态",
                    value: "\(analysis.segmentationDiagnostics.status.rawValue) · \(analysis.segmentationDiagnostics.reason ?? "模型输出包含可用区域")"
                ),
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
                PhotoDiagnosticItem(
                    label: "区域覆盖率",
                    value: String(
                        format: "天空 %.1f%% · 地面 %.1f%% · 植被 %.1f%% · 水面 %.1f%% · 建筑 %.1f%%",
                        analysis.segmentationDiagnostics.skyCoverage * 100,
                        analysis.segmentationDiagnostics.groundCoverage * 100,
                        analysis.segmentationDiagnostics.vegetationCoverage * 100,
                        analysis.segmentationDiagnostics.waterCoverage * 100,
                        analysis.segmentationDiagnostics.architectureCoverage * 100
                    )
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
                PhotoDiagnosticItem(
                    label: "多维场景",
                    value: decision.context.sceneFacets.map(\.rawValue).joined(separator: "、")
                ),
                PhotoDiagnosticItem(
                    label: "光照条件",
                    value: decision.context.lightingConditions.map(\.rawValue).joined(separator: "、")
                ),
                PhotoDiagnosticItem(
                    label: "光向与空间",
                    value: String(
                        format: "%@ · 景深层次 %.0f%% · 氛围 %.0f%%",
                        decision.context.lightDirection.rawValue,
                        decision.context.spatialDepthScore * 100,
                        decision.context.atmosphereScore * 100
                    )
                ),
                PhotoDiagnosticItem(
                    label: "摄影风格判断",
                    value: "\(decision.context.style.rawValue)：\(decision.context.styleReason)"
                ),
                PhotoDiagnosticItem(label: "审美目标", value: decision.aestheticTarget.title),
                PhotoDiagnosticItem(label: "最终摄影观感", value: decision.treatmentPlan.finalLook),
                PhotoDiagnosticItem(label: "光线设计", value: decision.treatmentPlan.lightingDesign),
                PhotoDiagnosticItem(
                    label: "局部精修区域",
                    value: decision.treatmentPlan.regionalTreatments
                        .map { "\($0.region.rawValue)：\($0.objective)" }
                        .joined(separator: "；")
                ),
                PhotoDiagnosticItem(
                    label: "人物保护",
                    value: decision.treatmentPlan.portraitProtection.isActive
                        ? "严格：禁用人脸专属提亮、几何修改和生成式修复，保留皮肤纹理"
                        : "当前照片未检测到人物保护触发条件"
                ),
                PhotoDiagnosticItem(
                    label: "电影模式",
                    value: "\(decision.recipe.cinematicIntensity.title) · \(decision.recipe.cinematicToneStyle.rawValue)"
                ),
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
                        format: "曲线 %@/%.2f · 降噪 %.3f · 锐化 %.2f · 肤质保护 %.2f · 主体 %+.2f EV · 人脸 %+.2f EV",
                        decision.recipe.toneCurveStyle.rawValue,
                        decision.recipe.toneCurveAmount,
                        decision.recipe.noiseReductionAmount,
                        decision.recipe.sharpeningAmount,
                        decision.recipe.skinTextureProtection,
                        decision.recipe.subjectExposureEV,
                        decision.recipe.faceExposureEV
                    )
                ),
                PhotoDiagnosticItem(
                    label: "摄影调色",
                    value: String(
                        format: "强度 %.2f · 暗部冷 %.2f · 中间调暖 %.2f · 高光暖 %.2f · 色彩对比 %.2f",
                        decision.recipe.colorGradeIntensity,
                        decision.recipe.shadowCoolAmount,
                        decision.recipe.midtoneWarmAmount,
                        decision.recipe.highlightWarmAmount,
                        decision.recipe.colorContrast
                    )
                ),
                PhotoDiagnosticItem(
                    label: "七段影调",
                    value: String(
                        format: "黑位 %.3f · 阴影卷降 %.2f · 低中调 %+.3f · 中调 %+.3f · 高中调 %+.3f · 高光卷降 %.2f · 白位 %.3f",
                        decision.recipe.blackPoint,
                        decision.recipe.shadowRollOff,
                        decision.recipe.lowerMidtoneLift,
                        decision.recipe.midtoneBias,
                        decision.recipe.upperMidtoneSeparation,
                        decision.recipe.highlightRollOff,
                        decision.recipe.whitePoint
                    )
                ),
                PhotoDiagnosticItem(
                    label: "镜头质感",
                    value: String(
                        format: "Bloom %.3f · Halation %.3f · 阈值 %.2f · 颗粒 %.3f · 暗角 %.3f · 空间层次 %.3f",
                        decision.recipe.bloomIntensity,
                        decision.recipe.halationIntensity,
                        decision.recipe.highlightGlowThreshold,
                        decision.recipe.grainAmount,
                        decision.recipe.vignetteIntensity,
                        decision.recipe.backgroundSeparation
                    )
                ),
                PhotoDiagnosticItem(
                    label: "分区 HSL",
                    value: String(
                        format: "橙 S%+.2f/L%+.2f · 黄 S%+.2f/L%+.2f · 绿 S%+.2f/L%+.2f · 青 S%+.2f/L%+.2f · 蓝 S%+.2f/L%+.2f",
                        decision.recipe.hsl.orangeSaturation,
                        decision.recipe.hsl.orangeLuminance,
                        decision.recipe.hsl.yellowSaturation,
                        decision.recipe.hsl.yellowLuminance,
                        decision.recipe.hsl.greenSaturation,
                        decision.recipe.hsl.greenLuminance,
                        decision.recipe.hsl.cyanSaturation,
                        decision.recipe.hsl.cyanLuminance,
                        decision.recipe.hsl.blueSaturation,
                        decision.recipe.hsl.blueLuminance
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
                ),
                PhotoDiagnosticItem(
                    label: "亮度蒙版",
                    value: String(
                        format: "阴影 %+.2f EV · 高光 %+.2f EV · 强度 %.2f",
                        decision.recipe.shadowZoneExposureEV,
                        decision.recipe.highlightZoneExposureEV,
                        decision.recipe.luminanceMaskStrength
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

    static func processing(_ diagnostics: ImageProcessingDiagnostics) -> PhotoDiagnosticSection {
        let original = diagnostics.original
        let edited = diagnostics.edited
        let difference = diagnostics.difference
        let stageItems = diagnostics.stages.map { stage in
            PhotoDiagnosticItem(
                label: stage.name,
                value: "\(stage.durationMilliseconds) ms · \(stage.executed ? "已执行" : "跳过") · \(stage.detail)"
            )
        }

        return PhotoDiagnosticSection(
            id: "processing",
            title: "像素与处理链诊断",
            items: [
                PhotoDiagnosticItem(
                    label: "文件标识",
                    value: "原图 \(original.identifier) · 成片 \(edited.identifier)"
                ),
                PhotoDiagnosticItem(
                    label: "编码尺寸",
                    value: "原图 \(original.encodedPixelWidth)×\(original.encodedPixelHeight) · 成片 \(edited.encodedPixelWidth)×\(edited.encodedPixelHeight)"
                ),
                PhotoDiagnosticItem(
                    label: "解码尺寸",
                    value: "原图 \(original.decodedPixelWidth)×\(original.decodedPixelHeight) · 成片 \(edited.decodedPixelWidth)×\(edited.decodedPixelHeight)"
                ),
                PhotoDiagnosticItem(
                    label: "方向",
                    value: "原图 EXIF \(original.exifOrientation) · 成片 EXIF \(edited.exifOrientation)"
                ),
                PhotoDiagnosticItem(
                    label: "色彩空间",
                    value: "原图 \(original.colorModel)/\(original.colorProfile) · 成片 \(edited.colorModel)/\(edited.colorProfile)"
                ),
                PhotoDiagnosticItem(
                    label: "真实差异",
                    value: String(
                        format: "RGB MAE %.2f%% · 亮度 %.2f%% · 颜色 %.2f%% · 变化像素 %.1f%%",
                        difference.normalizedMeanAbsoluteRGBDifference * 100,
                        difference.meanAbsoluteLuminanceDifference * 100,
                        difference.meanAbsoluteColorDifference * 100,
                        difference.changedPixelRatio * 100
                    )
                ),
                PhotoDiagnosticItem(
                    label: "平均亮度",
                    value: String(
                        format: "原图 %.1f%% · 成片 %.1f%% · 改变 %+.1f%%",
                        difference.originalAverageLuminance * 100,
                        difference.editedAverageLuminance * 100,
                        (difference.editedAverageLuminance - difference.originalAverageLuminance) * 100
                    )
                ),
                PhotoDiagnosticItem(
                    label: "平均 RGB",
                    value: "原图 \(difference.originalMeanRGB.rgbText) · 成片 \(difference.editedMeanRGB.rgbText)"
                ),
                PhotoDiagnosticItem(
                    label: "亮度直方图",
                    value: "原图 \(difference.originalLuminanceHistogram.histogramText)\n成片 \(difference.editedLuminanceHistogram.histogramText)"
                ),
                PhotoDiagnosticItem(
                    label: "执行模块",
                    value: diagnostics.executedModules.joined(separator: " → ")
                ),
                PhotoDiagnosticItem(
                    label: "局部执行回执",
                    value: diagnostics.regionalExecutionDetails.joined(separator: "；")
                ),
                PhotoDiagnosticItem(
                    label: "降级原因",
                    value: diagnostics.fallbackReason ?? "无"
                )
            ] + stageItems
        )
    }
}

private extension Array where Element == Float {
    var rgbText: String {
        guard count >= 3 else { return "不可用" }
        return String(format: "%.0f/%.0f/%.0f", self[0] * 255, self[1] * 255, self[2] * 255)
    }

    var histogramText: String {
        let symbols: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        return map { value in
            let level = Swift.min(8, Swift.max(0, Int((value * 64).rounded())))
            return String(symbols[level])
        }
        .joined()
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

