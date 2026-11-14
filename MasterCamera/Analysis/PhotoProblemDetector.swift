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
    let affectedRegions: [TreatmentRegion]
    let recommendation: String
    let risk: String
    let confidence: Float

    init(
        kind: PhotoProblemKind,
        severity: PhotoProblemSeverity,
        evidence: String,
        affectedRegions: [TreatmentRegion] = [.global],
        recommendation: String = "根据实测结果进行克制的摄影调整。",
        risk: String = "调整过强可能破坏原始光影关系。",
        confidence: Float = 0.7
    ) {
        self.kind = kind
        self.severity = severity
        self.evidence = evidence
        self.affectedRegions = affectedRegions
        self.recommendation = recommendation
        self.risk = risk
        self.confidence = min(1, max(0, confidence))
    }
}

enum PhotographyDiagnosisExecutionStatus: String, Equatable, Sendable {
    case executable
    case analysisOnly
    case unavailable
}

/// Structured photography diagnosis produced from the same measurements used
/// by the existing decision engine. It does not invent a new renderer or a new
/// aesthetic rule set; it makes the evidence, boundary and execution state of
/// each existing problem explicit. See PT-DIAGNOSIS-001.
struct PhotographyDiagnosisEvidence: Equatable, Sendable {
    let identifier: String
    let status: VisualEvidenceStatus
    let problemKind: PhotoProblemKind?
    let severity: PhotoProblemSeverity
    let affectedRegions: [TreatmentRegion]
    let measurementBasis: String
    let photographicMeaning: String
    let adjustmentDirection: String
    let sideEffects: String
    let confidence: Float
    let executionStatus: PhotographyDiagnosisExecutionStatus
    let knowledgeRuleIDs: [PhotographyKnowledgeRuleID]

    var traceSummary: String {
        "\(identifier){status=\(status.rawValue);severity=\(severity.title);regions=\(affectedRegions.map(\.rawValue).joined(separator: ","));measurements=\(measurementBasis);meaning=\(photographicMeaning);direction=\(adjustmentDirection);sideEffects=\(sideEffects);confidence=\(String(format: "%.3f", confidence));execution=\(executionStatus.rawValue);rules=\(knowledgeRuleIDs.map(\.rawValue).joined(separator: ","))}"
    }
}

struct StructuredPhotographyDiagnosis: Equatable, Sendable {
    let status: VisualEvidenceStatus
    let evidence: [PhotographyDiagnosisEvidence]
    let unknowns: [String]

    var traceSummary: String {
        "status=\(status.rawValue) evidence=[\(evidence.map(\.traceSummary).joined(separator: " | "))] unknown=[\(unknowns.joined(separator: ","))]"
    }
}

enum PhotoProblemKind: String, Equatable, Hashable, Sendable {
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
    case regionalUnderexposure
    case regionalFlatness
    case regionalHighlightRisk

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
        case .regionalUnderexposure: return "局部区域偏暗"
        case .regionalFlatness: return "局部层次不足"
        case .regionalHighlightRisk: return "局部高光风险"
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
        detectRegionalProblems(in: analysis, problems: &problems)
        detectColorProblems(in: analysis, problems: &problems)
        detectSceneSpecificProblems(in: analysis, problems: &problems)

