import Foundation
import Darwin

final class PhotoProcessingPipeline {
    private let analyzer: PhotoAnalyzer
    private let problemDetector: PhotoProblemDetector
    private let photographyDirector: PhotographyDirector
    private let candidatePlanner: PhotographyCandidatePlanner
    private let renderer: CoreImageRenderer
    private let qualityService: QualityCheckService
    private let diagnosticsService: ImageProcessingDiagnosticsService
    private let configuration: ProcessingConfiguration
    private let referenceMatcher: PhotographyReferenceMatcher?

    init(
        analyzer: PhotoAnalyzer = PhotoAnalyzer(),
        problemDetector: PhotoProblemDetector = PhotoProblemDetector(),
        photographyDirector: PhotographyDirector = PhotographyDirector(),
        candidatePlanner: PhotographyCandidatePlanner = PhotographyCandidatePlanner(),
        renderer: CoreImageRenderer = CoreImageRenderer(),
        qualityService: QualityCheckService = QualityCheckService(),
        diagnosticsService: ImageProcessingDiagnosticsService = ImageProcessingDiagnosticsService(),
        configuration: ProcessingConfiguration = .current,
        referenceMatcher: PhotographyReferenceMatcher? = PhotographyReferenceMatcher.loadBundledForValidation()
    ) {
        self.analyzer = analyzer
        self.problemDetector = problemDetector
        self.photographyDirector = photographyDirector
        self.candidatePlanner = candidatePlanner
        self.renderer = renderer
        self.qualityService = qualityService
        self.diagnosticsService = diagnosticsService
        self.configuration = configuration
        self.referenceMatcher = referenceMatcher
    }

