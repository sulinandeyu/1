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

    let cameraManager = CameraManager()

    init() {
        cameraManager.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$state)
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

    func focusAndExpose(at point: CGPoint) {
        cameraManager.focusAndExpose(at: point)
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
                saveState = .saved
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
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run {
                self?.processingState = .rendering
            }

            let processedPhoto = await Task.detached(priority: .userInitiated) {
                PhotoProcessingPipeline().process(photo)
            }
            .value

            await MainActor.run {
                self?.processingState = .finalizing
            }
            try? await Task.sleep(nanoseconds: 120_000_000)

            self?.capturedPhoto = processedPhoto
            self?.processingState = .idle
        }
    }
}

