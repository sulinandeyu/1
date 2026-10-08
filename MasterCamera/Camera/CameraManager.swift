import AVFoundation
import Combine
import CoreGraphics
import Foundation

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var state: CameraState = .idle
    @Published private(set) var currentPosition: AVCaptureDevice.Position = .back

    private let sessionQueue = DispatchQueue(label: "com.mastercamera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private lazy var photoCaptureService = PhotoCaptureService(photoOutput: photoOutput)
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false

    func prepare() {
        Task { @MainActor in
            state = .checkingPermission
        }

        switch CameraPermissionManager.authorizationStatus {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            Task {
                let granted = await CameraPermissionManager.requestAccess()
                if granted {
                    configureIfNeeded()
                } else {
                    await MainActor.run {
                        self.state = .permissionDenied
                    }
                }
            }
        default:
            Task { @MainActor in
                state = .permissionDenied
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() {
        let nextPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        configureSession(position: nextPosition)
    }

    func capturePhoto(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        Task { @MainActor in
            state = .capturing
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.photoCaptureService.capturePhoto { [weak self] result in
                Task { @MainActor in
                    self?.state = .ready
                }

                switch result {
                case .success(let data):
                    completion(.success(CapturedPhoto(originalImageData: data, capturedAt: Date())))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard
                let self,
                let device = self.videoInput?.device
            else { return }

            do {
                try device.lockForConfiguration()

                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }

                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }

                device.unlockForConfiguration()
            } catch {
                AppLogger.camera.error("对焦/曝光设置失败：\(error.localizedDescription)")
            }
        }
    }

    private func configureIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isConfigured {
                self.startSession()
                return
            }
            self.configureSession(position: .back)
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) {
        Task { @MainActor in
            state = .configuring
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                let input = try self.makeInput(position: position)

                try self.updateSessionConfiguration(with: input)
                self.isConfigured = true

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                Task { @MainActor in
                    self.currentPosition = position
                    self.state = .ready
                }
            } catch {
                AppLogger.camera.error("相机配置失败：\(error.localizedDescription)")

                Task { @MainActor in
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func makeInput(position: AVCaptureDevice.Position) throws -> AVCaptureDeviceInput {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )

        guard let device = discoverySession.devices.first else {
            throw CameraError.deviceUnavailable
        }

        return try AVCaptureDeviceInput(device: device)
    }

    private func updateSessionConfiguration(with input: AVCaptureDeviceInput) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        session.sessionPreset = .photo

        if let videoInput {
            session.removeInput(videoInput)
        }

        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)
        videoInput = input

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                throw CameraError.cannotAddOutput
            }

            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isHighResolutionCaptureEnabled = true
        }
    }
}

enum CameraError: LocalizedError {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "当前摄像头不可用。"
        case .cannotAddInput:
            return "无法将摄像头输入添加到拍摄会话。"
        case .cannotAddOutput:
            return "无法将照片输出添加到拍摄会话。"
        }
    }
}

