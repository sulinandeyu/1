import AVFoundation
import Combine
import CoreGraphics
import Foundation

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published var capturedPhoto: CapturedPhoto?
    @Published var errorMessage: String?
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var processingState: ProcessingState = .idle
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var maximumZoomFactor: CGFloat = 1.0

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
                let savedReferenceCandidate = capturedPhoto.isDiagnosticImport
                    && capturedPhoto.processingStagePreviews.contains {
                        $0.name.hasPrefix("C 摄影参考校准候选") && !$0.imageData.isEmpty
                    }
                saveState = savedReferenceCandidate ? .savedDiagnosticABC : .saved
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

