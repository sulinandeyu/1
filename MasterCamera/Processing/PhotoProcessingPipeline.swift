import Foundation

final class PhotoProcessingPipeline {
    private let analyzer: PhotoAnalyzer
    private let problemDetector: PhotoProblemDetector
    private let decisionEngine: PhotographyDecisionEngine
    private let renderer: CoreImageRenderer
    private let qualityService: QualityCheckService

    init(
        analyzer: PhotoAnalyzer = PhotoAnalyzer(),
        problemDetector: PhotoProblemDetector = PhotoProblemDetector(),
        decisionEngine: PhotographyDecisionEngine = PhotographyDecisionEngine(),
        renderer: CoreImageRenderer = CoreImageRenderer(),
        qualityService: QualityCheckService = QualityCheckService()
    ) {
        self.analyzer = analyzer
        self.problemDetector = problemDetector
        self.decisionEngine = decisionEngine
        self.renderer = renderer
        self.qualityService = qualityService
    }

    func process(_ photo: CapturedPhoto) throws -> CapturedPhoto {
        let totalStart = ProcessInfo.processInfo.systemUptime
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
        let finalEdit = chooseFinalEdit(
            originalData: photo.originalImageData,
            initialEditedData: initialEditedData,
            initialQualityCheck: initialQualityCheck
        )
        let qualityDuration = ProcessInfo.processInfo.systemUptime - qualityStart
        let totalDuration = ProcessInfo.processInfo.systemUptime - totalStart
        AppLogger.imageEngine.info(
            "处理完成：渲染=\(Self.milliseconds(renderDuration))ms，质检/回退=\(Self.milliseconds(qualityDuration))ms，总计=\(Self.milliseconds(totalDuration))ms，状态=\(finalEdit.qualityCheck.status.rawValue)，安全回退=\(finalEdit.qualityCheck.fallbackApplied)"
        )

        // 7. 返回可预览的原片与成片；用户确认后由 PhotoLibraryManager 保存。
        return CapturedPhoto(
            originalImageData: photo.originalImageData,
            editedImageData: finalEdit.data,
            capturedAt: photo.capturedAt,
            skinMask: photo.skinMask,
            analysis: analysis,
            problemReport: problemReport,
            decision: decision,
            qualityCheck: finalEdit.qualityCheck
        )
    }

    private func chooseFinalEdit(
        originalData: Data,
        initialEditedData: Data,
        initialQualityCheck: QualityCheckResult
    ) -> (data: Data, qualityCheck: QualityCheckResult) {
        guard initialQualityCheck.status == .failed else {
            return (initialEditedData, initialQualityCheck)
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
                return (fallbackData, fallbackQualityCheck)
            }

            AppLogger.imageEngine.warning("安全回退未改善质检等级，保留初版成片")
            return (initialEditedData, initialQualityCheck)
        } catch {
            AppLogger.imageEngine.error("安全回退处理失败，保留初版成片：\(error.localizedDescription)")
            return (initialEditedData, initialQualityCheck)
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }
}

