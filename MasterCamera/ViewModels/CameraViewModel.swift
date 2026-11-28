import AVFoundation
import Combine
import CoreGraphics
import Foundation
import PhotosUI
import SwiftUI

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published var capturedPhoto: CapturedPhoto?
    @Published var errorMessage: String?
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var processingState: ProcessingState = .idle
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var maximumZoomFactor: CGFloat = 1.0
    @Published private(set) var diagnosticBatchProgress: DiagnosticBatchProgress?
    @Published var diagnosticBatchArchive: DiagnosticBatchArchive?
    @Published private(set) var recoverableOriginalCount = 0

    let cameraManager = CameraManager()
    private let originalRetentionStore: OriginalPhotoRetentionStore
    private var recoverableOriginals: [OriginalRetentionReceipt] = []
    private var reconciliationCaptureIDs: Set<UUID> = []

    init(originalRetentionStore: OriginalPhotoRetentionStore = .shared) {
        self.originalRetentionStore = originalRetentionStore
        cameraManager.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$state)

        cameraManager.$zoomFactor
            .receive(on: DispatchQueue.main)
            .assign(to: &$zoomFactor)

        cameraManager.$maximumZoomFactor
            .receive(on: DispatchQueue.main)
            .assign(to: &$maximumZoomFactor)
    }

    func onAppear() {
        cameraManager.prepare()
        Task { await initializeOriginalRecovery() }
    }

    func onDisappear() {
        cameraManager.stopSession()
    }

    func switchCamera() {
        guard !processingState.isProcessing else { return }
        cameraManager.switchCamera()
    }

    func capturePhoto() {
        guard !processingState.isProcessing else { return }

        errorMessage = nil
        cameraManager.capturePhoto { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let photo):
                    self?.processCapturedPhoto(photo)
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func processImportedPhotoData(_ data: Data) {
        guard !processingState.isProcessing else { return }
        guard !data.isEmpty else {
            errorMessage = "导入的样片为空。"
            return
        }

        AppLogger.imageEngine.info("导入真实样片复测：\(data.count) bytes")
        processCapturedPhoto(
            CapturedPhoto(
                originalImageData: data,
                editedImageData: nil,
                capturedAt: Date(),
                isDiagnosticImport: true
            )
        )
    }

    /// Device-local Task 2-A evidence flow. Only A enters PhotoProcessingPipeline.
    /// T is retained by this task solely for the final local ZIP and can never
    /// influence analysis, parameters, masks or rendered pixels.
    func processTask2AValidation(sourceData: Data, targetData: Data) {
        guard !processingState.isProcessing else { return }
        guard !sourceData.isEmpty, !targetData.isEmpty else {
            errorMessage = "Task 2-A 的 A 或 T 数据为空。"
            return
        }
        errorMessage = nil
        if let previousArchive = diagnosticBatchArchive?.url {
            try? FileManager.default.removeItem(at: previousArchive)
        }
        diagnosticBatchArchive = nil
        processingState = .analyzing
        Task { [weak self] in
            guard let self else { return }
            do {
                let input = CapturedPhoto(
                    originalImageData: sourceData,
                    editedImageData: nil,
                    capturedAt: Date(),
                    isDiagnosticImport: true
                )
                processingState = .rendering
                let processed = try await Task.detached(priority: .userInitiated) {
                    try PhotoProcessingPipeline().process(input)
                }.value
                processingState = .finalizing
                let archiveURL = try await Task.detached(priority: .utility) {
                    try DiagnosticBundleExporter().makeArchive(
                        for: processed,
                        externalResearchTargetData: targetData
                    )
                }.value
                diagnosticBatchArchive = DiagnosticBatchArchive(
                    url: archiveURL,
                    requestedCount: 1,
                    completedCount: 1,
                    failedCount: 0
                )
            } catch {
                errorMessage = "Task 2-A 本机渲染或证据导出失败：\(error.localizedDescription)"
            }
            processingState = .idle
        }
    }

#if XIAOSU_INTERNAL_CAPTURE_EVIDENCE
    /// PT-LEARN-007 device-local ORACLE reproduction. A is the only render
    /// input. T is passed only to the local ZIP exporter after all analysis,
    /// masks, parameters and Core Image pixels have already been produced.
    func processPTLearnOracleValidation(sourceData: Data, targetData: Data) {
        guard !processingState.isProcessing else { return }
        guard !sourceData.isEmpty, !targetData.isEmpty else {
            errorMessage = "PT-LEARN ORACLE 的 A 或 T 数据为空。"
            return
        }
        errorMessage = nil
        if let previousArchive = diagnosticBatchArchive?.url {
            try? FileManager.default.removeItem(at: previousArchive)
        }
        diagnosticBatchArchive = nil
        processingState = .analyzing
        Task { [weak self] in
            guard let self else { return }
            do {
                let input = CapturedPhoto(
                    originalImageData: sourceData,
                    editedImageData: nil,
                    capturedAt: Date(),
                    isDiagnosticImport: true
                )
                processingState = .rendering
                let processed = try await Task.detached(priority: .userInitiated) {
                    try PhotoProcessingPipeline(configuration: .ptLearnOracleDiagnostic)
                        .process(input)
                }.value
                processingState = .finalizing
                let archiveURL = try await Task.detached(priority: .utility) {
                    try DiagnosticBundleExporter().makeArchive(
                        for: processed,
                        externalResearchTargetData: targetData
                    )
                }.value
                diagnosticBatchArchive = DiagnosticBatchArchive(
                    url: archiveURL,
                    requestedCount: 1,
                    completedCount: 1,
                    failedCount: 0
                )
            } catch {
                errorMessage = "PT-LEARN ORACLE 本机渲染或证据导出失败：\(error.localizedDescription)"
            }
            processingState = .idle
        }
    }
#endif

    /// Runs the exact production analysis/solver/Core Image pipeline for up to
    /// seven private library assets. Processing is deliberately serial: only
    /// one original and one full-resolution CapturedPhoto are resident at a
    /// time, then its self-contained ZIP is written before advancing.
    func processImportedPhotoBatch(_ items: [PhotosPickerItem]) {
        guard !processingState.isProcessing else { return }
        let selectedItems = Array(items.prefix(7))
        guard !selectedItems.isEmpty else {
            errorMessage = "请至少选择一张诊断原图。"
            return
        }

        errorMessage = nil
        if let previousArchive = diagnosticBatchArchive?.url {
            try? FileManager.default.removeItem(at: previousArchive)
        }
        diagnosticBatchArchive = nil
        processingState = .analyzing
        diagnosticBatchProgress = DiagnosticBatchProgress(
            completedCount: 0,
            totalCount: selectedItems.count,
            currentItem: 1,
            failureCount: 0
        )

        Task { [weak self] in
            guard let self else { return }
            var completedCases: [DiagnosticBatchCase] = []
            var failures: [DiagnosticBatchFailure] = []

            for (offset, item) in selectedItems.enumerated() {
                let index = offset + 1
                diagnosticBatchProgress = DiagnosticBatchProgress(
                    completedCount: completedCases.count,
                    totalCount: selectedItems.count,
                    currentItem: index,
                    failureCount: failures.count
                )

                var sourceHash: String?
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                        throw DiagnosticBatchProcessingError.emptyImport
                    }
                    sourceHash = DiagnosticBundleExporter.sourceSHA256(data)
                    processingState = .rendering
                    let input = CapturedPhoto(
                        originalImageData: data,
                        editedImageData: nil,
                        capturedAt: Date(),
                        isDiagnosticImport: true
                    )
                    let processed = try await Task.detached(priority: .userInitiated) {
                        try PhotoProcessingPipeline().process(input)
                    }.value
                    processingState = .finalizing
                    let preparedCase = try await Task.detached(priority: .utility) {
                        let individualArchive = try DiagnosticBundleExporter().makeArchive(for: processed)
                        let imageDirectory = FileManager.default.temporaryDirectory
                            .appendingPathComponent("XiaoSuCamera_BatchCase_\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(
                            at: imageDirectory,
                            withIntermediateDirectories: true
                        )
                        var blindImages: [DiagnosticBatchImageFile] = []
                        let originalURL = imageDirectory.appendingPathComponent("A_original.jpg")
                        try processed.originalImageData.write(to: originalURL, options: .atomic)
                        blindImages.append(DiagnosticBatchImageFile(
                            identifier: "A",
                            fileURL: originalURL,
                            technicalStatus: "source",
                            eligibleForPreference: false
                        ))

                        if !processed.editedImageData.isEmpty {
                            let formalBURL = imageDirectory.appendingPathComponent("B_formal_output.jpg")
                            try processed.editedImageData.write(to: formalBURL, options: .atomic)
                            let formalBStatus = processed.qualityCheck?.status.rawValue ?? "notRun"
                            blindImages.append(DiagnosticBatchImageFile(
                                identifier: "B",
                                fileURL: formalBURL,
                                technicalStatus: formalBStatus,
                                eligibleForPreference: processed.qualityCheck.map {
                                    $0.status != .failed
                                } ?? false
                            ))
                        }

                        for identifier in ["D", "E1", "E2", "V2-1", "V2-2", "V2-3", "V2-AUTO"] {
                            guard let candidate = processed.diagnosticCandidates.first(where: { $0.identifier == identifier }) else {
                                continue
                            }
                            guard let preview = DiagnosticBundleExporter.resolvedPreview(
                                for: candidate,
                                in: processed.processingStagePreviews
                            ) else {
                                continue
                            }
                            let quality = candidate.qualityStatus ?? "notRun"
                            let qualityLower = quality.lowercased()
                            let eligible = candidate.states.contains(.executed)
                                && !candidate.states.contains(.rejected)
                                && !qualityLower.contains("failed")
                            let fileURL = imageDirectory.appendingPathComponent("\(identifier)_candidate.jpg")
                            try preview.imageData.write(to: fileURL, options: .atomic)
                            blindImages.append(DiagnosticBatchImageFile(
                                identifier: identifier,
                                fileURL: fileURL,
                                technicalStatus: quality,
                                eligibleForPreference: eligible
                            ))
                        }
                        return (individualArchive, blindImages)
                    }.value
                    let summaries = processed.diagnosticCandidates.map { candidate in
                        DiagnosticBatchCandidateSummary(
                            identifier: candidate.identifier,
                            states: candidate.states.map(\.rawValue),
                            qualityStatus: candidate.qualityStatus ?? "notRun",
                            humanAestheticStatus: candidate.humanAestheticStatus
                        )
                    }
                    completedCases.append(DiagnosticBatchCase(
                        index: index,
                        sourceHash: sourceHash ?? "unknown",
                        archiveURL: preparedCase.0,
                        candidates: summaries,
                        blindImages: preparedCase.1
                    ))
                } catch {
                    AppLogger.imageEngine.error(
                        "批量诊断第 \(index) 张失败：\(error.localizedDescription)"
                    )
                    failures.append(DiagnosticBatchFailure(
                        index: index,
                        sourceHash: sourceHash,
                        reason: error.localizedDescription
                    ))
                }

                diagnosticBatchProgress = DiagnosticBatchProgress(
                    completedCount: completedCases.count,
                    totalCount: selectedItems.count,
                    currentItem: min(index + 1, selectedItems.count),
                    failureCount: failures.count
                )
                processingState = .analyzing
            }

            do {
                processingState = .finalizing
                let archive = try await Task.detached(priority: .utility) {
                    try DiagnosticBatchBundleExporter().makeArchive(
                        requestedCount: selectedItems.count,
                        cases: completedCases,
                        failures: failures
                    )
                }.value
                diagnosticBatchArchive = archive
                if archive.failedCount > 0 {
                    errorMessage = "批量取证完成：成功 \(archive.completedCount) 张，失败 \(archive.failedCount) 张。失败原因已写入 ZIP。"
                }
            } catch {
                AppLogger.imageEngine.error("批量诊断打包失败：\(error.localizedDescription)")
                errorMessage = "批量诊断打包失败：\(error.localizedDescription)"
            }

            for item in completedCases {
                try? FileManager.default.removeItem(at: item.archiveURL)
                if let imageDirectory = item.blindImages.first?.fileURL.deletingLastPathComponent() {
                    try? FileManager.default.removeItem(at: imageDirectory)
                }
            }

            diagnosticBatchProgress = nil
            processingState = .idle
        }
    }

    func reportImportFailure(_ message: String) {
        errorMessage = message
    }

    func focusAndExpose(at point: CGPoint) {
        cameraManager.focusAndExpose(at: point)
    }

    func setZoomFactor(_ factor: CGFloat) {
        guard state == .ready, !processingState.isProcessing else { return }
        cameraManager.setZoomFactor(factor)
    }

    func dismissPreview() {
        capturedPhoto = nil
        saveState = .idle
        processingState = .idle
        Task { await refreshRecoverableOriginals() }
    }

    func restoreLatestPendingOriginal() {
        guard !processingState.isProcessing else { return }
        Task {
            await refreshRecoverableOriginals()
            guard let receipt = recoverableOriginals.first else { return }
            do {
                let data = try await originalRetentionStore.originalData(for: receipt)
                capturedPhoto = CapturedPhoto(
                    id: receipt.captureID,
                    originalImageData: data,
                    capturedAt: receipt.capturedAt,
                    originalRetentionReceipt: receipt
                )
                if case .needsReconciliation(let reason) = receipt.state {
                    saveState = .needsReconciliation(reason)
                } else if reconciliationCaptureIDs.contains(receipt.captureID) {
                    saveState = .needsReconciliation(
                        "正式成片的 Photos 提交状态无法确认；已停止自动重试以避免重复资产。"
                    )
                } else {
                    saveState = .idle
                }
                errorMessage = nil
            } catch {
                errorMessage = "恢复原图失败：\(error.localizedDescription)"
            }
        }
    }

    func saveCapturedPhoto() {
        guard let capturedPhoto else { return }
        guard !saveState.isSaving else { return }

        Task {
            saveState = capturedPhoto.hasCompletedProcessing
                ? .saving
                : .savingOriginalOnly

            do {
                let result = try await PhotoLibraryManager.savePhotos(capturedPhoto)
                errorMessage = nil
                switch result {
                case .diagnosticAssets:
                    saveState = .savedDiagnosticBundle
                case .originalMemoryRescue(let receipt):
                    self.capturedPhoto = capturedPhoto
                        .replacingOriginalRetentionReceipt(receipt)
                    saveState = .savedOriginalMemoryRescue
                case .captured(let outcome):
                    self.capturedPhoto = capturedPhoto
                        .replacingOriginalRetentionReceipt(outcome.originalReceipt)
                    saveState = outcome.editedAssetIdentifier == nil
                        ? .savedOriginalOnly
                        : .saved
                }
                await refreshRecoverableOriginals()
            } catch {
                errorMessage = error.localizedDescription
                if let coordinatorError = error as? PhotoSaveCoordinatorError {
                    switch coordinatorError {
                    case .needsReconciliation(let reason),
                         .confirmationUnknown(let reason):
                        saveState = .needsReconciliation(reason)
                    default:
                        saveState = .failed(error.localizedDescription)
                    }
                } else {
                    saveState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func processCapturedPhoto(_ photo: CapturedPhoto) {
        errorMessage = nil
        saveState = .idle
        processingState = .analyzing

        Task { [weak self] in
            guard let self else { return }

            let preparedPhoto: CapturedPhoto
            if !OriginalRetentionPolicy.shouldStageNewCapture(
                isDiagnosticImport: photo.isDiagnosticImport
            ) {
                preparedPhoto = photo
            } else {
                do {
                    let receipt = try await originalRetentionStore.stageOriginal(
                        data: photo.originalImageData,
                        captureID: photo.id,
                        capturedAt: photo.capturedAt
                    )
                    preparedPhoto = photo.replacingOriginalRetentionReceipt(receipt)
                    await refreshRecoverableOriginals()
                } catch {
                    // The image file and manifest are separate durability units. If
                    // the verified image reached its final name but manifest commit
                    // was interrupted, retry the same idempotent stage operation.
                    // Do not invoke cold-launch reconciliation during this process.
                    if let recovered = try? await originalRetentionStore.stageOriginal(
                        data: photo.originalImageData,
                        captureID: photo.id,
                        capturedAt: photo.capturedAt
                    ) {
                        preparedPhoto = photo.replacingOriginalRetentionReceipt(recovered)
                        await refreshRecoverableOriginals()
                        AppLogger.imageEngine.warning(
                            "原图 manifest 写入中断后已由完整文件恢复：\(photo.id.uuidString)"
                        )
                    } else {
                        let receipt = OriginalRetentionReceipt.memoryOnly(
                            captureID: photo.id,
                            data: photo.originalImageData,
                            capturedAt: photo.capturedAt,
                            reason: error.localizedDescription
                        )
                        capturedPhoto = photo.replacingOriginalRetentionReceipt(receipt)
                        saveState = .originalRetentionFailed(error.localizedDescription)
                        errorMessage = "原图私有暂存失败，已停止 AI 后期；请立即保存内存中的原图。"
                        processingState = .idle
                        return
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
            processingState = .rendering

            do {
                let processedPhoto = try await Task.detached(priority: .userInitiated) {
                    try PhotoProcessingPipeline().process(preparedPhoto)
                }
                .value

                processingState = .finalizing
                try? await Task.sleep(nanoseconds: 120_000_000)

                capturedPhoto = processedPhoto
                processingState = .idle
            } catch {
                AppLogger.imageEngine.error("照片处理失败：\(error.localizedDescription)")
#if XIAOSU_INTERNAL_CAPTURE_EVIDENCE
                if let processingError = error as? PhotoProcessingError,
                   case let .formalBRejected(_, evidence) = processingError {
                    capturedPhoto = preparedPhoto.replacingRejectedFormalBEvidence(evidence)
                } else {
                    capturedPhoto = preparedPhoto
                }
#else
                capturedPhoto = preparedPhoto
#endif
                saveState = .processingFailedOriginalAvailable
                errorMessage = "照片处理失败，原图安全副本仍可恢复：\(error.localizedDescription)"
                processingState = .idle
            }
        }
    }

    private func initializeOriginalRecovery() async {
        do {
            let report = try await originalRetentionStore.reconcileAfterColdLaunch()
            applyRecoveryReport(report)

            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            let cleanup = try await originalRetentionStore.cleanupConfirmedOriginals(
                olderThan: cutoff
            )
            for issue in cleanup.issues {
                AppLogger.imageEngine.warning("已确认原图清理：\(issue)")
            }
        } catch {
            AppLogger.imageEngine.error("原图冷启动协调失败：\(error.localizedDescription)")
        }
    }

    private func refreshRecoverableOriginals() async {
        do {
            let report = try await originalRetentionStore.recoverySnapshot()
            applyRecoveryReport(report)
        } catch {
            AppLogger.imageEngine.error("原图恢复索引读取失败：\(error.localizedDescription)")
        }
    }

    private func applyRecoveryReport(_ report: OriginalRetentionRecoveryReport) {
        recoverableOriginals = report.recoverableOriginals
        recoverableOriginalCount = report.recoverableOriginals.count
        reconciliationCaptureIDs = Set(
            report.needsReconciliation.map(\.captureID)
        )
        for issue in report.issues {
            AppLogger.imageEngine.warning("原图恢复协调：\(issue)")
        }
    }
}

private enum DiagnosticBatchProcessingError: LocalizedError {
    case emptyImport

    var errorDescription: String? {
        switch self {
        case .emptyImport:
            return "所选原图无法读取或内容为空。"
        }
    }
}

