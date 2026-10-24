import Foundation
import Darwin

final class PhotoProcessingPipeline {
    private let analyzer: PhotoAnalyzer
    private let problemDetector: PhotoProblemDetector
    private let photographyDirector: PhotographyDirector
    private let renderer: CoreImageRenderer
    private let qualityService: QualityCheckService
    private let diagnosticsService: ImageProcessingDiagnosticsService

    init(
        analyzer: PhotoAnalyzer = PhotoAnalyzer(),
        problemDetector: PhotoProblemDetector = PhotoProblemDetector(),
        photographyDirector: PhotographyDirector = PhotographyDirector(),
        renderer: CoreImageRenderer = CoreImageRenderer(),
        qualityService: QualityCheckService = QualityCheckService(),
        diagnosticsService: ImageProcessingDiagnosticsService = ImageProcessingDiagnosticsService()
    ) {
        self.analyzer = analyzer
        self.problemDetector = problemDetector
        self.photographyDirector = photographyDirector
        self.renderer = renderer
        self.qualityService = qualityService
        self.diagnosticsService = diagnosticsService
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
        // 3–4. 判断摄影风格并制定处理策略
        let decision = photographyDirector.direct(analysis: analysis, problems: problemReport)
        let decisionDuration = ProcessInfo.processInfo.systemUptime - decisionStart
        AppLogger.imageEngine.info(
            "摄影总监决策完成 \(Self.milliseconds(decisionDuration))ms：策略=\(decision.sceneStrategy.rawValue)，目标=\(decision.aestheticTarget.rawValue)，区域=\(decision.treatmentPlan.regionalTreatments.map { $0.region.rawValue }.joined(separator: ","), privacy: .public)，人物保护=\(decision.treatmentPlan.portraitProtection.isActive)，问题=[\(problemReport.problems.map { $0.kind.rawValue }.joined(separator: ","), privacy: .public)]，配方=\(decision.recipe.traceSummary, privacy: .public)"
        )
        // 5. 使用人物、主体和人脸蒙版执行分区域及全局处理
        let renderStart = ProcessInfo.processInfo.systemUptime
        let initialEditedData = try renderer.renderAutomaticEdit(
            from: photo.originalImageData,
            recipe: decision.recipe,
            analysis: analysis
        )
        let initialRegionalExecutionDetails = renderer.regionalExecutionDetails(
            for: decision.recipe,
            analysis: analysis
        )
        AppLogger.imageEngine.info(
            "识别/分割状态：scene=\(analysis.sceneRecognitionDiagnostics.status.rawValue, privacy: .public) confidence=\(analysis.sceneRecognitionDiagnostics.topConfidence) reason=\(analysis.sceneRecognitionDiagnostics.reason ?? \"none\", privacy: .public)；segmentation=\(analysis.segmentationDiagnostics.status.rawValue, privacy: .public) reason=\(analysis.segmentationDiagnostics.reason ?? \"none\", privacy: .public)；区域回执=[\(initialRegionalExecutionDetails.joined(separator: \"；\"), privacy: .public)]"
        )
        let renderDuration = ProcessInfo.processInfo.systemUptime - renderStart
        // 6. 与原片比较并检查成片质量
        let qualityStart = ProcessInfo.processInfo.systemUptime
        let initialQualityCheck = try qualityService.check(
            originalData: photo.originalImageData,
            editedData: initialEditedData,
            sourceAnalysis: analysis,
            expectedRegions: decision.treatmentPlan.regionalTreatments.map(\.region),
            regionalExecutionDetails: initialRegionalExecutionDetails
        )
        let finalEdit = try chooseFinalEdit(
            originalData: photo.originalImageData,
            initialEditedData: initialEditedData,
            initialQualityCheck: initialQualityCheck,
            initialRecipe: decision.recipe,
            analysis: analysis,
            expectedRegions: decision.treatmentPlan.regionalTreatments.map(\.region)
        )
        let finalDecision = decision.replacingRecipe(with: finalEdit.recipe)
        let qualityDuration = ProcessInfo.processInfo.systemUptime - qualityStart
        let totalDuration = ProcessInfo.processInfo.systemUptime - totalStart
        let finishingMemory = Self.memoryFootprint()
        AppLogger.imageEngine.info(
            "处理完成：渲染=\(Self.milliseconds(renderDuration))ms，质检/回退=\(Self.milliseconds(qualityDuration))ms，总计=\(Self.milliseconds(totalDuration))ms，状态=\(finalEdit.qualityCheck.status.rawValue)，安全回退=\(finalEdit.qualityCheck.fallbackApplied)，RGB_MAE=\(finalEdit.qualityCheck.processingImpact.normalizedMeanAbsoluteRGBDifference)，变化像素=\(finalEdit.qualityCheck.processingImpact.changedPixelRatio)，最终配方=\(finalEdit.recipe.traceSummary, privacy: .public)"
        )

        let stageRecords = [
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
        let diagnosticsResult: ImageDiagnosticsResult?
        do {
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
                stages: stageRecords,
                fallbackReason: finalEdit.fallbackReason
            )
        } catch {
            diagnosticsResult = nil
            AppLogger.imageEngine.error("成片差异诊断失败：\(error.localizedDescription)")
        }

        let stagePreviews: [ProcessingStagePreview]
        do {
            stagePreviews = try renderer.renderStagePreviews(
                from: photo.originalImageData,
                recipe: finalEdit.recipe,
                analysis: finalEdit.analysis
            )
        } catch {
            stagePreviews = []
            AppLogger.imageEngine.error("处理阶段预览生成失败：\(error.localizedDescription)")
        }

        // 7. 返回可预览的原片与成片；用户确认后由 PhotoLibraryManager 保存。
        return CapturedPhoto(
            originalImageData: photo.originalImageData,
            editedImageData: finalEdit.data,
            capturedAt: photo.capturedAt,
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

    private func chooseFinalEdit(
        originalData: Data,
        initialEditedData: Data,
        initialQualityCheck: QualityCheckResult,
        initialRecipe: AutomaticEditingRecipe,
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

        do {
            let correctiveRecipe = correctionRecipe(
                from: initialRecipe,
                issues: initialQualityCheck.issues
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
        issues: [QualityIssue]
    ) -> AutomaticEditingRecipe {
        if issues.contains(.canvasMismatch) {
            return .safeFallback
        }

        var recipe = original
        let set = Set(issues)

        if !set.isDisjoint(with: [.possibleRenderFallback, .insufficientProcessingImpact]) {
            // The first render completed but did not visibly move decoded pixels. Keep the
            // scene recipe and strengthen only the photographic controls that are already
            // selected instead of replacing it with one shared fallback preset.
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.42)
            recipe.localContrastAmount = max(recipe.localContrastAmount, 0.065)
            recipe.vibrance = max(recipe.vibrance, 0.085)
            recipe.contrast = max(recipe.contrast, 1.025)
            recipe.shadowZoneExposureEV = max(recipe.shadowZoneExposureEV, 0.055)
            recipe.highlightZoneExposureEV = min(recipe.highlightZoneExposureEV, -0.055)
            recipe.luminanceMaskStrength = max(recipe.luminanceMaskStrength, 0.42)
        }

        if !set.isDisjoint(with: [.tooDark, .crushedShadows, .abnormalBlackCoverage]) {
            recipe.exposureEV = max(recipe.exposureEV, 0.04)
            recipe.shadowAmount = max(recipe.shadowAmount, 0.2)
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.24)
            recipe.shadowZoneExposureEV = min(0.16, max(recipe.shadowZoneExposureEV, 0.08))
            recipe.blackPoint = min(recipe.blackPoint, 0.004)
            recipe.contrast = min(recipe.contrast, 1.025)
        }

        if !set.isDisjoint(with: [.tooBright, .clippedHighlights, .expandedPureWhite, .excessiveHighlightSpread]) {
            recipe.exposureEV = min(recipe.exposureEV, -0.035)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.52)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.32)
            recipe.highlightZoneExposureEV = max(-0.2, min(recipe.highlightZoneExposureEV, -0.1))
            recipe.whitePoint = min(recipe.whitePoint, 0.97)
            recipe.bloomIntensity = 0
            recipe.halationIntensity = 0
        }

        if set.contains(.tooFlat) {
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.26)
            recipe.contrast = max(recipe.contrast, 1.025)
            recipe.localContrastAmount = min(0.08, max(recipe.localContrastAmount, 0.04))
        }

