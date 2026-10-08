import AVFoundation
import Foundation

final class PhotoCaptureService {
    private let photoOutput: AVCapturePhotoOutput
    private var processors: [Int64: PhotoCaptureProcessor] = [:]

    init(photoOutput: AVCapturePhotoOutput) {
        self.photoOutput = photoOutput
    }

    func capturePhoto(completion: @escaping (Result<Data, Error>) -> Void) {
        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.jpeg
        ])

        if photoOutput.isHighResolutionCaptureEnabled {
            settings.isHighResolutionPhotoEnabled = true
        }

        let processor = PhotoCaptureProcessor(
            completion: completion,
            onFinish: { [weak self] uniqueID in
                self?.processors[uniqueID] = nil
            }
        )

        processors[settings.uniqueID] = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private let onFinish: (Int64) -> Void
    private var didComplete = false

    init(
        completion: @escaping (Result<Data, Error>) -> Void,
        onFinish: @escaping (Int64) -> Void
    ) {
        self.completion = completion
        self.onFinish = onFinish
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            complete(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            complete(.failure(PhotoCaptureError.missingPhotoData))
            return
        }

        complete(.success(data))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            complete(.failure(error))
        }

        onFinish(resolvedSettings.uniqueID)
    }

    private func complete(_ result: Result<Data, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }
}

enum PhotoCaptureError: LocalizedError {
    case missingPhotoData

    var errorDescription: String? {
        switch self {
        case .missingPhotoData:
            return "拍摄结果中没有可用的图片数据。"
        }
    }
}