    func process(_ photo: CapturedPhoto) throws -> CapturedPhoto {
        let totalStart = ProcessInfo.processInfo.systemUptime
        let startingMemory = Self.memoryFootprint()
        let analysisStart = totalStart
        // 1. 理解照片
        let analysis = try analyzer.analyze(
            data: photo.originalImageData,
            capturedSkinMask: photo.skinMask
        )
        let analysisDuration = ProcessInfo.processInfo.systemUptime - analysisStart
        AppLogger.imageEngine.info(
            "分析完成 \(Self.milliseconds(analysisDuration))ms：\(analysis.traceSummary, privacy: .public)"
        )
        // 2. 找问题
        let decisionStart = ProcessInfo.processInfo.systemUptime
        let problemReport = problemDetector.detect(in: analysis)
        // 3–4. 生成逐图摄影目标并动态求解参数
        let decision = photographyDirector.direct(analysis: analysis, problems: problemReport)
        let decisionDuration = ProcessInfo.processInfo.systemUptime - decisionStart
        let treatmentTrace = decision.treatmentPlan.regionalTreatments
            .map { treatment in
                "\(treatment.region.rawValue){confidence=\(String(format: "%.2f", treatment.confidence)); \(treatment.parameters)}"
            }
            .joined(separator: "；")
        let parameterEvidenceTrace = decision.parameterEvidence
            .map {
                let rules = $0.knowledgeRuleIDs.map(\.rawValue).joined(separator: ",")
                return "\($0.key.rawValue){rules=\(rules); input=\($0.inputEvidence); target=\($0.target); range=\($0.minimumValue)...\($0.maximumValue); value=\($0.actualValue); region=\($0.affectedRegion.rawValue); status=\($0.decisionStatus.rawValue)}"
            }
            .joined(separator: "；")
        AppLogger.imageEngine.info(
            "摄影总监决策完成 \(Self.milliseconds(decisionDuration))ms：场景仅作分析=\(decision.sceneStrategy.rawValue)，逐图目标=\(decision.adaptiveTarget.summaryText, privacy: .public)，目标依据=\(decision.adaptiveTarget.rationale, privacy: .public)，区域计划=[\(treatmentTrace, privacy: .public)]，逐图参数=[\(parameterEvidenceTrace, privacy: .public)]，人物保护=\(decision.treatmentPlan.portraitProtection.isActive)，问题=[\(problemReport.problems.map { $0.kind.rawValue }.joined(separator: ","), privacy: .public)]，配方=\(decision.recipe.traceSummary, privacy: .public)"
        )
        // 5. 先在低分辨率预览上比较由同一摄影决策派生的候选。
        let candidateStart = ProcessInfo.processInfo.systemUptime
        let candidateResult = try evaluateCandidates(
            originalData: photo.originalImageData,
            decision: decision,
            analysis: analysis,
            problems: problemReport,
            retainPreviews: photo.isDiagnosticImport
        )
        let candidateDuration = ProcessInfo.processInfo.systemUptime - candidateStart
        let selectedDecision = decision.replacingRecipe(
            with: candidateResult.plan.recipe,
            analysis: analysis
        )
        AppLogger.imageEngine.info(
            "候选评估完成 \(Self.milliseconds(candidateDuration))ms：选择=\(candidateResult.plan.intent.rawValue, privacy: .public)，原因=\(candidateResult.selectionReason, privacy: .public)"
        )

        // 6. 只对优胜方案执行完整分辨率渲染。
        let renderStart = ProcessInfo.processInfo.systemUptime
        let initialEditedData = try renderer.renderAutomaticEdit(
            from: photo.originalImageData,
            recipe: selectedDecision.recipe,
            analysis: analysis
        )
        let initialRegionalExecutionDetails = renderer.regionalExecutionDetails(
            for: selectedDecision.recipe,
            analysis: analysis
        )
        let recognitionReason = analysis.sceneRecognitionDiagnostics.reason ?? "none"
        let segmentationReason = analysis.segmentationDiagnostics.reason ?? "none"
        let regionalExecutionSummary = initialRegionalExecutionDetails.joined(separator: "；")
        AppLogger.imageEngine.info(
            "识别/分割状态：scene=\(analysis.sceneRecognitionDiagnostics.status.rawValue, privacy: .public) confidence=\(analysis.sceneRecognitionDiagnostics.topConfidence) reason=\(recognitionReason, privacy: .public)；segmentation=\(analysis.segmentationDiagnostics.status.rawValue, privacy: .public) reason=\(segmentationReason, privacy: .public)；区域回执=[\(regionalExecutionSummary, privacy: .public)]"
        )
        let renderDuration = ProcessInfo.processInfo.systemUptime - renderStart
        // 7. 与原片比较并检查成片质量；最多只允许一次有边界修正。
        let qualityStart = ProcessInfo.processInfo.systemUptime
        let initialQualityCheck = try qualityService.check(
            originalData: photo.originalImageData,
            editedData: initialEditedData,
            sourceAnalysis: analysis,
            expectedRegions: selectedDecision.treatmentPlan.regionalTreatments.map(\.region),
            regionalExecutionDetails: initialRegionalExecutionDetails
        )
        let finalEdit = try chooseFinalEdit(
            originalData: photo.originalImageData,
            initialEditedData: initialEditedData,
            initialQualityCheck: initialQualityCheck,
            initialRecipe: selectedDecision.recipe,
            target: selectedDecision.adaptiveTarget,
            analysis: analysis,
            expectedRegions: selectedDecision.treatmentPlan.regionalTreatments.map(\.region)
        )
        let finalDecision = selectedDecision.replacingRecipe(
            with: finalEdit.recipe,
            analysis: analysis
        )
        let qualityDuration = ProcessInfo.processInfo.systemUptime - qualityStart
        let totalDuration = ProcessInfo.processInfo.systemUptime - totalStart
        let finishingMemory = Self.memoryFootprint()
        AppLogger.imageEngine.info(
            "处理完成：渲染=\(Self.milliseconds(renderDuration))ms，质检/回退=\(Self.milliseconds(qualityDuration))ms，总计=\(Self.milliseconds(totalDuration))ms，状态=\(finalEdit.qualityCheck.status.rawValue)，安全回退=\(finalEdit.qualityCheck.fallbackApplied)，RGB_MAE=\(finalEdit.qualityCheck.processingImpact.normalizedMeanAbsoluteRGBDifference)，变化像素=\(finalEdit.qualityCheck.processingImpact.changedPixelRatio)，肤色偏移=\(finalEdit.qualityCheck.colorIntegrity.skinColorDifference)，中性色染色=\(finalEdit.qualityCheck.colorIntegrity.neutralChromaIncrease)，最终配方=\(finalEdit.recipe.traceSummary, privacy: .public)"
        )

        // The reference-driven path is an isolated experiment. It runs only for
        // explicit diagnostic imports, produces candidate C, and never replaces B.
        let referenceValidation = evaluateReferenceCandidate(
            originalData: photo.originalImageData,
            analysis: analysis,
            problems: problemReport,
            isDiagnosticImport: photo.isDiagnosticImport
        )

        var stageRecords = [
            ProcessingStageRecord(
                name: "照片理解",
                durationMilliseconds: Self.milliseconds(analysisDuration),
                executed: true,
                detail: "\(analysis.semanticScene.rawValue) · \(analysis.semanticLabels.count) 个语义标签"
            ),
            ProcessingStageRecord(
                name: "问题诊断与摄影总监方案",
                durationMilliseconds: Self.milliseconds(decisionDuration),
                executed: true,
                detail: "\(problemReport.problems.count) 个问题 · \(decision.sceneStrategy.rawValue)"
            ),
            ProcessingStageRecord(
                name: "低分辨率候选评估",
                durationMilliseconds: Self.milliseconds(candidateDuration),
                executed: true,
                detail: "\(candidateResult.evaluations.filter { $0.status != .skipped }.count) 个候选 · 选择 \(candidateResult.plan.intent.rawValue)"
            ),
            ProcessingStageRecord(
                name: "完整分辨率渲染",
                durationMilliseconds: Self.milliseconds(renderDuration),
                executed: true,
                detail: "Core Image · extended linear sRGB → sRGB"
            ),
            ProcessingStageRecord(
                name: "质量检查与回退",
                durationMilliseconds: Self.milliseconds(qualityDuration),
                executed: true,
                detail: finalEdit.qualityCheck.summaryText
            ),
            ProcessingStageRecord(
                name: "总耗时",
                durationMilliseconds: Self.milliseconds(totalDuration),
                executed: true,
                detail: Self.memorySummary(start: startingMemory, end: finishingMemory)
            )
        ]
        if let referenceStage = referenceValidation?.stage {
            stageRecords.append(referenceStage)
        }
        let diagnosticsResult: ImageDiagnosticsResult?
        do {
            let finalRegionImpacts = try qualityService.measureRegionImpacts(
                originalData: photo.originalImageData,
                editedData: finalEdit.data,
                analysis: analysis
            )
            diagnosticsResult = try diagnosticsService.inspect(
                originalData: photo.originalImageData,
                editedData: finalEdit.data,
                executedModules: renderer.executedModuleNames(
                    for: finalEdit.recipe,
                    analysis: finalEdit.analysis
                ),
                regionalExecutionDetails: renderer.regionalExecutionDetails(
                    for: finalEdit.recipe,
                    analysis: finalEdit.analysis
                ),
                parameterExecutionResults: parameterExecutionResults(
                    decision: finalDecision,
                    source: analysis,
                    edited: finalEdit.qualityCheck.measuredAnalysis,
                    regionImpacts: finalRegionImpacts
                ),
                candidateEvaluations: candidateResult.evaluations,
                finalRegionImpacts: finalRegionImpacts,
                referenceValidationDetails: referenceValidation?.details ?? [],
                stages: stageRecords,
                fallbackReason: finalEdit.fallbackReason
            )
        } catch {
            diagnosticsResult = nil
            AppLogger.imageEngine.error("成片差异诊断失败：\(error.localizedDescription)")
        }

        let stagePreviews: [ProcessingStagePreview]
        do {
            let renderedStages = try renderer.renderStagePreviews(
                from: photo.originalImageData,
                recipe: finalEdit.recipe,
                analysis: finalEdit.analysis
            )
            if photo.isDiagnosticImport {
                let maskDiagnostics = try renderer.renderMaskDiagnosticPreviews(
                    from: photo.originalImageData,
                    analysis: analysis,
                    recipe: finalEdit.recipe
                )
                var comparisonPreviews = [
                    ProcessingStagePreview(name: "A 原始照片", imageData: photo.originalImageData),
                    ProcessingStagePreview(name: "B 当前正式算法成片", imageData: finalEdit.data)
                ]
                if let referencePreview = referenceValidation?.preview {
                    comparisonPreviews.append(referencePreview)
                }
                stagePreviews = comparisonPreviews
                    + candidateResult.previews
                    + renderedStages
                    + maskDiagnostics
            } else {
                stagePreviews = renderedStages
            }
        } catch {
            // Candidate previews were already rendered successfully and remain useful
            // even if a later full-stage or mask diagnostic preview fails.
            if photo.isDiagnosticImport {
                var comparisonPreviews = [
                    ProcessingStagePreview(name: "A 原始照片", imageData: photo.originalImageData),
                    ProcessingStagePreview(name: "B 当前正式算法成片", imageData: finalEdit.data)
                ]
                if let referencePreview = referenceValidation?.preview {
                    comparisonPreviews.append(referencePreview)
                }
                stagePreviews = comparisonPreviews + candidateResult.previews
            } else {
                stagePreviews = []
            }
            AppLogger.imageEngine.error("处理阶段预览生成失败：\(error.localizedDescription)")
        }

        // 8. 返回可预览的原片与成片；用户确认后由 PhotoLibraryManager 保存。
        return CapturedPhoto(
            originalImageData: photo.originalImageData,
            editedImageData: finalEdit.data,
            capturedAt: photo.capturedAt,
            isDiagnosticImport: photo.isDiagnosticImport,
            skinMask: photo.skinMask,
            analysis: analysis,
            problemReport: problemReport,
            decision: finalDecision,
            qualityCheck: finalEdit.qualityCheck,
            processingDiagnostics: diagnosticsResult?.diagnostics,
            differenceImageData: diagnosticsResult?.differenceImageData,
            processingStagePreviews: stagePreviews
        )
    }

