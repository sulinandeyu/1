import Foundation

final class PhotoProcessingPipeline {
    private let analyzer: PhotoAnalyzer
    private let decisionEngine: PhotographyDecisionEngine
    private let renderer: CoreImageRenderer
    private let qualityService: QualityCheckService

    init(
        analyzer: PhotoAnalyzer = PhotoAnalyzer(),
        decisionEngine: PhotographyDecisionEngine = PhotographyDecisionEngine(),
        renderer: CoreImageRenderer = CoreImageRenderer(),
        qualityService: QualityCheckService = QualityCheckService()
    ) {
        self.analyzer = analyzer
        self.decisionEngine = decisionEngine
        self.renderer = renderer
        self.qualityService = qualityService
    }

    func process(_ photo: CapturedPhoto) -> CapturedPhoto {
        do {
            let analysis = try analyzer.analyze(data: photo.originalImageData)
            let decision = decisionEngine.makeDecision(for: analysis)
            let initialEditedData = try renderer.renderAutomaticEdit(
                from: photo.originalImageData,
                recipe: decision.recipe,
                analysis: analysis
            )
            let initialQualityCheck = try qualityService.check(
                originalData: photo.originalImageData,
                editedData: initialEditedData
            )
            let finalEdit = try chooseFinalEdit(
                originalData: photo.originalImageData,
                initialEditedData: initialEditedData,
                initialQualityCheck: initialQualityCheck
            )

            return CapturedPhoto(
                originalImageData: photo.originalImageData,
                editedImageData: finalEdit.data,
                capturedAt: photo.capturedAt,
                analysis: analysis,
                decision: decision,
                qualityCheck: finalEdit.qualityCheck
            )
        } catch {
            AppLogger.imageEngine.error("照片处理失败：\(error.localizedDescription)")
            return photo
        }
    }

    private func chooseFinalEdit(
        originalData: Data,
        initialEditedData: Data,
        initialQualityCheck: QualityCheckResult
    ) throws -> (data: Data, qualityCheck: QualityCheckResult) {
        guard initialQualityCheck.status == .failed else {
            return (initialEditedData, initialQualityCheck)
        }

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
    }
}

