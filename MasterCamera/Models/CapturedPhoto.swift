import Foundation
import UIKit

struct CapturedPhoto: Identifiable, Equatable, Sendable {
    let id = UUID()
    let originalImageData: Data
    let editedImageData: Data
    let capturedAt: Date
    let isDiagnosticImport: Bool
    let skinMask: NormalizedPhotoMask?
    let analysis: PhotoAnalysis?
    let problemReport: PhotoProblemReport?
    let decision: PhotographyDecision?
    let qualityCheck: QualityCheckResult?
    let processingDiagnostics: ImageProcessingDiagnostics?
    let differenceImageData: Data?
    let processingStagePreviews: [ProcessingStagePreview]

    init(
        originalImageData: Data,
        editedImageData: Data? = nil,
        capturedAt: Date,
        isDiagnosticImport: Bool = false,
        skinMask: NormalizedPhotoMask? = nil,
        analysis: PhotoAnalysis? = nil,
        problemReport: PhotoProblemReport? = nil,
        decision: PhotographyDecision? = nil,
        qualityCheck: QualityCheckResult? = nil,
        processingDiagnostics: ImageProcessingDiagnostics? = nil,
        differenceImageData: Data? = nil,
        processingStagePreviews: [ProcessingStagePreview] = []
    ) {
        self.originalImageData = originalImageData
        // A newly captured/imported photo has no AI result yet. Keeping this empty is
        // intentional: copying the original bytes here made an unprocessed capture look
        // like a valid edited deliverable to every downstream caller.
        self.editedImageData = editedImageData ?? Data()
        self.capturedAt = capturedAt
        self.isDiagnosticImport = isDiagnosticImport
        self.skinMask = skinMask
        self.analysis = analysis
        self.problemReport = problemReport
        self.decision = decision
        self.qualityCheck = qualityCheck
        self.processingDiagnostics = processingDiagnostics
        self.differenceImageData = differenceImageData
        self.processingStagePreviews = processingStagePreviews
    }

    var originalImage: UIImage? {
        UIImage(data: originalImageData)
    }

    var editedImage: UIImage? {
        guard !editedImageData.isEmpty else { return nil }
        return UIImage(data: editedImageData)
    }

    var hasCompletedProcessing: Bool {
        guard let qualityCheck else { return false }
        return !editedImageData.isEmpty
            && analysis != nil
            && decision != nil
            && qualityCheck.status != .failed
    }

    var differenceImage: UIImage? {
        guard let differenceImageData else { return nil }
        return UIImage(data: differenceImageData)
    }
}