    private func evaluateReferenceCandidate(
        originalData: Data,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        isDiagnosticImport: Bool
    ) -> ReferenceValidationCandidateResult? {
        guard configuration.referenceValidation.isEnabled(
            isDiagnosticImport: isDiagnosticImport
        ) else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        guard let referenceMatcher else {
            return ReferenceValidationCandidateResult(
                preview: nil,
                details: [
                    "状态=indexUnavailable",
                    "原因=App 包内没有可解码的许可过滤参考特征索引；B 仍由原逐图求解器生成",
                    "未执行 Core Image 候选 C"
                ],
                stage: ProcessingStageRecord(
                    name: "摄影参考验证候选 C",
                    durationMilliseconds: Self.milliseconds(ProcessInfo.processInfo.systemUptime - start),
                    executed: false,
                    detail: "参考索引不可用；安全降级到 B，不伪装成参考驱动结果"
                )
            )
        }

        let match = referenceMatcher.match(
            analysis: analysis,
            maximumResults: configuration.referenceValidation.maximumMatches
        )
        let profile = PhotographyReferenceTargetGenerator().makeProfile(
            analysis: analysis,
            problems: problems,
            matchResult: match
        )
        let matchTrace = match.matches.map { item in
            "\(item.record.id){相似=\(String(format: "%.1f", item.similarity * 100))%；度量=\(String(format: "%.1f", item.metricSimilarity * 100))%；语义=\(String(format: "%.1f", item.semanticSimilarity * 100))%；许可=\(item.record.license.name)；依据=[\(item.reasons.joined(separator: "；"))]；不可迁移=[\(item.nonTransferableFeatures.joined(separator: ","))]}"
        }.joined(separator: " | ")
        guard profile.referenceApplied else {
            let reason = match.fallbackReason ?? "参考适用性门控未通过"
            AppLogger.imageEngine.info(
                "摄影参考验证降级：status=\(match.status.rawValue, privacy: .public) confidence=\(match.confidence) reason=\(reason, privacy: .public)"
            )
            return ReferenceValidationCandidateResult(
                preview: nil,
                details: [
                    "状态=\(match.status.rawValue)",
                    "置信度=\(String(format: "%.1f", match.confidence * 100))%",
                    "匹配=\(matchTrace.isEmpty ? "无" : matchTrace)",
                    "降级=\(reason)",
                    "候选 C 未渲染；B 保持原逐图测量结果"
                ],
                stage: ProcessingStageRecord(
                    name: "摄影参考验证候选 C",
                    durationMilliseconds: Self.milliseconds(ProcessInfo.processInfo.systemUptime - start),
                    executed: false,
                    detail: "适用性不足，安全降级；\(reason)"
                )
            )
        }

        do {
            let referenceDecision = photographyDirector.direct(
                analysis: analysis,
                problems: problems,
                targetProfile: profile
            )
            let candidateData = try renderer.renderAutomaticEdit(
                from: originalData,
                recipe: referenceDecision.recipe,
                analysis: analysis
            )
            let regionalExecution = renderer.regionalExecutionDetails(
                for: referenceDecision.recipe,
                analysis: analysis
            )
            let quality = try qualityService.check(
                originalData: originalData,
                editedData: candidateData,
                sourceAnalysis: analysis,
                expectedRegions: referenceDecision.treatmentPlan.regionalTreatments.map(\.region),
                regionalExecutionDetails: regionalExecution
            )
            let parameters = referenceDecision.parameterEvidence.map { evidence in
                "\(evidence.key.rawValue)=\(String(format: "%.4f", evidence.actualValue)){rules=\(evidence.knowledgeRuleIDs.map(\.rawValue).joined(separator: ","));status=\(evidence.decisionStatus.rawValue)}"
            }.joined(separator: ",")
            let localPlan = referenceDecision.treatmentPlan.regionalTreatments.map { item in
                "\(item.region.rawValue){confidence=\(String(format: "%.2f", item.confidence));\(item.parameters)}"
            }.joined(separator: " | ")
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            let details = [
                "状态=matchedForValidation；仅诊断导入启用，不替换正式 B",
                "置信度=\(String(format: "%.1f", match.confidence * 100))%；参考影响=\(String(format: "%.1f", profile.referenceInfluence * 100))%",
                "匹配依据=\(matchTrace)",
                "目标=\(profile.resolvedTarget.summaryText)；依据=\(profile.rationale.joined(separator: " "))",
                "保护=\(profile.preservedProperties.joined(separator: ","))",
                "参数=\(parameters)",
                "局部计划=\(localPlan.isEmpty ? "无可靠局部区域" : localPlan)",
                "区域执行=\(regionalExecution.joined(separator: " | "))",
                "候选 C 质检=\(quality.status.rawValue)；问题=[\(quality.issues.map(\.rawValue).joined(separator: ","))]；RGB_MAE=\(String(format: "%.4f", quality.processingImpact.normalizedMeanAbsoluteRGBDifference))；肤色偏移=\(String(format: "%.4f", quality.colorIntegrity.skinColorDifference))；中性色染色=\(String(format: "%.4f", quality.colorIntegrity.neutralChromaIncrease))",
                "耗时=\(duration)ms；iPhone 视觉审美=尚未人工验收"
            ]
            AppLogger.imageEngine.info(
                "摄影参考验证候选 C 完成：\(details.joined(separator: "；"), privacy: .public)"
            )
            return ReferenceValidationCandidateResult(
                preview: ProcessingStagePreview(
                    name: "C 摄影参考校准候选（\(quality.status.rawValue)）",
                    imageData: candidateData
                ),
                details: details,
                stage: ProcessingStageRecord(
                    name: "摄影参考验证候选 C",
                    durationMilliseconds: duration,
                    executed: true,
                    detail: "Core Image 已渲染 · \(match.matches.count) 条参考 · 质检 \(quality.status.rawValue) · 未替换 B"
                )
            )
        } catch {
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            AppLogger.imageEngine.error(
                "摄影参考验证候选 C 失败，正式 B 不受影响：\(error.localizedDescription, privacy: .public)"
            )
            return ReferenceValidationCandidateResult(
                preview: nil,
                details: [
                    "状态=renderFailed",
                    "匹配=\(matchTrace)",
                    "错误=\(error.localizedDescription)",
                    "B 保持当前正式算法结果；未把失败伪装成 C"
                ],
                stage: ProcessingStageRecord(
                    name: "摄影参考验证候选 C",
                    durationMilliseconds: duration,
                    executed: false,
                    detail: "渲染或质检失败：\(error.localizedDescription)"
                )
            )
        }
    }