        if set.contains(.tooHarsh) || set.contains(.overprocessedDetail) {
            recipe.contrast = min(recipe.contrast, 1.015)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.055)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.065)
            recipe.toneCurveAmount = min(recipe.toneCurveAmount, 0.34)
        }

        if set.contains(.oversaturated) || set.contains(.abnormalColorCast) {
            recipe.saturation = min(recipe.saturation, 0.995)
            recipe.vibrance = min(recipe.vibrance, 0.055)
            recipe.temperatureShift *= 0.45
            recipe.tintShift *= 0.45
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.1)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.04)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.05)
            recipe.colorContrast = min(recipe.colorContrast, 0.04)
        }

        if !set.isDisjoint(with: [.portraitRegionOverAltered, .portraitTextureAltered]) {
            recipe.faceExposureEV = 0
            recipe.subjectExposureEV = min(recipe.subjectExposureEV, 0.08)
            recipe.hsl.orangeLuminance = 0
            recipe.hsl.orangeSaturation = min(max(recipe.hsl.orangeSaturation, -0.01), 0.01)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.12)
            recipe.noiseReductionAmount = min(recipe.noiseReductionAmount, 0.012)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.055)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.045)
            recipe.skinTextureProtection = max(recipe.skinTextureProtection, 0.76)
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

enum PhotoProcessingError: LocalizedError {
    case qualityValidationFailed(String)
    case safeFallbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .qualityValidationFailed(let issues):
            return "AI 成片未通过质量检查（\(issues)），已保留原图且未输出异常成片。"
        case .safeFallbackFailed(let reason):
            return "安全处理失败（\(reason)），已保留原图。"
        }
    }
}