        return PhotoProblemReport(problems: problems)
    }

    func structuredDiagnosis(
        in analysis: PhotoAnalysis,
        report: PhotoProblemReport? = nil
    ) -> StructuredPhotographyDiagnosis {
        let resolvedReport = report ?? detect(in: analysis)
        let understanding = analysis.visualSceneUnderstanding
        var diagnosis = resolvedReport.problems.enumerated().map { index, problem in
            diagnosisEvidence(problem, index: index, analysis: analysis, understanding: understanding)
        }

        if let relationship = understanding.regionRelationships.first(where: {
            $0.identifier == "ground-versus-vegetation" && $0.status == .reliable
        }), let luminanceDelta = relationship.luminanceDelta,
           let saturationDelta = relationship.saturationDelta,
           abs(luminanceDelta) >= 0.035 || abs(saturationDelta) >= 0.05 {
            let groundEvidence = understanding.regionEvidence.first { $0.kind == .ground }
            let vegetationEvidence = understanding.regionEvidence.first { $0.kind == .vegetation }
            let isEligibleForLocalAdjustment = groundEvidence?.isExecutableForLocalAdjustment == true
                && vegetationEvidence?.isExecutableForLocalAdjustment == true
            diagnosis.append(PhotographyDiagnosisEvidence(
                identifier: "VISUAL-RELATION-GROUND-VEGETATION",
                status: .reliable,
                problemKind: nil,
                severity: abs(luminanceDelta) >= 0.16 ? .moderate : .mild,
                affectedRegions: [.ground, .vegetation],
                measurementBasis: String(
                    format: "地面-植被亮度差 %+.3f、饱和度差 %+.3f；区域置信度 %.3f。",
                    luminanceDelta,
                    saturationDelta,
                    relationship.confidence
                ),
                photographicMeaning: "空间平面与颜色更丰富区域的视觉权重可能失衡；该证据不声明道路或树叶是主体。",
                adjustmentDirection: "仅在两侧蒙版可靠时建立相对明暗/颜色层级目标，参数由当前像素残差求解。",
                sideEffects: "错误压暗可能造成死黑、车辆/建筑中性色损伤或蒙版边缘光晕。",
                confidence: relationship.confidence,
                // `executable` is an eligibility result at diagnosis time. It is
                // deliberately not evidence that a parameter was planned or a
                // pixel was rendered; those later states are recorded by D.
                executionStatus: isEligibleForLocalAdjustment ? .executable : .analysisOnly,
                knowledgeRuleIDs: [.structuredRegionEvidence, .evidenceBasedPhotographyDiagnosis, .measuredVisualHierarchy, .regionalColorHarmony]
            ))
        }

        var unknowns = understanding.unknowns
        if diagnosis.isEmpty {
            unknowns.append("未发现达到当前诊断阈值的摄影技术问题；不等于照片已经具有专业审美")
        }
        let status: VisualEvidenceStatus
        if understanding.status == .unavailable {
            status = .unavailable
        } else if diagnosis.contains(where: { $0.status == .reliable }) {
            status = .reliable
        } else {
            status = .uncertain
        }
        return StructuredPhotographyDiagnosis(
            status: status,
            evidence: diagnosis,
            unknowns: Array(Set(unknowns)).sorted()
        )
    }

    private func diagnosisEvidence(
        _ problem: PhotoProblem,
        index: Int,
        analysis: PhotoAnalysis,
        understanding: VisualSceneUnderstandingResult
    ) -> PhotographyDiagnosisEvidence {
        let regionalEvidence: [VisualRegionEvidence] = problem.affectedRegions.compactMap { region -> VisualRegionEvidence? in
            guard let kind = visualKind(for: region) else { return nil }
            understanding.regionEvidence.first { evidence in
                evidence.kind == kind
            }
        }
        let requiresLocalMask = problem.affectedRegions.contains { $0 != .global && $0 != .background }
        let localExecutable = !requiresLocalMask || (
            !regionalEvidence.isEmpty
                && regionalEvidence.allSatisfy { $0.isExecutableForLocalAdjustment }
        )
        let involvesPerson = problem.affectedRegions.contains(.person)
        let executionStatus: PhotographyDiagnosisExecutionStatus
        if involvesPerson {
            executionStatus = .analysisOnly
        } else if localExecutable {
            executionStatus = .executable
        } else {
            executionStatus = .analysisOnly
        }
        let status: VisualEvidenceStatus = requiresLocalMask && regionalEvidence.isEmpty
            ? .uncertain
            : .reliable
        let metrics = regionalEvidence.map { $0.traceSummary }.joined(separator: " | ")
        return PhotographyDiagnosisEvidence(
            identifier: String(format: "PHOTO-PROBLEM-%03d-%@", index + 1, problem.kind.rawValue.uppercased()),
            status: status,
            problemKind: problem.kind,
            severity: problem.severity,
            affectedRegions: problem.affectedRegions,
            measurementBasis: metrics.isEmpty ? problem.evidence : "\(problem.evidence)；\(metrics)",
            photographicMeaning: photographicMeaning(for: problem.kind),
            adjustmentDirection: problem.recommendation,
            sideEffects: problem.risk,
            confidence: problem.confidence,
            executionStatus: executionStatus,
            knowledgeRuleIDs: knowledgeRules(for: problem.kind, local: requiresLocalMask)
        )
    }

    private func visualKind(for region: TreatmentRegion) -> VisualRegionKind? {
        switch region {
        case .sky: return .sky
        case .person: return .person
        case .subject: return .salientSubject
        case .ground: return .ground
        case .vegetation: return .vegetation
        case .water: return .water
        case .architecture: return .architecture
        case .global, .background: return nil
        }
    }

    private func photographicMeaning(for kind: PhotoProblemKind) -> String {
        switch kind {
        case .underexposed: return "整体可读性不足，但暗部噪声会限制恢复幅度。"
        case .overexposed: return "画面亮度权重过高，可能削弱主体和空间层次。"
        case .clippedHighlights: return "真实高光和材质接近丢失，不能伪造已经剪切的细节。"
        case .blockedShadows: return "暗部层次不足；夜景或有意低调影调不能被机械提亮。"
        case .flatContrast: return "前中后景与主体背景分离不足。"
        case .harshContrast: return "明暗跨度可能造成高光和暗部同时损伤。"
        case .coolCast, .warmCast, .greenCast: return "可靠中性色显示可能的综合色偏，但现场氛围必须保留。"
        case .oversaturated: return "颜色身份和材质可能失真。"
        case .noiseRisk: return "提亮、清晰度与锐化可能把噪声强化为假纹理。"
        case .backlitSubject: return "主体与背景亮度关系可能削弱视觉重心；人物只允许摄影级整体处理。"
        case .regionalUnderexposure: return "可靠区域的中间调不足。"
        case .regionalFlatness: return "可靠区域内部缺少可读层次。"
        case .regionalHighlightRisk: return "可靠区域高光可能压缩材质与真实光源形态。"
        }
    }

    private func knowledgeRules(
        for kind: PhotoProblemKind,
        local: Bool
    ) -> [PhotographyKnowledgeRuleID] {
        var rules: [PhotographyKnowledgeRuleID] = [.evidenceBasedPhotographyDiagnosis]
        if local { rules += [.structuredRegionEvidence, .reliableSemanticMask] }
        switch kind {
        case .underexposed, .overexposed, .clippedHighlights, .blockedShadows:
            rules.append(.toneHistogramRegions)
        case .flatContrast, .harshContrast, .regionalUnderexposure, .regionalFlatness, .regionalHighlightRisk:
            rules.append(.measuredToneCurve)
        case .coolCast, .warmCast, .greenCast:
            rules.append(.neutralEvidenceWhiteBalance)
        case .oversaturated:
            rules.append(.regionalColorHarmony)
        case .noiseRisk:
            rules.append(.noiseAwareDetail)
        case .backlitSubject:
            rules.append(.portraitSourceRelativeProtection)
        }
        return Array(Set(rules))
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

        guard let neutral = analysis.neutralColorStatistics, neutral.isReliable else {
            return
        }

        let lighting = Set(analysis.photographyContext.lightingConditions)
        let atmosphereMayBeIntentional = !lighting.isDisjoint(with: [
            .sunrise, .goldenHour, .blueHour, .dusk, .night, .indoorArtificial, .mixed
        ])
        let temperatureThreshold: Float = atmosphereMayBeIntentional ? 0.05 : 0.028
        let tintThreshold: Float = atmosphereMayBeIntentional ? 0.04 : 0.022
        let evidencePrefix = String(
            format: "排除人脸后的中性色样本覆盖 %.1f%%、空间覆盖 %.1f%%、置信度 %.0f%%；",
            neutral.coverage * 100,
            neutral.spatialZoneCoverage * 100,
            neutral.confidence * 100
        )

        if neutral.warmBias <= -temperatureThreshold {
            append(
                .coolCast,
                evidence: evidencePrefix + String(format: "中性色 B-R 偏差为 %.3f。", -neutral.warmBias),
                to: &problems
            )
        } else if neutral.warmBias >= temperatureThreshold {
            append(
                .warmCast,
                evidence: evidencePrefix + String(format: "中性色 R-B 偏差为 %.3f。", neutral.warmBias),
                to: &problems
            )
        }

        if neutral.greenBias >= tintThreshold {
            append(
                .greenCast,
                evidence: evidencePrefix + String(format: "中性色 G-(R+B)/2 偏差为 %.3f。", neutral.greenBias),
                to: &problems
            )
        }
    }

    private func detectRegionalProblems(
        in analysis: PhotoAnalysis,
        problems: inout [PhotoProblem]
    ) {
        let regions: [(TreatmentRegion, NormalizedPhotoMask?, PhotoRegionStatistics?)] = [
            (.subject, analysis.salientSubjectMask, analysis.salientSubjectStatistics),
            (.sky, analysis.skyMask, analysis.skyStatistics),
            (.ground, analysis.groundMask, analysis.groundStatistics),
            (.vegetation, analysis.vegetationMask, analysis.vegetationStatistics),
            (.water, analysis.waterMask, analysis.waterStatistics),
            (.architecture, analysis.architectureMask, analysis.architectureStatistics)
        ]
        let isNight = analysis.photographyContext.lightingConditions.contains(.night)
        for (region, optionalMask, optionalStatistics) in regions {
            guard
                let mask = optionalMask,
                mask.qualityAssessment.isUsable,
                mask.activeCoverage >= 0.01,
                mask.activeCoverage <= 0.82,
                let statistics = optionalStatistics
            else { continue }
            let coverageConfidence = min(0.95, max(0.58, mask.activeCoverage * 2.6))
            let confidence = region == .subject
                ? min(coverageConfidence, analysis.salientSubjectPriorityConfidence)
                : coverageConfidence
            if region == .subject, confidence < 0.54 { continue }
            let darkLimit: Float = isNight ? 0.16 : 0.25
            if region != .sky,
               statistics.averageLuminance < darkLimit,
               statistics.shadowRatio > 0.38 {
                appendRegional(
                    .regionalUnderexposure,
                    region: region,
                    severity: statistics.averageLuminance < darkLimit - 0.08 ? .strong : .moderate,
                    evidence: String(
                        format: "%@区域亮度 %.1f%%、阴影 %.1f%%，明显影响区域层次。",
                        region.rawValue,
                        statistics.averageLuminance * 100,
                        statistics.shadowRatio * 100
                    ),
                    recommendation: "只在可靠\(region.rawValue)蒙版内恢复可用中间调。",
                    risk: "限制局部提亮，避免噪声和蒙版边缘光晕。",
                    confidence: confidence,
                    to: &problems
                )
            }
            if region != .sky, statistics.contrastRange < 0.3 {
                appendRegional(
                    .regionalFlatness,
                    region: region,
                    severity: statistics.contrastRange < 0.2 ? .strong : .moderate,
                    evidence: String(
                        format: "%@区域 5%%–95%% 亮度跨度仅 %.1f%%。",
                        region.rawValue,
                        statistics.contrastRange * 100
                    ),
                    recommendation: "在该区域增加克制的局部对比和纹理分离。",
                    risk: "不得通过全图强对比制造伪 HDR。",
                    confidence: confidence,
                    to: &problems
                )
            }
            if statistics.highlightRatio > 0.16 {
                appendRegional(
                    .regionalHighlightRisk,
                    region: region,
                    severity: statistics.highlightRatio > 0.28 ? .strong : .moderate,
                    evidence: String(
                        format: "%@区域高光占 %.1f%%。",
                        region.rawValue,
                        statistics.highlightRatio * 100
                    ),
                    recommendation: "只控制该区域可恢复高光并保留光源质感。",
                    risk: "禁止把真实灯光或太阳压成灰色。",
                    confidence: confidence,
                    to: &problems
                )
            }
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
        let guidance = guidance(for: kind)
        let confidence = min(0.96, 0.64 + Float(severity.rawValue) * 0.1)
        problems.append(PhotoProblem(
            kind: kind,
            severity: severity,
            evidence: evidence,
            affectedRegions: guidance.regions,
            recommendation: guidance.recommendation,
            risk: guidance.risk,
            confidence: confidence
        ))
    }

    private func guidance(
        for kind: PhotoProblemKind
    ) -> (regions: [TreatmentRegion], recommendation: String, risk: String) {
        switch kind {
        case .underexposed:
            return ([.global, .ground], "恢复可用中间调和阴影，不抬高真实黑位。", "暗部提亮可能放大噪声。")
        case .overexposed:
            return ([.global, .sky], "降低曝光并压缩可恢复高光。", "过度压暗会使画面灰脏。")
        case .clippedHighlights:
            return ([.global, .sky], "保护亮部端点并压缩高光过渡。", "已剪切细节不能被伪造恢复。")
        case .blockedShadows:
            return ([.ground, .architecture, .global], "优先在暗部区域恢复层次。", "阴影恢复过强会放大噪声并削弱夜景氛围。")
        case .flatContrast:
            return ([.global, .subject], "增加中间调分离和局部对比。", "过强会产生光晕和 HDR 感。")
        case .harshContrast:
            return ([.global, .sky, .ground], "压缩两端并保留主体与环境光比。", "过度压缩会让画面失去立体感。")
        case .coolCast:
            return ([.global], "在非场景性冷色下进行有限白平衡校正。", "不得消除蓝调时刻等真实冷色氛围。")
        case .warmCast:
            return ([.global], "在非场景性暖色下进行有限白平衡校正。", "不得中和室内暖灯或日落色彩。")
        case .greenCast:
            return ([.global], "校正非自然绿色偏移并保护植被记忆色。", "全局去绿可能污染植物与肤色。")
        case .oversaturated:
            return ([.global, .sky, .vegetation], "降低过饱和颜色并保持色彩分离。", "统一降饱和会使主体失去活力。")
        case .noiseRisk:
            return ([.global, .ground, .architecture], "限制暗部提亮并执行适度降噪。", "过度降噪会抹除真实纹理。")
        case .backlitSubject:
            return ([.person, .subject, .background], "仅在可靠整人物或主体蒙版内协调曝光。", "禁止人脸专属提亮及任何外貌修改。")
        case .regionalUnderexposure:
            return ([.global], "仅恢复问题区域内的可用暗部。", "局部提亮可能放大噪声。")
        case .regionalFlatness:
            return ([.global], "仅增强问题区域的层次和纹理。", "避免明显光晕和 HDR 感。")
        case .regionalHighlightRisk:
            return ([.global], "仅压缩问题区域内可恢复高光。", "避免把真实高亮物体压灰。")
        }
    }

    private func appendRegional(
        _ kind: PhotoProblemKind,
        region: TreatmentRegion,
        severity: PhotoProblemSeverity,
        evidence: String,
        recommendation: String,
        risk: String,
        confidence: Float,
        to problems: inout [PhotoProblem]
    ) {
        problems.append(PhotoProblem(
            kind: kind,
            severity: severity,
            evidence: evidence,
            affectedRegions: [region],
            recommendation: recommendation,
            risk: risk,
            confidence: confidence
        ))
    }
}

private extension Float {
    var percentText: String {
        "\(Int((self * 100).rounded()))%"
    }
}
