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
        let measuredAestheticValidation = evaluateMeasuredAestheticCandidate(
            originalData: photo.originalImageData,
            analysis: analysis,
            problems: problemReport,
            isDiagnosticImport: photo.isDiagnosticImport
        )
        let aestheticTargetExperiments = evaluateAestheticTargetExperiments(
            originalData: photo.originalImageData,
            analysis: analysis,
            problems: problemReport,
            isDiagnosticImport: photo.isDiagnosticImport
        )
        let manualValidation = evaluateManualCandidate(
            originalData: photo.originalImageData,
            analysis: analysis,
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
        if let measuredStage = measuredAestheticValidation?.stage {
            stageRecords.append(measuredStage)
        }
        stageRecords.append(contentsOf: aestheticTargetExperiments.map { $0.result.stage })
        if let manualStage = manualValidation?.stage {
            stageRecords.append(manualStage)
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
                referenceValidationDetails: (referenceValidation?.details ?? [])
                    + (measuredAestheticValidation?.details ?? [])
                    + (manualValidation?.details ?? []),
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
                if let measuredPreview = measuredAestheticValidation?.preview {
                    comparisonPreviews.append(measuredPreview)
                }
                comparisonPreviews.append(contentsOf: aestheticTargetExperiments.compactMap { $0.result.preview })
                if let manualPreview = manualValidation?.preview {
                    comparisonPreviews.append(manualPreview)
                }
                let manualProbePreviews = (try? renderer.renderManualParameterProbePreviews(
                    from: photo.originalImageData,
                    analysis: analysis
                )) ?? []
                stagePreviews = comparisonPreviews
                    + candidateResult.previews
                    + renderedStages
                    + maskDiagnostics
                    + manualProbePreviews
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
                if let measuredPreview = measuredAestheticValidation?.preview {
                    comparisonPreviews.append(measuredPreview)
                }
                if let manualPreview = manualValidation?.preview {
                    comparisonPreviews.append(manualPreview)
                }
                stagePreviews = comparisonPreviews + candidateResult.previews
            } else {
                stagePreviews = []
            }
            AppLogger.imageEngine.error("处理阶段预览生成失败：\(error.localizedDescription)")
        }

        let diagnosticCandidates = photo.isDiagnosticImport
            ? makeDiagnosticCandidateEvidence(
                finalDecision: finalDecision,
                finalRecipe: finalEdit.recipe,
                finalAnalysis: finalEdit.analysis,
                finalQualityCheck: finalEdit.qualityCheck,
                finalFallbackReason: finalEdit.fallbackReason,
                referenceValidation: referenceValidation,
                measuredAestheticValidation: measuredAestheticValidation,
                aestheticTargetExperiments: aestheticTargetExperiments,
                manualValidation: manualValidation
            )
            : []

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
            processingStagePreviews: stagePreviews,
            diagnosticCandidates: diagnosticCandidates
        )
    }

    private func makeDiagnosticCandidateEvidence(
        finalDecision: PhotographyDecision,
        finalRecipe: AutomaticEditingRecipe,
        finalAnalysis: PhotoAnalysis?,
        finalQualityCheck: QualityCheckResult,
        finalFallbackReason: String?,
        referenceValidation: ReferenceValidationCandidateResult?,
        measuredAestheticValidation: IsolatedDiagnosticCandidateResult?,
        aestheticTargetExperiments: [AestheticExperimentCandidateResult],
        manualValidation: IsolatedDiagnosticCandidateResult?
    ) -> [DiagnosticCandidateEvidence] {
        let parameterPlan = finalDecision.parameterEvidence.map { item in
            let rules = item.knowledgeRuleIDs.map(\.rawValue).joined(separator: ",")
            return "\(item.key.rawValue){input=\(item.inputEvidence);target=\(item.target);value=\(item.actualValue);region=\(item.affectedRegion.rawValue);status=\(item.decisionStatus.rawValue);rules=\(rules)}"
        }
        let bRegionalExecution = renderer.regionalExecutionDetails(
            for: finalRecipe,
            analysis: finalAnalysis
        )
        var bStates: [DiagnosticCandidateState] = [.planned, .executed]
        var bFallback: [String] = []
        if finalQualityCheck.fallbackApplied || finalFallbackReason != nil {
            bStates.append(.fallback)
            bFallback.append(finalFallbackReason ?? "质量检查应用了安全修正")
        }
        let a = DiagnosticCandidateEvidence(
            identifier: "A",
            displayName: "原图",
            states: [.executed],
            imageStageName: "A 原始照片",
            planned: [],
            executed: ["未经像素后期；作为同源输入与比较基准"],
            rejected: [],
            fallback: [],
            unavailable: [],
            qualityStatus: "source",
            targetQualityStatus: "source_not_applicable",
            humanAestheticStatus: "source_reference",
            assessmentEvidence: ["A 是同源输入，不接受技术成片或审美优胜判定。"],
            durationMilliseconds: nil
        )
        let b = DiagnosticCandidateEvidence(
            identifier: "B",
            displayName: "正式算法实际成片",
            states: bStates,
            imageStageName: "B 当前正式算法成片",
            planned: [
                "target=\(finalDecision.adaptiveTarget.summaryText)",
                "recipe=\(finalRecipe.traceSummary)"
            ] + parameterPlan,
            executed: [
                "modules=\(renderer.executedModuleNames(for: finalRecipe, analysis: finalAnalysis).joined(separator: " -> "))"
            ] + bRegionalExecution,
            rejected: [],
            fallback: bFallback,
            unavailable: [],
            qualityStatus: finalQualityCheck.status.rawValue,
            targetQualityStatus: "formal_algorithm_not_reassessed_in_experiment",
            humanAestheticStatus: "awaiting_blind_review",
            assessmentEvidence: ["B 保持正式算法；本轮未用 D/E 的目标分数替代人工偏好。"],
            durationMilliseconds: nil
        )
        var candidates = [
            a,
            b,
            evidence(
                identifier: "C",
                displayName: "摄影参考校准候选",
                preview: referenceValidation?.preview,
                details: referenceValidation?.details,
                stage: referenceValidation?.stage,
                nilReason: "摄影参考候选未启用或许可过滤索引不可用"
            ),
            evidence(
                identifier: "D",
                displayName: "逐图自动后期诊断候选",
                preview: measuredAestheticValidation?.preview,
                details: measuredAestheticValidation?.details,
                stage: measuredAestheticValidation?.stage,
                nilReason: "D 诊断路径未启用"
            )
        ]
        candidates.append(contentsOf: aestheticTargetExperiments.map { experiment in
            evidence(
                identifier: experiment.identifier,
                displayName: experiment.displayName,
                preview: experiment.result.preview,
                details: experiment.result.details,
                stage: experiment.result.stage,
                nilReason: "\(experiment.identifier) 目标实验未启用"
            )
        })
        candidates.append(
            evidence(
                identifier: "M",
                displayName: "人工参数渲染验证",
                preview: manualValidation?.preview,
                details: manualValidation?.details,
                stage: manualValidation?.stage,
                nilReason: "M 诊断路径未启用"
            )
        )
        return candidates
    }

    private func evidence(
        identifier: String,
        displayName: String,
        preview: ProcessingStagePreview?,
        details: [String]?,
        stage: ProcessingStageRecord?,
        nilReason: String
    ) -> DiagnosticCandidateEvidence {
        let lines = details ?? []
        let plannedKeywords = ["视觉理解", "摄影问题", "审美目标", "动态参数", "声明参数", "目标=", "参数=", "局部计划", "参数生命周期"]
        let executedKeywords = ["renderStatus=completed", "区域执行", "执行模块", "技术质检", "耗时=", "同定义复测", "有限反馈", "最终实际参数", "参数生命周期"]
        let rejectedKeywords = [
            "technicalQualityStatus=failed",
            "qualityEvaluationFailed",
            "renderFailed",
            "未标记通过",
            "质检执行失败"
        ]
        let fallbackKeywords = ["降级", "fallback", "安全回退"]
        var planned = lines.filter { line in plannedKeywords.contains { line.contains($0) } }
        var executed = lines.filter { line in executedKeywords.contains { line.contains($0) } }
        var rejected = lines.filter { line in rejectedKeywords.contains { line.contains($0) } }
        let fallback = lines.filter { line in fallbackKeywords.contains { line.localizedCaseInsensitiveContains($0) } }
        var unavailable = lines.filter {
            $0.contains("indexUnavailable") || $0.contains("不可用") || $0.contains("未启用")
        }
        var states: [DiagnosticCandidateState] = []

        if !planned.isEmpty || stage != nil { states.append(.planned) }
        if preview != nil { states.append(.executed) }
        if !rejected.isEmpty {
            states.append(.rejected)
        }
        if !fallback.isEmpty { states.append(.fallback) }
        if preview == nil, unavailable.isEmpty, rejected.isEmpty {
            unavailable = [nilReason]
        }
        if !unavailable.isEmpty { states.append(.unavailable) }
        if planned.isEmpty, let stage {
            planned = [stage.detail]
        }
        if executed.isEmpty, preview != nil {
            executed = ["全分辨率诊断图片已生成：\(preview?.name ?? displayName)"]
        }
        if preview == nil, !lines.isEmpty, unavailable.isEmpty, rejected.isEmpty {
            rejected = lines
            states.append(.rejected)
        }

        let qualityLine = lines.first { $0.contains("technicalQualityStatus=") || $0.contains("质检=") }
        let targetQualityLine = lines.first { $0.contains("targetQualityStatus=") }
        let humanAestheticLine = lines.first { $0.contains("humanAestheticStatus=") || $0.contains("人工偏好=") }
        let assessmentEvidence = lines.filter {
            $0.contains("targetQualityStatus=")
                || $0.contains("humanAestheticStatus=")
                || $0.contains("不是审美结论")
                || $0.contains("有限反馈=")
        }
        return DiagnosticCandidateEvidence(
            identifier: identifier,
            displayName: displayName,
            states: Array(Set(states)).sorted { $0.rawValue < $1.rawValue },
            imageStageName: preview?.name,
            planned: planned,
            executed: executed,
            rejected: rejected,
            fallback: fallback,
            unavailable: unavailable,
            qualityStatus: qualityLine,
            targetQualityStatus: targetQualityLine ?? "notEvaluated",
            humanAestheticStatus: humanAestheticLine ?? "awaiting_blind_review",
            assessmentEvidence: assessmentEvidence,
            durationMilliseconds: stage?.durationMilliseconds
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
            let regionImpacts = try qualityService.measureRegionImpacts(
                originalData: originalData,
                editedData: candidateData,
                analysis: analysis
            )
            let targetAttainment = AdaptiveTargetAttainmentScorer().score(
                target: referenceDecision.adaptiveTarget,
                source: analysis,
                edited: quality.measuredAnalysis
            )
            let aestheticProxy = PhotographyAestheticProgressScorer().score(
                source: analysis,
                regionImpacts: regionImpacts
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
                "结构化视觉理解=\(analysis.visualSceneUnderstanding.traceSummary)",
                "摄影审美规划=\(referenceDecision.aestheticPlan?.traceSummary ?? "未生成；保持原逐图测量目标")",
                "目标=\(profile.resolvedTarget.summaryText)；依据=\(profile.rationale.joined(separator: " "))",
                "保护=\(profile.preservedProperties.joined(separator: ","))",
                "参数=\(parameters)",
                "局部计划=\(localPlan.isEmpty ? "无可靠局部区域" : localPlan)",
                "区域执行=\(regionalExecution.joined(separator: " | "))",
                "候选 C 质检=\(quality.status.rawValue)；问题=[\(quality.issues.map(\.rawValue).joined(separator: ","))]；RGB_MAE=\(String(format: "%.4f", quality.processingImpact.normalizedMeanAbsoluteRGBDifference))；肤色偏移=\(String(format: "%.4f", quality.colorIntegrity.skinColorDifference))；中性色染色=\(String(format: "%.4f", quality.colorIntegrity.neutralChromaIncrease))",
                "摄影目标代理（不是审美结论）=逐图目标达成 \(String(format: "%.1f", targetAttainment * 100))%；主体关系 \(String(format: "%.1f", aestheticProxy.subjectPriority * 100))%；区域协调 \(String(format: "%.1f", aestheticProxy.regionalHarmony * 100))%；最终好看与否仍需盲测",
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

    /// D is a reference-free, measured aesthetic-planning candidate. It shares
    /// the analyzer, problem detector, adaptive solver and full-resolution Core
    /// Image renderer with B, but remains isolated to diagnostic imports.
    private func evaluateMeasuredAestheticCandidate(
        originalData: Data,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        isDiagnosticImport: Bool
    ) -> IsolatedDiagnosticCandidateResult? {
        guard isDiagnosticImport,
              configuration.diagnosticValidation.measuredAestheticCandidateEnabled
        else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        var phase = "planning"
        var renderedData: Data?
        do {
            let decision = photographyDirector.direct(
                analysis: analysis,
                problems: problems,
                enableMeasuredAestheticPlanning: true
            )
            phase = "rendering"
            let initialData = try renderer.renderAutomaticEdit(
                from: originalData,
                recipe: decision.recipe,
                analysis: analysis,
                adaptiveRegionalTonePlan: decision.adaptiveRegionalTonePlan
            )
            renderedData = initialData
            phase = "qualityEvaluation"
            let initialRegionalExecution = renderer.regionalExecutionDetails(
                for: decision.recipe,
                analysis: analysis
            ) + renderer.adaptiveRegionalExecutionDetails(
                analysis: analysis,
                plan: decision.adaptiveRegionalTonePlan
            )
            let initialQuality = try qualityService.check(
                originalData: originalData,
                editedData: initialData,
                sourceAnalysis: analysis,
                expectedRegions: decision.treatmentPlan.regionalTreatments.map(\.region),
                regionalExecutionDetails: initialRegionalExecution
            )
            let initialImpacts = try qualityService.measureRegionImpacts(
                originalData: originalData,
                editedData: initialData,
                analysis: analysis
            )
            let initialAttainment = AdaptiveTargetAttainmentScorer().score(
                target: decision.adaptiveTarget,
                source: analysis,
                edited: initialQuality.measuredAnalysis
            )
            var selectedData = initialData
            var selectedRecipe = decision.recipe
            var selectedRegionalPlan = decision.adaptiveRegionalTonePlan
            var selectedQuality = initialQuality
            var selectedImpacts = initialImpacts
            var selectedAttainment = initialAttainment
            var selectedRegionalAttainment = regionalPlanExecutionScore(
                plan: decision.adaptiveRegionalTonePlan,
                impacts: initialImpacts
            )
            var selectedIteration = 0
            var feedbackTrace = "未触发：首轮渲染已在目标容差内或无可安全修正残差"

            let feedbackRecipe = measuredAestheticFeedbackRecipe(
                from: decision.recipe,
                target: decision.adaptiveTarget,
                plan: decision.aestheticPlan,
                rendered: initialQuality.measuredAnalysis,
                regionImpacts: initialImpacts
            )
            let feedbackRegionalPlan = AdaptiveRegionalToneFeedbackSolver().makeFeedback(
                plan: decision.adaptiveRegionalTonePlan,
                impacts: initialImpacts,
                risks: AdaptiveRegionalToneFeedbackRisks(
                    maskBoundaryArtifact: initialQuality.issues.contains(.localMaskBoundaryArtifact),
                    neutralIntegrityLoss: initialQuality.issues.contains(.neutralLuminanceLoss)
                        || initialQuality.issues.contains(.neutralColorDrift),
                    shadowDetailLoss: initialQuality.issues.contains(.crushedShadows)
                        || initialQuality.issues.contains(.abnormalBlackCoverage)
                        || initialQuality.issues.contains(.tooHarsh)
                )
            )
            if feedbackRecipe != nil || feedbackRegionalPlan != nil {
                phase = "feedbackRendering"
                do {
                    let resolvedFeedbackRecipe = feedbackRecipe ?? decision.recipe
                    let resolvedFeedbackPlan = feedbackRegionalPlan ?? decision.adaptiveRegionalTonePlan
                    let feedbackData = try renderer.renderAutomaticEdit(
                        from: originalData,
                        recipe: resolvedFeedbackRecipe,
                        analysis: analysis,
                        adaptiveRegionalTonePlan: resolvedFeedbackPlan
                    )
                    let feedbackRegionalExecution = renderer.regionalExecutionDetails(
                        for: resolvedFeedbackRecipe,
                        analysis: analysis
                    ) + renderer.adaptiveRegionalExecutionDetails(
                        analysis: analysis,
                        plan: resolvedFeedbackPlan
                    )
                    let feedbackQuality = try qualityService.check(
                        originalData: originalData,
                        editedData: feedbackData,
                        sourceAnalysis: analysis,
                        expectedRegions: decision.treatmentPlan.regionalTreatments.map(\.region),
                        regionalExecutionDetails: feedbackRegionalExecution
                    )
                    let feedbackImpacts = try qualityService.measureRegionImpacts(
                        originalData: originalData,
                        editedData: feedbackData,
                        analysis: analysis
                    )
                    let feedbackAttainment = AdaptiveTargetAttainmentScorer().score(
                        target: decision.adaptiveTarget,
                        source: analysis,
                        edited: feedbackQuality.measuredAnalysis
                    )
                    let feedbackRegionalAttainment = regionalPlanExecutionScore(
                        plan: resolvedFeedbackPlan,
                        impacts: feedbackImpacts
                    )
                    if shouldSelectMeasuredAestheticFeedback(
                        initialQuality: initialQuality,
                        initialAttainment: initialAttainment,
                        initialRegionalAttainment: selectedRegionalAttainment,
                        feedbackQuality: feedbackQuality,
                        feedbackAttainment: feedbackAttainment,
                        feedbackRegionalAttainment: feedbackRegionalAttainment
                    ) {
                        selectedData = feedbackData
                        selectedRecipe = resolvedFeedbackRecipe
                        selectedRegionalPlan = resolvedFeedbackPlan
                        selectedQuality = feedbackQuality
                        selectedImpacts = feedbackImpacts
                        selectedAttainment = feedbackAttainment
                        selectedRegionalAttainment = feedbackRegionalAttainment
                        selectedIteration = 1
                        renderedData = feedbackData
                        feedbackTrace = String(
                            format: "采用一次有限反馈：全局目标 %.1f%%→%.1f%%，区域执行 %.1f%%→%.1f%%，质检 %@→%@",
                            initialAttainment * 100,
                            feedbackAttainment * 100,
                            regionalPlanExecutionScore(plan: decision.adaptiveRegionalTonePlan, impacts: initialImpacts) * 100,
                            feedbackRegionalAttainment * 100,
                            initialQuality.status.rawValue,
                            feedbackQuality.status.rawValue
                        )
                    } else {
                        feedbackTrace = String(
                            format: "拒绝反馈候选：全局目标 %.1f%%→%.1f%%，区域执行 %.1f%%→%.1f%%，质检 %@→%@；保留首轮真实渲染",
                            initialAttainment * 100,
                            feedbackAttainment * 100,
                            regionalPlanExecutionScore(plan: decision.adaptiveRegionalTonePlan, impacts: initialImpacts) * 100,
                            feedbackRegionalAttainment * 100,
                            initialQuality.status.rawValue,
                            feedbackQuality.status.rawValue
                        )
                    }
                } catch {
                    feedbackTrace = "反馈渲染/复测失败，保留已完成首轮结果：\(error.localizedDescription)"
                }
            }
            phase = "completed"
            let regionalExecution = renderer.regionalExecutionDetails(
                for: selectedRecipe,
                analysis: analysis
            ) + renderer.adaptiveRegionalExecutionDetails(
                analysis: analysis,
                plan: selectedRegionalPlan
            )
            let aestheticProxy = PhotographyAestheticProgressScorer().score(
                source: analysis,
                regionImpacts: selectedImpacts
            )
            let parameters = decision.parameterEvidence.map { evidence in
                var executedEvidence = evidence.refreshingActualValue(from: selectedRecipe)
                if selectedIteration > 0 {
                    executedEvidence = executedEvidence.appendingKnowledgeRules([.renderMeasureFeedback])
                }
                return "\(executedEvidence.key.rawValue)=\(String(format: "%.4f", executedEvidence.actualValue)){input=\(executedEvidence.inputEvidence);target=\(executedEvidence.target);rules=\(executedEvidence.knowledgeRuleIDs.map(\.rawValue).joined(separator: ","));status=\(executedEvidence.decisionStatus.rawValue)}"
            }.joined(separator: ";")
            let lifecycle = decision.recipeLifecycle.map { snapshot in
                "\(snapshot.stage){changes=[\(snapshot.changes.joined(separator: ","))];recipe=\(snapshot.recipeSummary)}"
            }.joined(separator: " -> ")
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            let passedTechnicalQuality = selectedQuality.status != .failed
            let details = [
                "[D] 状态=measuredAestheticDiagnostic；不读取摄影参考，不替换 B",
                "[D] renderStatus=completed；technicalQualityStatus=\(selectedQuality.status.rawValue)；eligibleToReplaceB=false",
                "[D] targetQualityStatus=uncertain_single_hypothesis；目标达成率只衡量当前目标，不证明目标具有摄影审美价值",
                "[D] humanAestheticStatus=awaiting_blind_review",
                "[D] 视觉理解=\(analysis.visualSceneUnderstanding.traceSummary)",
                "[D] 摄影问题=\(problems.problems.map { $0.kind.rawValue }.joined(separator: ","))",
                "[D] 审美目标=\(decision.aestheticPlan?.traceSummary ?? "未生成")",
                "[D] 增强区域影调=\(selectedRegionalPlan?.traceSummary ?? "未生成（无可靠蒙版或无需调整）")；rules=PT-AESTHETIC-007,PT-AESTHETIC-008,PT-QA-003",
                "[D] 动态参数=\(parameters)",
                "[D] 参数生命周期=\(lifecycle)；rules=PT-QA-004",
                "[D] 最终实际参数=\(selectedRecipe.traceSummary)",
                String(format: "[D] 同定义复测=源亮度 %.4f/反差 %.4f/饱和 %.4f；首轮 %.4f/%.4f/%.4f；最终 %.4f/%.4f/%.4f；反馈次数=%d",
                       analysis.averageLuminance, analysis.contrastRange, analysis.averageSaturation,
                       initialQuality.measuredAnalysis.averageLuminance, initialQuality.measuredAnalysis.contrastRange, initialQuality.measuredAnalysis.averageSaturation,
                       selectedQuality.measuredAnalysis.averageLuminance, selectedQuality.measuredAnalysis.contrastRange, selectedQuality.measuredAnalysis.averageSaturation,
                       selectedIteration),
                "[D] 有限反馈=\(feedbackTrace)",
                "[D] 区域执行=\(regionalExecution.joined(separator: " | "))",
                "[D] 技术质检=\(selectedQuality.status.rawValue)；问题=[\(selectedQuality.issues.map(\.rawValue).joined(separator: ","))]；全局目标达成=\(String(format: "%.1f", selectedAttainment * 100))%；区域执行达成=\(String(format: "%.1f", selectedRegionalAttainment * 100))%；主体代理=\(String(format: "%.1f", aestheticProxy.subjectPriority * 100))%；协调代理=\(String(format: "%.1f", aestheticProxy.regionalHarmony * 100))%；不是审美结论",
                "[D] 耗时=\(duration)ms；人工偏好=待评价"
            ]
            return IsolatedDiagnosticCandidateResult(
                preview: ProcessingStagePreview(
                    name: "D 新版逐图自动后期（\(selectedQuality.status.rawValue)）",
                    imageData: selectedData
                ),
                details: details,
                stage: ProcessingStageRecord(
                    name: "D 新版逐图自动后期",
                    durationMilliseconds: duration,
                    executed: true,
                    detail: "渲染完成 · 技术质检 \(passedTechnicalQuality ? "通过/警告" : "失败")（\(selectedQuality.status.rawValue)）· 仅诊断 · 未替换 B"
                )
            )
        } catch {
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            if let renderedData {
                AppLogger.imageEngine.error(
                    "D 新版逐图候选已渲染但质检执行失败，B 不受影响：\(error.localizedDescription, privacy: .public)"
                )
                return IsolatedDiagnosticCandidateResult(
                    preview: ProcessingStagePreview(
                        name: "D 新版逐图自动后期（质检执行失败）",
                        imageData: renderedData
                    ),
                    details: [
                        "[D] 状态=qualityEvaluationFailed",
                        "[D] renderStatus=completed；technicalQualityStatus=notCompleted；eligibleToReplaceB=false",
                        "[D] 错误=\(error.localizedDescription)",
                        "[D] 保留真实渲染结果仅供诊断；未标记通过；B 不受影响"
                    ],
                    stage: ProcessingStageRecord(
                        name: "D 新版逐图自动后期",
                        durationMilliseconds: duration,
                        executed: true,
                        detail: "全分辨率渲染完成；技术质检执行失败：\(error.localizedDescription)"
                    )
                )
            }
            AppLogger.imageEngine.error(
                "D 新版逐图候选失败，B 不受影响：\(error.localizedDescription, privacy: .public)"
            )
            return IsolatedDiagnosticCandidateResult(
                preview: nil,
                details: [
                    "[D] 状态=\(phase)Failed",
                    "[D] renderStatus=notCompleted；technicalQualityStatus=notRun；eligibleToReplaceB=false",
                    "[D] 错误=\(error.localizedDescription)",
                    "[D] 未把失败结果冒充成片；B 不受影响"
                ],
                stage: ProcessingStageRecord(
                    name: "D 新版逐图自动后期",
                    durationMilliseconds: duration,
                    executed: false,
                    detail: "失败：\(error.localizedDescription)"
                )
            )
        }
    }

    /// PT-AESTHETIC-005/006: E1 and E2 are independently solved target
    /// hypotheses for the same source. They are rendered sequentially only for
    /// diagnostic imports and are never ranked as an automatic aesthetic winner.
    private func evaluateAestheticTargetExperiments(
        originalData: Data,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        isDiagnosticImport: Bool
    ) -> [AestheticExperimentCandidateResult] {
        guard isDiagnosticImport,
              configuration.diagnosticValidation.measuredAestheticCandidateEnabled
        else { return [] }

        return AestheticTargetHypothesisGenerator()
            .makeHypotheses(analysis: analysis, problems: problems)
            .map { hypothesis in
                autoreleasepool {
                    evaluateAestheticTargetExperiment(
                        hypothesis,
                        originalData: originalData,
                        analysis: analysis,
                        problems: problems
                    )
                }
            }
    }

    private func evaluateAestheticTargetExperiment(
        _ hypothesis: AestheticTargetHypothesis,
        originalData: Data,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> AestheticExperimentCandidateResult {
        let identifier = hypothesis.kind == .spatialEmphasis ? "E1" : "E2"
        let start = ProcessInfo.processInfo.systemUptime
        var renderedData: Data?
        do {
            let decision = photographyDirector.direct(
                analysis: analysis,
                problems: problems,
                targetProfile: hypothesis.profile,
                enableMeasuredAestheticPlanning: true
            )
            let initialData = try renderer.renderAutomaticEdit(
                from: originalData,
                recipe: decision.recipe,
                analysis: analysis,
                adaptiveRegionalTonePlan: decision.adaptiveRegionalTonePlan
            )
            renderedData = initialData
            let initialRegionalExecution = renderer.regionalExecutionDetails(
                for: decision.recipe,
                analysis: analysis
            ) + renderer.adaptiveRegionalExecutionDetails(
                analysis: analysis,
                plan: decision.adaptiveRegionalTonePlan
            )
            let initialQuality = try qualityService.check(
                originalData: originalData,
                editedData: initialData,
                sourceAnalysis: analysis,
                expectedRegions: decision.treatmentPlan.regionalTreatments.map(\.region),
                regionalExecutionDetails: initialRegionalExecution
            )
            let initialImpacts = try qualityService.measureRegionImpacts(
                originalData: originalData,
                editedData: initialData,
                analysis: analysis
            )
            let initialAttainment = AdaptiveTargetAttainmentScorer().score(
                target: decision.adaptiveTarget,
                source: analysis,
                edited: initialQuality.measuredAnalysis
            )

            var selectedData = initialData
            var selectedRecipe = decision.recipe
            var selectedQuality = initialQuality
            var selectedImpacts = initialImpacts
            var selectedAttainment = initialAttainment
            var feedbackStatus = "notGenerated"
            if let feedbackRecipe = measuredAestheticFeedbackRecipe(
                from: decision.recipe,
                target: decision.adaptiveTarget,
                plan: decision.aestheticPlan,
                rendered: initialQuality.measuredAnalysis,
                regionImpacts: initialImpacts
            ) {
                do {
                    let feedbackData = try renderer.renderAutomaticEdit(
                        from: originalData,
                        recipe: feedbackRecipe,
                        analysis: analysis,
                        adaptiveRegionalTonePlan: decision.adaptiveRegionalTonePlan
                    )
                    let feedbackExecution = renderer.regionalExecutionDetails(
                        for: feedbackRecipe,
                        analysis: analysis
                    ) + renderer.adaptiveRegionalExecutionDetails(
                        analysis: analysis,
                        plan: decision.adaptiveRegionalTonePlan
                    )
                    let feedbackQuality = try qualityService.check(
                        originalData: originalData,
                        editedData: feedbackData,
                        sourceAnalysis: analysis,
                        expectedRegions: decision.treatmentPlan.regionalTreatments.map(\.region),
                        regionalExecutionDetails: feedbackExecution
                    )
                    let feedbackImpacts = try qualityService.measureRegionImpacts(
                        originalData: originalData,
                        editedData: feedbackData,
                        analysis: analysis
                    )
                    let feedbackAttainment = AdaptiveTargetAttainmentScorer().score(
                        target: decision.adaptiveTarget,
                        source: analysis,
                        edited: feedbackQuality.measuredAnalysis
                    )
                    if shouldSelectMeasuredAestheticFeedback(
                        initialQuality: initialQuality,
                        initialAttainment: initialAttainment,
                        initialRegionalAttainment: regionalPlanExecutionScore(
                            plan: decision.adaptiveRegionalTonePlan,
                            impacts: initialImpacts
                        ),
                        feedbackQuality: feedbackQuality,
                        feedbackAttainment: feedbackAttainment,
                        feedbackRegionalAttainment: regionalPlanExecutionScore(
                            plan: decision.adaptiveRegionalTonePlan,
                            impacts: feedbackImpacts
                        )
                    ) {
                        selectedData = feedbackData
                        selectedRecipe = feedbackRecipe
                        selectedQuality = feedbackQuality
                        selectedImpacts = feedbackImpacts
                        selectedAttainment = feedbackAttainment
                        renderedData = feedbackData
                        feedbackStatus = String(
                            format: "generatedAndAdopted; attainment %.3f→%.3f; quality %@→%@",
                            initialAttainment,
                            feedbackAttainment,
                            initialQuality.status.rawValue,
                            feedbackQuality.status.rawValue
                        )
                    } else {
                        feedbackStatus = String(
                            format: "generatedAndRejected; attainment %.3f→%.3f; quality %@→%@",
                            initialAttainment,
                            feedbackAttainment,
                            initialQuality.status.rawValue,
                            feedbackQuality.status.rawValue
                        )
                    }
                } catch {
                    feedbackStatus = "generatedButFailed; \(error.localizedDescription)"
                }
            }

            let regionalExecution = renderer.regionalExecutionDetails(
                for: selectedRecipe,
                analysis: analysis
            ) + renderer.adaptiveRegionalExecutionDetails(
                analysis: analysis,
                plan: decision.adaptiveRegionalTonePlan
            )
            let impactTrace = selectedImpacts.map {
                String(
                    format: "%@{coverage=%.3f,luma=%+.4f,color=%.4f,contrast=%+.4f,changed=%.3f}",
                    $0.region.rawValue,
                    $0.maskCoverage,
                    $0.luminanceDelta,
                    $0.colorDelta,
                    $0.contrastDelta,
                    $0.changedPixelRatio
                )
            }.joined(separator: " | ")
            let parameters = decision.parameterEvidence.map {
                $0.refreshingActualValue(from: selectedRecipe)
            }.map {
                "\($0.key.rawValue)=\(String(format: "%.4f", $0.actualValue)){input=\($0.inputEvidence);target=\($0.target);rules=\(($0.knowledgeRuleIDs + [.measuredTargetHypotheses, .separatedAestheticAssessment]).map(\.rawValue).joined(separator: ","));status=\($0.decisionStatus.rawValue)}"
            }.joined(separator: ";")
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            let details = [
                "[\(identifier)] 状态=isolatedMeasuredTargetHypothesis；eligibleToReplaceB=false",
                "[\(identifier)] renderStatus=completed；technicalQualityStatus=\(selectedQuality.status.rawValue)",
                "[\(identifier)] targetQualityStatus=\(hypothesis.targetQualityStatus)；evidenceConfidence=\(String(format: "%.3f", hypothesis.evidenceConfidence))；目标可执行不等于目标审美合理",
                "[\(identifier)] humanAestheticStatus=awaiting_blind_review；禁止自动宣称优于 B/D",
                "[\(identifier)] 摄影目标=\(hypothesis.profile.hypothesisIdentifier)；\(hypothesis.profile.resolvedTarget.summaryText)；依据=[\(hypothesis.rationale.joined(separator: " | "))]",
                "[\(identifier)] 审美目标=\(decision.aestheticPlan?.traceSummary ?? "未生成")",
                "[\(identifier)] 增强区域影调=\(decision.adaptiveRegionalTonePlan?.traceSummary ?? "未生成（无可靠蒙版或无需调整）")；rules=PT-AESTHETIC-007,PT-QA-003",
                "[\(identifier)] 最终实际参数=\(selectedRecipe.traceSummary)；证据=[\(parameters)]",
                String(format: "[\(identifier)] 同定义复测=源亮度 %.4f/反差 %.4f/饱和 %.4f；最终 %.4f/%.4f/%.4f；目标达成 %.1f%%（仅技术目标）",
                       analysis.averageLuminance, analysis.contrastRange, analysis.averageSaturation,
                       selectedQuality.measuredAnalysis.averageLuminance,
                       selectedQuality.measuredAnalysis.contrastRange,
                       selectedQuality.measuredAnalysis.averageSaturation,
                       selectedAttainment * 100),
                "[\(identifier)] 有限反馈=\(feedbackStatus)",
                "[\(identifier)] 区域执行=\(regionalExecution.joined(separator: " | "))",
                "[\(identifier)] 区域实测=\(impactTrace.isEmpty ? "无可靠区域蒙版" : impactTrace)",
                "[\(identifier)] 技术质检=\(selectedQuality.status.rawValue)；问题=[\(selectedQuality.issues.map(\.rawValue).joined(separator: ","))]；不是审美结论",
                "[\(identifier)] 耗时=\(duration)ms；人工偏好=待评价"
            ]
            return AestheticExperimentCandidateResult(
                identifier: identifier,
                displayName: hypothesis.displayName,
                result: IsolatedDiagnosticCandidateResult(
                    preview: ProcessingStagePreview(
                        name: "\(identifier) \(hypothesis.displayName)（\(selectedQuality.status.rawValue)）",
                        imageData: selectedData
                    ),
                    details: details,
                    stage: ProcessingStageRecord(
                        name: "\(identifier) 动态摄影目标实验",
                        durationMilliseconds: duration,
                        executed: true,
                        detail: "独立逐图目标 → 全分辨率 Core Image · \(selectedQuality.status.rawValue) · 人工审美待评价"
                    )
                )
            )
        } catch {
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            let preview = renderedData.map {
                ProcessingStagePreview(name: "\(identifier) 已渲染但质检失败", imageData: $0)
            }
            return AestheticExperimentCandidateResult(
                identifier: identifier,
                displayName: hypothesis.displayName,
                result: IsolatedDiagnosticCandidateResult(
                    preview: preview,
                    details: [
                        "[\(identifier)] 状态=experimentFailed；technicalQualityStatus=notCompleted",
                        "[\(identifier)] targetQualityStatus=notEvaluated",
                        "[\(identifier)] humanAestheticStatus=notEvaluated",
                        "[\(identifier)] 错误=\(error.localizedDescription)；不替换 B/D"
                    ],
                    stage: ProcessingStageRecord(
                        name: "\(identifier) 动态摄影目标实验",
                        durationMilliseconds: duration,
                        executed: preview != nil,
                        detail: "失败：\(error.localizedDescription)"
                    )
                )
            )
        }
    }

    /// PT-AESTHETIC-004: at most one D-only correction is derived from pixels
    /// remeasured by the same `PhotoAnalyzer` definitions used for the target.
    /// It never changes B and never treats a technical score as an aesthetic
    /// verdict.
    private func measuredAestheticFeedbackRecipe(
        from original: AutomaticEditingRecipe,
        target: AdaptivePhotographyTarget,
        plan: AestheticPhotographyPlan?,
        rendered: PhotoAnalysis,
        regionImpacts: [PhotographyRegionImpact]
    ) -> AutomaticEditingRecipe? {
        var recipe = original
        var changed = false

        if rendered.averageLuminance > target.luminanceMaximum + 0.006 {
            let residual = rendered.averageLuminance - target.luminanceMaximum
            recipe.exposureEV -= (residual * 0.30).clamped(to: 0...0.055)
            recipe.brightness -= (residual * 0.07).clamped(to: 0...0.012)
            changed = true
        } else if rendered.averageLuminance < target.luminanceMinimum - 0.006 {
            let residual = target.luminanceMinimum - rendered.averageLuminance
            recipe.exposureEV += (residual * 0.30).clamped(to: 0...0.055)
            recipe.brightness += (residual * 0.07).clamped(to: 0...0.012)
            changed = true
        }

        let contrastResidual = target.contrast - rendered.contrastRange
        if abs(contrastResidual) > 0.025 {
            recipe.contrast += (contrastResidual * 0.07).clamped(to: -0.018...0.018)
            if contrastResidual > 0 {
                recipe.toneCurveAmount += (contrastResidual * 0.18).clamped(to: 0...0.055)
                recipe.localContrastAmount += (contrastResidual * 0.10).clamped(to: 0...0.025)
            } else {
                recipe.toneCurveAmount = max(0, recipe.toneCurveAmount - min(0.045, abs(contrastResidual) * 0.12))
                recipe.localContrastAmount = max(0, recipe.localContrastAmount - min(0.02, abs(contrastResidual) * 0.08))
            }
            changed = true
        }

        let saturationResidual = target.saturation - rendered.averageSaturation
        if abs(saturationResidual) > 0.025 {
            if saturationResidual > 0 {
                recipe.vibrance += (saturationResidual * 0.16).clamped(to: 0...0.025)
            } else {
                recipe.saturation += (saturationResidual * 0.08).clamped(to: -0.018...0)
            }
            changed = true
        }

        if let plan, plan.colorSeparationStrength > 0.004,
           let vegetationImpact = regionImpacts.first(where: { $0.region == .vegetation }) {
            let desiredColorDelta = 0.005 + plan.colorSeparationStrength * 0.24
            let colorResidual = desiredColorDelta - vegetationImpact.colorDelta
            if colorResidual > 0.0025 {
                recipe.hsl.yellowSaturation += (colorResidual * 1.4).clamped(to: 0...0.022)
                recipe.hsl.yellowLuminance += (colorResidual * 0.45).clamped(to: 0...0.008)
                changed = true
            }
        }

        let refined = recipe.clamped()
        return changed && refined != original ? refined : nil
    }

    private func shouldSelectMeasuredAestheticFeedback(
        initialQuality: QualityCheckResult,
        initialAttainment: Float,
        initialRegionalAttainment: Float,
        feedbackQuality: QualityCheckResult,
        feedbackAttainment: Float,
        feedbackRegionalAttainment: Float
    ) -> Bool {
        guard feedbackQuality.status != .failed else { return false }
        if initialQuality.status == .failed { return true }
        if feedbackQuality.status.isBetter(than: initialQuality.status) { return true }
        if feedbackQuality.status == initialQuality.status,
           feedbackAttainment > initialAttainment + 0.006 {
            return true
        }
        if feedbackQuality.status == initialQuality.status,
           feedbackRegionalAttainment > initialRegionalAttainment + 0.04 {
            return true
        }
        return false
    }

    /// Measures whether the regional controls that were actually sent to Core
    /// Image produced the intended direction without destroying endpoints or
    /// detail. This is execution evidence, not an aesthetic score.
    private func regionalPlanExecutionScore(
        plan: AdaptiveRegionalTonePlan?,
        impacts: [PhotographyRegionImpact]
    ) -> Float {
        guard let plan, !plan.adjustments.isEmpty else { return 1 }
        let values = plan.adjustments.compactMap { adjustment -> Float? in
            guard let impact = impacts.first(where: { $0.region == adjustment.region }) else {
                return nil
            }
            let intendedTone = adjustment.exposureEV
                + adjustment.midtoneBias * 0.8
                + adjustment.lowerMidtoneLift * 0.5
            let toneExpectation = min(0.06, abs(intendedTone) * 0.12)
            let toneDirection: Float
            if toneExpectation <= 0.004 {
                toneDirection = 1
            } else if intendedTone.sign == impact.luminanceDelta.sign {
                toneDirection = min(1, abs(impact.luminanceDelta) / toneExpectation)
            } else {
                toneDirection = 0
            }

            let requestedColor = abs(adjustment.hsl.yellowSaturation)
                + abs(adjustment.hsl.greenSaturation)
                + abs(adjustment.hsl.orangeSaturation)
            let colorExpectation = min(0.035, requestedColor * 0.10)
            let colorRealization = colorExpectation <= 0.003
                ? Float(1)
                : min(1, impact.colorDelta / colorExpectation)
            let shadowPenalty = max(
                0,
                impact.editedShadowRatio - impact.sourceShadowRatio - 0.035
            ).clamped(to: 0...0.18) / 0.18
            let highlightPenalty = max(
                0,
                impact.editedHighlightRatio - impact.sourceHighlightRatio - 0.03
            ).clamped(to: 0...0.16) / 0.16
            let detailPenalty = max(0, 0.78 - impact.detailEnergyRatio).clamped(to: 0...0.5) / 0.5
            return (
                toneDirection * 0.62
                    + colorRealization * 0.38
                    - shadowPenalty * 0.42
                    - highlightPenalty * 0.34
                    - detailPenalty * 0.28
            ).clamped(to: 0...1)
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    /// M bypasses all automatic decisions and proves whether declared controls
    /// reach the same full-resolution pixel renderer and encoder used by B/D.
    private func evaluateManualCandidate(
        originalData: Data,
        analysis: PhotoAnalysis,
        isDiagnosticImport: Bool
    ) -> IsolatedDiagnosticCandidateResult? {
        guard isDiagnosticImport,
              let parameters = configuration.diagnosticValidation.manualParameters
        else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        var renderedData: Data?
        do {
            let initialData = try renderer.renderManualEdit(
                from: originalData,
                parameters: parameters,
                analysis: analysis
            )
            renderedData = initialData
            let initialRegionalExecution = renderer.manualRegionalExecutionDetails(
                analysis: analysis,
                adjustments: parameters.regionalToneAdjustments
            )
            let initialQuality = try qualityService.check(
                originalData: originalData,
                editedData: initialData,
                sourceAnalysis: analysis,
                expectedRegions: [],
                regionalExecutionDetails: initialRegionalExecution
            )
            let initialImpacts = try qualityService.measureRegionImpacts(
                originalData: originalData,
                editedData: initialData,
                analysis: analysis
            )

            var selectedParameters = parameters
            var selectedData = initialData
            var selectedQuality = initialQuality
            var selectedImpacts = initialImpacts
            var selectedRegionalExecution = initialRegionalExecution
            var safetyTrace = "未触发：初始 M/R3 未命中可修复的影调安全问题"
            if let corrected = safetyCorrectedManualParameters(
                parameters,
                quality: initialQuality
            ) {
                let correctedData = try renderer.renderManualEdit(
                    from: originalData,
                    parameters: corrected,
                    analysis: analysis
                )
                let correctedExecution = renderer.manualRegionalExecutionDetails(
                    analysis: analysis,
                    adjustments: corrected.regionalToneAdjustments
                )
                let correctedQuality = try qualityService.check(
                    originalData: originalData,
                    editedData: correctedData,
                    sourceAnalysis: analysis,
                    expectedRegions: [],
                    regionalExecutionDetails: correctedExecution
                )
                let correctedImpacts = try qualityService.measureRegionImpacts(
                    originalData: originalData,
                    editedData: correctedData,
                    analysis: analysis
                )
                let improved = correctedQuality.status.isBetter(than: initialQuality.status)
                    || (correctedQuality.status == initialQuality.status
                        && correctedQuality.issues.count < initialQuality.issues.count)
                if improved {
                    selectedParameters = corrected
                    selectedData = correctedData
                    selectedQuality = correctedQuality
                    selectedImpacts = correctedImpacts
                    selectedRegionalExecution = correctedExecution
                    renderedData = correctedData
                    safetyTrace = "采用结果反馈安全修正：\(initialQuality.status.rawValue)[\(initialQuality.issues.map(\.rawValue).joined(separator: ","))] → \(correctedQuality.status.rawValue)[\(correctedQuality.issues.map(\.rawValue).joined(separator: ","))]"
                } else {
                    safetyTrace = "拒绝结果反馈安全修正：未改善技术状态/问题数量；保留初始失败证据，不降低阈值"
                }
            }
            let recipe = selectedParameters.makeRecipe()
            let quality = selectedQuality
            let data = selectedData
            let impacts = selectedImpacts
            let regionalExecution = selectedRegionalExecution
            let impactTrace = impacts.map {
                String(
                    format: "%@{coverage=%.3f,luma=%+.4f,color=%.4f,contrast=%+.4f,changed=%.3f}",
                    $0.region.rawValue,
                    $0.maskCoverage,
                    $0.luminanceDelta,
                    $0.colorDelta,
                    $0.contrastDelta,
                    $0.changedPixelRatio
                )
            }.joined(separator: " | ")
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            return IsolatedDiagnosticCandidateResult(
                preview: ProcessingStagePreview(
                    name: "M 人工参数真实渲染（\(quality.status.rawValue)）",
                    imageData: data
                ),
                details: [
                    "[M] 状态=manualRendererVerification；id=\(selectedParameters.identifier)；不参与自动决策，不替换 B/D",
                    "[M] renderStatus=completed；technicalQualityStatus=\(quality.status.rawValue)",
                    "[M] targetQualityStatus=manual_expression_probe_not_automatic_target",
                    "[M] humanAestheticStatus=awaiting_blind_review",
                    "[M] 声明参数=\(recipe.traceSummary)",
                    "[M] 执行模块=\(renderer.executedModuleNames(for: recipe, analysis: analysis, manualRegionalAdjustments: selectedParameters.regionalToneAdjustments).joined(separator: " → "))",
                    "[M] 区域影调回执=\(regionalExecution.joined(separator: "；"))",
                    "[M] 安全反馈=\(safetyTrace)；rules=PT-QA-003；质检阈值未修改",
                    "[M] 技术质检=\(quality.status.rawValue)；问题=[\(quality.issues.map(\.rawValue).joined(separator: ","))]；RGB_MAE=\(String(format: "%.4f", quality.processingImpact.normalizedMeanAbsoluteRGBDifference))",
                    String(format: "[M] 失败阈值证据=tooHarsh: contrastRange %.4f / 上限 0.9000；neutralLuminanceLoss: coverage %.4f / 启用阈值 0.0150，luminanceShift %+.4f / 下限 -0.0650",
                           quality.measuredAnalysis.contrastRange,
                           quality.colorIntegrity.neutralCoverage,
                           quality.colorIntegrity.neutralLuminanceShift),
                    "[M] 区域实测=\(impactTrace.isEmpty ? "无可靠区域蒙版" : impactTrace)",
                    "[M] 单参数方向另见 M 探针预览；Core Image/iPhone 视觉正确性仍需真机确认"
                ],
                stage: ProcessingStageRecord(
                    name: "M 人工参数渲染验证",
                    durationMilliseconds: duration,
                    executed: true,
                    detail: "显式人工参数 → 同一全分辨率 Core Image/编码链 · \(quality.status.rawValue)"
                )
            )
        } catch {
            let duration = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
            if let renderedData {
                return IsolatedDiagnosticCandidateResult(
                    preview: ProcessingStagePreview(
                        name: "M 人工参数真实渲染（质检执行失败）",
                        imageData: renderedData
                    ),
                    details: [
                        "[M] 状态=qualityEvaluationFailed；id=\(parameters.identifier)",
                        "[M] renderStatus=completed；technicalQualityStatus=notCompleted",
                        "[M] 错误=\(error.localizedDescription)",
                        "[M] 保留真实渲染结果仅供诊断；未标记通过"
                    ],
                    stage: ProcessingStageRecord(
                        name: "M 人工参数渲染验证",
                        durationMilliseconds: duration,
                        executed: true,
                        detail: "全分辨率渲染完成；技术质检执行失败：\(error.localizedDescription)"
                    )
                )
            }
            return IsolatedDiagnosticCandidateResult(
                preview: nil,
                details: [
                    "[M] 状态=renderFailed；id=\(parameters.identifier)",
                    "[M] 错误=\(error.localizedDescription)",
                    "[M] 未把失败结果冒充成片"
                ],
                stage: ProcessingStageRecord(
                    name: "M 人工参数渲染验证",
                    durationMilliseconds: duration,
                    executed: false,
                    detail: "失败：\(error.localizedDescription)"
                )
            )
        }
    }

    /// PT-QA-003. One bounded result-feedback pass for the isolated M/R3
    /// expression probe. It reacts to measured failure evidence; it does not
    /// change QualityCheckService thresholds and never enters B or D.
    private func safetyCorrectedManualParameters(
        _ source: ManualPhotographyParameters,
        quality: QualityCheckResult
    ) -> ManualPhotographyParameters? {
        let issues = Set(quality.issues)
        let correctable: Set<QualityIssue> = [
            .tooHarsh,
            .crushedShadows,
            .abnormalBlackCoverage,
            .neutralLuminanceLoss,
            .neutralColorDrift,
            .localMaskBoundaryArtifact
        ]
        guard !issues.isDisjoint(with: correctable) else { return nil }
        return source.safetyAdjustedForMeasuredRisks(
            tooHarsh: issues.contains(.tooHarsh),
            crushedShadows: issues.contains(.crushedShadows),
            abnormalBlackCoverage: issues.contains(.abnormalBlackCoverage),
            neutralLuminanceShift: issues.contains(.neutralLuminanceLoss)
                ? quality.colorIntegrity.neutralLuminanceShift
                : nil,
            neutralColorDrift: issues.contains(.neutralColorDrift),
            localMaskBoundaryArtifact: issues.contains(.localMaskBoundaryArtifact)
        )
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
            case .hue, .saturation, .vibrance, .orangeHSL, .yellowHSL, .greenHSL, .blueHSL, .localColor:
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

private struct IsolatedDiagnosticCandidateResult {
    let preview: ProcessingStagePreview?
    let details: [String]
    let stage: ProcessingStageRecord
}

private struct AestheticExperimentCandidateResult {
    let identifier: String
    let displayName: String
    let result: IsolatedDiagnosticCandidateResult
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

