import Foundation
import Darwin

final class PhotoProcessingPipeline {
    private let analyzer: PhotoAnalyzer
    private let problemDetector: PhotoProblemDetector
    private let decisionEngine: PhotographyDecisionEngine
    private let renderer: CoreImageRenderer
    private let qualityService: QualityCheckService
    private let diagnosticsService: ImageProcessingDiagnosticsService

    init(
        analyzer: PhotoAnalyzer = PhotoAnalyzer(),
        problemDetector: PhotoProblemDetector = PhotoProblemDetector(),
        decisionEngine: PhotographyDecisionEngine = PhotographyDecisionEngine(),
        renderer: CoreImageRenderer = CoreImageRenderer(),
        qualityService: QualityCheckService = QualityCheckService(),
        diagnosticsService: ImageProcessingDiagnosticsService = ImageProcessingDiagnosticsService()
    ) {
        self.analyzer = analyzer
        self.problemDetector = problemDetector
        self.decisionEngine = decisionEngine
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
            "分析完成 \(Self.milliseconds(analysisDuration))ms：场景=\(analysis.semanticScene.rawValue)，亮度=\(analysis.averageLuminance)，高光=\(analysis.highlightRatio)，暗部=\(analysis.shadowRatio)，人脸=\(analysis.faceCount)"
        )
        // 2. 找问题
        let decisionStart = ProcessInfo.processInfo.systemUptime
        let problemReport = problemDetector.detect(in: analysis)
        // 3–4. 判断摄影风格并制定处理策略
        let decision = decisionEngine.makeDecision(for: analysis, problems: problemReport)
        let decisionDuration = ProcessInfo.processInfo.systemUptime - decisionStart
        AppLogger.imageEngine.info(
            "决策完成 \(Self.milliseconds(decisionDuration))ms：策略=\(decision.sceneStrategy.rawValue)，问题=\(problemReport.problems.count)，曲线=\(decision.recipe.toneCurveStyle.rawValue)/\(decision.recipe.toneCurveAmount)，调色=\(decision.recipe.colorGradeIntensity)，主体=\(decision.recipe.subjectExposureEV)EV，人脸=\(decision.recipe.faceExposureEV)EV"
        )
        // 5. 使用人物、主体和人脸蒙版执行分区域及全局处理
        let renderStart = ProcessInfo.processInfo.systemUptime
        let initialEditedData = try renderer.renderAutomaticEdit(
            from: photo.originalImageData,
            recipe: decision.recipe,
            analysis: analysis
        )
        let renderDuration = ProcessInfo.processInfo.systemUptime - renderStart
        // 6. 与原片比较并检查成片质量
        let qualityStart = ProcessInfo.processInfo.systemUptime
        let initialQualityCheck = try qualityService.check(
            originalData: photo.originalImageData,
            editedData: initialEditedData
        )
        let finalEdit = try chooseFinalEdit(
            originalData: photo.originalImageData,
            initialEditedData: initialEditedData,
            initialQualityCheck: initialQualityCheck,
            initialRecipe: decision.recipe,
            analysis: analysis
        )
        let qualityDuration = ProcessInfo.processInfo.systemUptime - qualityStart
        let totalDuration = ProcessInfo.processInfo.systemUptime - totalStart
        let finishingMemory = Self.memoryFootprint()
        AppLogger.imageEngine.info(
            "处理完成：渲染=\(Self.milliseconds(renderDuration))ms，质检/回退=\(Self.milliseconds(qualityDuration))ms，总计=\(Self.milliseconds(totalDuration))ms，状态=\(finalEdit.qualityCheck.status.rawValue)，安全回退=\(finalEdit.qualityCheck.fallbackApplied)"
        )

        let stageRecords = [
            ProcessingStageRecord(
                name: "照片理解",
                durationMilliseconds: Self.milliseconds(analysisDuration),
                executed: true,
                detail: "\(analysis.semanticScene.rawValue) · \(analysis.semanticLabels.count) 个语义标签"
            ),
            ProcessingStageRecord(
                name: "问题诊断与配方",
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
            decision: decision,
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
        analysis: PhotoAnalysis
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
            "初版成片质检失败，原因：\(initialQualityCheck.issues.map(\.rawValue).joined(separator: ","))；开始安全回退"
        )

        do {
            let fallbackData = try renderer.renderAutomaticEdit(
                from: originalData,
                recipe: .safeFallback,
                analysis: nil
            )
            let fallbackQualityCheck = try qualityService
                .check(originalData: originalData, editedData: fallbackData)
                .applyingFallback()

            if fallbackQualityCheck.status.isBetter(than: initialQualityCheck.status) {
                AppLogger.imageEngine.warning("安全回退结果更可靠，采用克制版成片")
                return (
                    fallbackData,
                    fallbackQualityCheck,
                    .safeFallback,
                    nil,
                    initialQualityCheck.issues.map(\.rawValue).joined(separator: ",")
                )
            }

            AppLogger.imageEngine.error("初版与安全回退均未通过质量验证，拒绝把异常图片标记为 AI 成片")
            throw PhotoProcessingError.qualityValidationFailed(
                initialQualityCheck.issues.map(\.rawValue).joined(separator: ",")
            )
        } catch {
            if let processingError = error as? PhotoProcessingError { throw processingError }
            AppLogger.imageEngine.error("安全回退处理失败，拒绝输出异常成片：\(error.localizedDescription)")
            throw PhotoProcessingError.safeFallbackFailed(error.localizedDescription)
        }
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