    private func parameterExecutionResults(
        decision: PhotographyDecision,
        source: PhotoAnalysis,
        edited: PhotoAnalysis,
        regionImpacts: [PhotographyRegionImpact]
    ) -> [String] {
        decision.parameterEvidence.map { evidence in
            let result: String
            switch evidence.key {
            case .exposure, .brightness:
                result = String(format: "平均亮度 %.3f→%.3f", source.averageLuminance, edited.averageLuminance)
            case .highlights, .whitePoint:
                result = String(format: "高光 %.3f→%.3f，纯白 %.3f→%.3f", source.highlightRatio, edited.highlightRatio, source.whiteRatio, edited.whiteRatio)
            case .shadows, .blackPoint:
                result = String(format: "阴影 %.3f→%.3f，纯黑 %.3f→%.3f", source.shadowRatio, edited.shadowRatio, source.blackRatio, edited.blackRatio)
            case .contrast, .toneCurve, .localContrast, .midtoneContrast, .localTexture:
                result = String(format: "亮度跨度 %.3f→%.3f，细节 %.3f→%.3f", source.contrastRange, edited.contrastRange, source.detailScore, edited.detailScore)
            case .temperature, .tint, .shadowColor, .midtoneColor, .highlightColor:
                result = String(format: "RGB %.3f/%.3f/%.3f→%.3f/%.3f/%.3f", source.redAverage, source.greenAverage, source.blueAverage, edited.redAverage, edited.greenAverage, edited.blueAverage)
            case .hue, .saturation, .vibrance, .orangeHSL, .greenHSL, .blueHSL, .localColor:
                result = String(format: "平均饱和度 %.3f→%.3f", source.averageSaturation, edited.averageSaturation)
            case .noiseReduction, .sharpening:
                result = String(format: "噪声代理 %.3f→%.3f，细节 %.3f→%.3f", source.noiseEstimate, edited.noiseEstimate, source.detailScore, edited.detailScore)
            case .luminanceMask, .localExposure, .localHighlights, .localShadows:
                result = regionImpacts.isEmpty
                    ? "无可靠区域影响可测；全局高光/阴影结果见直方图"
                    : regionImpacts.map {
                        String(format: "%@亮度%+.3f/对比%+.3f", $0.region.rawValue, $0.luminanceDelta, $0.contrastDelta)
                    }.joined(separator: ",")
            }
            return String(
                format: "%@ rules=%@ value=%.3f range=%.3f...%.3f region=%@ status=%@ · %@",
                evidence.key.rawValue,
                evidence.knowledgeRuleIDs.map(\.rawValue).joined(separator: ","),
                evidence.actualValue,
                evidence.minimumValue,
                evidence.maximumValue,
                evidence.affectedRegion.rawValue,
                evidence.decisionStatus.rawValue,
                result
            )
        }
    }

