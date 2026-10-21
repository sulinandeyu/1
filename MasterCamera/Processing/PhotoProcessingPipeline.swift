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
        // 1. 理解照片
        let analysis = try analyzer.analyze(data: photo.originalImageData)
        // 2. 找问题
        let problemReport = problemDetector.detect(in: analysis)
        // 3–4. 判断摄影风格并制定处理策略
        let decision = decisionEngine.makeDecision(for: analysis, problems: problemReport)
        // 5. 使用人物、主体和人脸蒙版执行分区域及全局处理
        let initialEditedData = try renderer.renderAutomaticEdit(
            from: photo.originalImageData,
            recipe: decision.recipe,
            analysis: analysis
        )
        // 6. 与原片比较并检查成片质量
        let initialQualityCheck = try qualityService.check(
            originalData: photo.originalImageData,
            editedData: initialEditedData
        )
        let finalEdit = chooseFinalEdit(
            originalData: photo.originalImageData,
            initialEditedData: initialEditedData,
            initialQualityCheck: initialQualityCheck
        )

        // 7. 返回可预览的原片与成片；用户确认后由 PhotoLibraryManager 保存。
        return CapturedPhoto(
            originalImageData: photo.originalImageData,
            editedImageData: finalEdit.data,
            capturedAt: photo.capturedAt,
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
                return (fallbackData, fallbackQualityCheck)
            }

            return (initialEditedData, initialQualityCheck)
        } catch {
            AppLogger.imageEngine.error("安全回退处理失败，保留初版成片：\(error.localizedDescription)")
            return (initialEditedData, initialQualityCheck)
        }
    }
}

