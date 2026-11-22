import Foundation
import UIKit

struct CapturedPhoto: Identifiable, Equatable, Sendable {
    let id: UUID
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
    let diagnosticCandidates: [DiagnosticCandidateEvidence]
    let originalRetentionReceipt: OriginalRetentionReceipt?
    /// Internal-only evidence for a rendered formal-B candidate that was
    /// rejected by technical quality. It is never treated as a deliverable B or
    /// saved automatically, but can be exported locally by an authorised build.
    let rejectedFormalBEvidence: RejectedFormalBEvidence?

    init(
        id: UUID = UUID(),
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
        processingStagePreviews: [ProcessingStagePreview] = [],
        diagnosticCandidates: [DiagnosticCandidateEvidence] = [],
        originalRetentionReceipt: OriginalRetentionReceipt? = nil,
        rejectedFormalBEvidence: RejectedFormalBEvidence? = nil
    ) {
        self.id = id
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
        self.diagnosticCandidates = diagnosticCandidates
        self.originalRetentionReceipt = originalRetentionReceipt
        self.rejectedFormalBEvidence = rejectedFormalBEvidence
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

    var hasRecoverableOriginal: Bool {
        originalRetentionReceipt?.hasRecoverableOriginal == true
            || !originalImageData.isEmpty
    }

    func replacingOriginalRetentionReceipt(
        _ receipt: OriginalRetentionReceipt?
    ) -> CapturedPhoto {
        CapturedPhoto(
            id: id,
            originalImageData: originalImageData,
            editedImageData: editedImageData,
            capturedAt: capturedAt,
            isDiagnosticImport: isDiagnosticImport,
            skinMask: skinMask,
            analysis: analysis,
            problemReport: problemReport,
            decision: decision,
            qualityCheck: qualityCheck,
            processingDiagnostics: processingDiagnostics,
            differenceImageData: differenceImageData,
            processingStagePreviews: processingStagePreviews,
            diagnosticCandidates: diagnosticCandidates,
            originalRetentionReceipt: receipt,
            rejectedFormalBEvidence: rejectedFormalBEvidence
        )
    }

    func replacingRejectedFormalBEvidence(
        _ evidence: RejectedFormalBEvidence?
    ) -> CapturedPhoto {
        CapturedPhoto(
            id: id,
            originalImageData: originalImageData,
            editedImageData: editedImageData,
            capturedAt: capturedAt,
            isDiagnosticImport: isDiagnosticImport,
            skinMask: skinMask,
            analysis: analysis,
            problemReport: problemReport,
            decision: decision,
            qualityCheck: qualityCheck,
            processingDiagnostics: processingDiagnostics,
            differenceImageData: differenceImageData,
            processingStagePreviews: processingStagePreviews,
            diagnosticCandidates: diagnosticCandidates,
            originalRetentionReceipt: originalRetentionReceipt,
            rejectedFormalBEvidence: evidence
        )
    }

    var differenceImage: UIImage? {
        guard let differenceImageData else { return nil }
        return UIImage(data: differenceImageData)
    }
}

struct RejectedFormalBEvidence: Equatable, Sendable {
    let candidateImageData: Data
    let recipe: AutomaticEditingRecipe
    let initialQualityCheck: QualityCheckResult
    let finalQualityCheck: QualityCheckResult
    let analysis: PhotoAnalysis
    let regionalExecutionDetails: [String]
    let rejectionReason: String
}