    private func evaluateCandidates(
        originalData: Data,
        decision: PhotographyDecision,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        retainPreviews: Bool
    ) throws -> (
        plan: PhotographyEditPlan,
        evaluations: [PhotographyCandidateEvaluation],
        previews: [ProcessingStagePreview],
        selectionReason: String
    ) {
        let plans = candidatePlanner.makePlans(
            decision: decision,
            analysis: analysis,
            problems: problems
        )
        let originalPreview = try renderer.renderEvaluationOriginal(from: originalData)
        let evaluationStart = ProcessInfo.processInfo.systemUptime
        let timeBudget: TimeInterval = 3.2
        var evaluations: [PhotographyCandidateEvaluation] = []
        var candidatePreviews: [ProcessingStagePreview] = []

        for plan in plans {
            let elapsed = ProcessInfo.processInfo.systemUptime - evaluationStart
            if elapsed >= timeBudget, evaluations.filter({ $0.status != .skipped }).count >= 2 {
                evaluations.append(PhotographyCandidateEvaluation(
                    planID: plan.id,
                    title: plan.intent.rawValue,
                    status: .skipped,
                    score: -100,
                    problemImprovement: 0,
                    preservationScore: 0,
                    issues: ["超过低分辨率候选时间预算"],
                    reason: "设备性能预算触发，未执行该候选；不会伪装成已评估。",
                    durationMilliseconds: 0,
                    selected: false
                ))
                continue
            }

            let start = ProcessInfo.processInfo.systemUptime
            do {
                let preview = try renderer.renderEvaluationPreview(
                    from: originalData,
                    recipe: plan.recipe,
                    analysis: analysis
                )
                if retainPreviews {
                    candidatePreviews.append(ProcessingStagePreview(
                        name: "D V9逐图候选-\(plan.intent.rawValue)",
                        imageData: preview
                    ))
                }
                let candidateDecision = decision.replacingRecipe(
                    with: plan.recipe,
                    analysis: analysis
                )
                let executionDetails = renderer.regionalExecutionDetails(
                    for: plan.recipe,
                    analysis: analysis
                )
                let quality = try qualityService.check(
                    originalData: originalPreview,
                    editedData: preview,
                    sourceAnalysis: analysis,
                    expectedRegions: candidateDecision.treatmentPlan.regionalTreatments.map(\.region),
                    regionalExecutionDetails: executionDetails
                )
                let regionImpacts = try qualityService.measureRegionImpacts(
                    originalData: originalPreview,
                    editedData: preview,
                    analysis: analysis
                )
                let improvement = PhotographyProblemImprovementScorer().score(
                    problems: problems,
                    source: analysis,
                    edited: quality.measuredAnalysis,
                    regionImpacts: regionImpacts
                )
                let targetAttainment = AdaptiveTargetAttainmentScorer().score(
                    target: decision.adaptiveTarget,
                    source: analysis,
                    edited: quality.measuredAnalysis
                )
                let aestheticProgress = PhotographyAestheticProgressScorer().score(
                    source: analysis,
                    regionImpacts: regionImpacts
                )
                let preservation = preservationScore(
                    quality: quality,
                    hasProblems: !problems.isEmpty
                )
                let status: CandidateEvaluationStatus
                switch quality.status {
                case .passed: status = .passed
                case .warning: status = .warning
                case .failed: status = .rejected
                }
                let technicalPenalty: Float = status == .rejected
                    ? 46
                    : (status == .warning ? 10 : 0)
                let insufficientImprovementPenalty: Float = !problems.isEmpty
                    && improvement < 0.08
                    && !aestheticProgress.hasMeaningfulProgress
                    ? 14
                    : 0
                let colorIntegrityPenalty = quality.colorIntegrity.riskPenalty * 34
                let score = (improvement * 32)
                    + (targetAttainment * 26)
                    + (preservation * 16)
                    + (aestheticProgress.subjectPriority * 13)
                    + (aestheticProgress.regionalHarmony * 13)
                    + 10
                    - technicalPenalty
                    - insufficientImprovementPenalty
                    - colorIntegrityPenalty
                    - Float(quality.issues.count) * 3
                let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
                let evaluation = PhotographyCandidateEvaluation(
                    planID: plan.id,
                    title: plan.intent.rawValue,
                    status: status,
                    score: score,
                    problemImprovement: improvement,
                    targetAttainmentScore: targetAttainment,
                    preservationScore: preservation,
                    subjectPriorityScore: aestheticProgress.subjectPriority,
                    harmonyScore: aestheticProgress.regionalHarmony,
                    issues: quality.issues.map(\.rawValue),
                    regionImpacts: regionImpacts,
                    reason: "\(plan.rationale) 技术质检=\(quality.status.rawValue)；逐图目标达成=\(Int((targetAttainment * 100).rounded()))%，主体改善=\(Int((aestheticProgress.subjectPriority * 100).rounded()))%，区域协调=\(Int((aestheticProgress.regionalHarmony * 100).rounded()))%，肤色/中性色风险=\(Int((quality.colorIntegrity.riskPenalty * 100).rounded()))%，弱改善惩罚=\(Int(insufficientImprovementPenalty))；不以像素差异大小单独判优。",
                    durationMilliseconds: duration,
                    selected: false
                )
                evaluations.append(evaluation)
                AppLogger.imageEngine.info(
                    "候选 \(plan.intent.rawValue, privacy: .public)：status=\(status.rawValue, privacy: .public) score=\(score) improvement=\(improvement) target=\(targetAttainment) subject=\(aestheticProgress.subjectPriority) harmony=\(aestheticProgress.regionalHarmony) preservation=\(preservation) colorRisk=\(quality.colorIntegrity.riskPenalty) weakPenalty=\(insufficientImprovementPenalty) duration=\(duration)ms recipe=\(plan.recipe.traceSummary, privacy: .public)"
                )
            } catch {
                let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
                evaluations.append(PhotographyCandidateEvaluation(
                    planID: plan.id,
                    title: plan.intent.rawValue,
                    status: .rejected,
                    score: -100,
                    problemImprovement: 0,
                    preservationScore: 0,
                    issues: [error.localizedDescription],
                    reason: "候选预览渲染或质量分析失败，已明确拒绝。",
                    durationMilliseconds: duration,
                    selected: false
                ))
                AppLogger.imageEngine.error(
                    "候选 \(plan.intent.rawValue, privacy: .public) 评估失败：\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard
            let selected = PhotographyCandidateSelector().select(from: evaluations),
            let selectedPlan = plans.first(where: { $0.id == selected.planID })
        else {
            throw PhotoProcessingError.candidateEvaluationFailed("没有候选完成可用的预览评估。")
        }
        let selectedEvaluations = evaluations.map {
            $0.planID == selected.planID ? $0.markingSelected() : $0
        }
        let selectionReason = String(
            format: "%@；最终按实测选择：状态=%@，得分=%.1f，问题改善=%.1f%%，逐图目标达成=%.1f%%，主体改善=%.1f%%，区域协调=%.1f%%，保真=%.1f%%。",
            selected.reason,
            selected.status.rawValue,
            selected.score,
            selected.problemImprovement * 100,
            selected.targetAttainmentScore * 100,
            selected.subjectPriorityScore * 100,
            selected.harmonyScore * 100,
            selected.preservationScore * 100
        )
        return (selectedPlan, selectedEvaluations, candidatePreviews, selectionReason)
    }

    private func preservationScore(
        quality: QualityCheckResult,
        hasProblems: Bool
    ) -> Float {
        let impact = quality.processingImpact.normalizedMeanAbsoluteRGBDifference
        let upperComfort: Float = hasProblems ? 0.105 : 0.055
        let overProcessingPenalty = max(0, impact - upperComfort) * 7
        let warningPenalty = Float(quality.issues.count) * 0.07
        return min(1, max(0, 1 - overProcessingPenalty - warningPenalty))
    }

    private func chooseFinalEdit(
        originalData: Data,
        initialEditedData: Data,
        initialQualityCheck: QualityCheckResult,
        initialRecipe: AutomaticEditingRecipe,
        target: AdaptivePhotographyTarget,
        analysis: PhotoAnalysis,
        expectedRegions: [TreatmentRegion]
    ) throws -> (
        data: Data,
        qualityCheck: QualityCheckResult,
        recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?,
        fallbackReason: String?
    ) {
        guard initialQualityCheck.status == .failed else {
            return (initialEditedData, initialQualityCheck, initialRecipe, analysis, nil)
        }

        AppLogger.imageEngine.warning(
            "初版成片质检失败，原因：\(initialQualityCheck.issues.map(\.rawValue).joined(separator: ","))；开始一次有边界的针对性重算"
        )

        if initialQualityCheck.issues.contains(.canvasMismatch) {
            throw PhotoProcessingError.qualityValidationFailed("最终画布与原图不一致；拒绝用固定回退配方掩盖输出链错误。")
        }

        do {
            let correctiveRecipe = correctionRecipe(
                from: initialRecipe,
                issues: initialQualityCheck.issues,
                target: target,
                measured: initialQualityCheck.measuredAnalysis
            )
            let correctiveData = try renderer.renderAutomaticEdit(
                from: originalData,
                recipe: correctiveRecipe,
                analysis: analysis
            )
            let correctiveRegionalExecutionDetails = renderer.regionalExecutionDetails(
                for: correctiveRecipe,
                analysis: analysis
            )
            let correctiveQualityCheck = try qualityService
                .check(
                    originalData: originalData,
                    editedData: correctiveData,
                    sourceAnalysis: analysis,
                    expectedRegions: expectedRegions,
                    regionalExecutionDetails: correctiveRegionalExecutionDetails
                )
                .applyingFallback()

            if correctiveQualityCheck.status.isBetter(than: initialQualityCheck.status) {
                AppLogger.imageEngine.warning("针对性重算结果更可靠，采用修正版成片；不再继续循环调整")
                return (
                    correctiveData,
                    correctiveQualityCheck,
                    correctiveRecipe,
                    analysis,
                    "V7 一次性修正：" + initialQualityCheck.issues.map(\.rawValue).joined(separator: ",")
                )
            }

            AppLogger.imageEngine.error("初版与一次针对性重算均未通过质量验证，拒绝把异常图片标记为 AI 成片")
            throw PhotoProcessingError.qualityValidationFailed(
                initialQualityCheck.issues.map(\.rawValue).joined(separator: ",")
            )
        } catch {
            if let processingError = error as? PhotoProcessingError { throw processingError }
            AppLogger.imageEngine.error("针对性重算失败，拒绝输出异常成片：\(error.localizedDescription)")
            throw PhotoProcessingError.safeFallbackFailed(error.localizedDescription)
        }
    }

    /// V7 quality feedback is deliberately bounded: the original analysis is
    /// reused and at most one issue-specific correction render is attempted.
    private func correctionRecipe(
        from original: AutomaticEditingRecipe,
        issues: [QualityIssue],
        target: AdaptivePhotographyTarget,
        measured: PhotoAnalysis
    ) -> AutomaticEditingRecipe {
        var recipe = original
        let set = Set(issues)

        if !set.isDisjoint(with: [.possibleRenderFallback, .insufficientProcessingImpact]) {
            let luminanceResidual = target.luminance - measured.averageLuminance
            let contrastResidual = target.contrast - measured.contrastRange
            let saturationResidual = target.saturation - measured.averageSaturation
            recipe.exposureEV += (luminanceResidual * 0.32).clamped(to: -0.08...0.08)
            recipe.brightness += (luminanceResidual * 0.06).clamped(to: -0.018...0.018)
            recipe.contrast += (contrastResidual * 0.1).clamped(to: -0.025...0.025)
            recipe.toneCurveAmount += (abs(contrastResidual) * 0.28).clamped(to: 0...0.12)
            recipe.localContrastAmount += (max(0, contrastResidual) * 0.12).clamped(to: 0...0.045)
            if saturationResidual > 0 {
                recipe.vibrance += (saturationResidual * 0.24).clamped(to: 0...0.045)
            } else {
                recipe.saturation += (saturationResidual * 0.1).clamped(to: -0.025...0)
            }
        }

        if !set.isDisjoint(with: [.tooDark, .crushedShadows, .abnormalBlackCoverage]) {
            let residual = max(0, target.luminanceMinimum - measured.averageLuminance)
            let shadowResidual = max(0, measured.shadowRatio - target.shadowRatio)
            recipe.exposureEV += (residual * 0.38).clamped(to: 0...0.1)
            recipe.shadowAmount += (shadowResidual * 0.5).clamped(to: 0...0.16)
            recipe.shadowRollOff += (shadowResidual * 0.35).clamped(to: 0...0.12)
            recipe.shadowZoneExposureEV += (shadowResidual * 0.22).clamped(to: 0...0.07)
            recipe.blackPoint = min(recipe.blackPoint, 0.004)
        }

        if !set.isDisjoint(with: [.tooBright, .clippedHighlights, .expandedPureWhite, .excessiveHighlightSpread]) {
            let residual = max(0, measured.averageLuminance - target.luminanceMaximum)
            let highlightResidual = max(0, measured.highlightRatio - target.highlightRatio)
            recipe.exposureEV -= (residual * 0.35).clamped(to: 0...0.1)
            recipe.highlightAmount -= (highlightResidual * 0.8).clamped(to: 0...0.2)
            recipe.highlightRollOff += (highlightResidual * 0.6).clamped(to: 0...0.18)
            recipe.highlightZoneExposureEV -= (highlightResidual * 0.28).clamped(to: 0...0.08)
            recipe.whitePoint -= (highlightResidual * 0.08).clamped(to: 0...0.018)
            recipe.bloomIntensity = 0
            recipe.halationIntensity = 0
        }

        if set.contains(.tooFlat) {
            let residual = max(0, target.contrast - measured.contrastRange)
            recipe.toneCurveAmount += (residual * 0.5).clamped(to: 0...0.18)
            recipe.contrast += (residual * 0.12).clamped(to: 0...0.035)
            recipe.localContrastAmount += (residual * 0.16).clamped(to: 0...0.055)
        }

        if set.contains(.tooHarsh) || set.contains(.overprocessedDetail) {
            recipe.contrast = min(recipe.contrast, 1.015)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.055)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.065)
            recipe.toneCurveAmount = min(recipe.toneCurveAmount, 0.34)
        }

        if !set.isDisjoint(with: [
            .oversaturated,
            .abnormalColorCast,
            .neutralColorDrift,
            .globalWarmCast,
            .globalGreenCast
        ]) {
            recipe.saturation = min(recipe.saturation, 0.995)
            recipe.vibrance = min(recipe.vibrance, 0.055)
            recipe.temperatureShift *= 0.2
            recipe.tintShift *= 0.2
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.04)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.015)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.015)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.02)
            recipe.colorContrast = min(recipe.colorContrast, 0.02)
            recipe.hsl.cyanHue = 0
            recipe.hsl.blueHue = 0
            recipe.hsl.greenHue = 0
            recipe.hsl.cyanSaturation = min(recipe.hsl.cyanSaturation, 0)
            recipe.hsl.blueSaturation = min(recipe.hsl.blueSaturation, 0)
            recipe.hsl.greenSaturation = min(recipe.hsl.greenSaturation, 0)
        }

        if !set.isDisjoint(with: [.portraitRegionOverAltered, .portraitTextureAltered, .skinToneDrift]) {
            recipe.faceExposureEV = 0
            recipe.subjectExposureEV = min(recipe.subjectExposureEV, 0.08)
            recipe.temperatureShift *= 0.15
            recipe.tintShift *= 0.15
            recipe.hsl.orangeHue = 0
            recipe.hsl.orangeLuminance = 0
            recipe.hsl.orangeSaturation = 0
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.025)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.01)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.01)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.015)
            recipe.noiseReductionAmount = min(recipe.noiseReductionAmount, 0.012)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.055)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.045)
            recipe.skinTextureProtection = max(recipe.skinTextureProtection, 0.76)
        }

        if set.contains(.neutralLuminanceLoss) {
            recipe.exposureEV = max(recipe.exposureEV, 0)
            recipe.highlightAmount = max(recipe.highlightAmount, 0.78)
            recipe.whitePoint = max(recipe.whitePoint, 0.985)
            recipe.highlightZoneExposureEV = max(recipe.highlightZoneExposureEV, -0.045)
        }

        if set.contains(.localMaskBoundaryArtifact) {
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.04)
            recipe.skyExposureEV *= 0.5
            recipe.skyHighlightAmount = max(recipe.skyHighlightAmount, 0.78)
            recipe.hsl.greenSaturation *= 0.55
            recipe.hsl.yellowSaturation *= 0.55
            recipe.hsl.cyanSaturation *= 0.55
            recipe.hsl.blueSaturation *= 0.55
        }

        if set.contains(.amplifiedNoise) {
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.045)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.055)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.045)
            recipe.grainAmount = 0
            recipe.shadowZoneExposureEV = min(recipe.shadowZoneExposureEV, 0.08)
        }

        return recipe.clamped()
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }

    private static func memorySummary(start: UInt64?, end: UInt64?) -> String {
        guard let start, let end else { return "分析到最终成片 · 内存指标不可用" }
        let megabyte = 1_048_576.0
        let delta = Double(Int64(end) - Int64(start)) / megabyte
        return String(
            format: "分析到最终成片 · 物理占用 %.1f MB · 变化 %+.1f MB",
            Double(end) / megabyte,
            delta
        )
    }
}

private struct ReferenceValidationCandidateResult {
    let preview: ProcessingStagePreview?
    let details: [String]
    let stage: ProcessingStageRecord
}

enum PhotoProcessingError: LocalizedError {
    case qualityValidationFailed(String)
    case safeFallbackFailed(String)
    case candidateEvaluationFailed(String)

    var errorDescription: String? {
        switch self {
        case .qualityValidationFailed(let issues):
            return "AI 成片未通过质量检查（\(issues)），已保留原图且未输出异常成片。"
        case .safeFallbackFailed(let reason):
            return "安全处理失败（\(reason)），已保留原图。"
        case .candidateEvaluationFailed(let reason):
            return "候选摄影方案评估失败（\(reason)），已保留原图。"
        }
    }
}

