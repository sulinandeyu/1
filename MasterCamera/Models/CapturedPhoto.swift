import Foundation
import UIKit

struct CapturedPhoto: Identifiable, Equatable, Sendable {
    let id = UUID()
    let originalImageData: Data
    let editedImageData: Data
    let capturedAt: Date
    let skinMask: NormalizedPhotoMask?
    let analysis: PhotoAnalysis?
    let problemReport: PhotoProblemReport?
    let decision: PhotographyDecision?
    let qualityCheck: QualityCheckResult?

    init(
        originalImageData: Data,
        editedImageData: Data? = nil,
        capturedAt: Date,
        skinMask: NormalizedPhotoMask? = nil,
        analysis: PhotoAnalysis? = nil,
        problemReport: PhotoProblemReport? = nil,
        decision: PhotographyDecision? = nil,
        qualityCheck: QualityCheckResult? = nil
    ) {
        self.originalImageData = originalImageData
        self.editedImageData = editedImageData ?? originalImageData
        self.capturedAt = capturedAt
        self.skinMask = skinMask
        self.analysis = analysis
        self.problemReport = problemReport
        self.decision = decision
        self.qualityCheck = qualityCheck
    }

    var originalImage: UIImage? {
        UIImage(data: originalImageData)
    }

    var editedImage: UIImage? {
        UIImage(data: editedImageData)
    }
}

