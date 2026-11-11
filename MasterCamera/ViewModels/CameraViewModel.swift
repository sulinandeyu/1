import AVFoundation
import Combine
import CoreGraphics
import Foundation
import PhotosUI

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

    let cameraManager = CameraManager()

    init() {
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

                        for identifier in ["D", "E1", "E2"] {
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
    }

    func saveCapturedPhoto() {
        guard let capturedPhoto else { return }
        guard !saveState.isSaving else { return }

        Task {
            saveState = .saving

            do {
                try await PhotoLibraryManager.savePhotos(capturedPhoto)
                errorMessage = nil
                saveState = capturedPhoto.isDiagnosticImport ? .savedDiagnosticBundle : .saved
            } catch {
                errorMessage = error.localizedDescription
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func processCapturedPhoto(_ photo: CapturedPhoto) {
        errorMessage = nil
        saveState = .idle
        processingState = .analyzing

        Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 120_000_000)
            processingState = .rendering

            do {
                let processedPhoto = try await Task.detached(priority: .userInitiated) {
                    try PhotoProcessingPipeline().process(photo)
                }
                .value

                processingState = .finalizing
                try? await Task.sleep(nanoseconds: 120_000_000)

                capturedPhoto = processedPhoto
                processingState = .idle
            } catch {
                AppLogger.imageEngine.error("照片处理失败：\(error.localizedDescription)")
                errorMessage = "照片处理失败：\(error.localizedDescription)"
                processingState = .idle
            }
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

