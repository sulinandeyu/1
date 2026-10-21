import AVFoundation
import CoreImage
import Foundation
import ImageIO

struct PhotoCaptureResult: Sendable {
    let imageData: Data
    let skinMask: NormalizedPhotoMask?
}

final class PhotoCaptureService {
    private let photoOutput: AVCapturePhotoOutput
    private var processors: [Int64: PhotoCaptureProcessor] = [:]

    init(photoOutput: AVCapturePhotoOutput) {
        self.photoOutput = photoOutput
    }

    func capturePhoto(
        videoRotationAngle: CGFloat,
        completion: @escaping (Result<PhotoCaptureResult, Error>) -> Void
    ) {
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(videoRotationAngle) {
            connection.videoRotationAngle = videoRotationAngle
            AppLogger.camera.info("拍照方向已设置为 \(videoRotationAngle)°")
        } else {
            AppLogger.camera.warning("设备不支持拍照旋转角度 \(videoRotationAngle)°，保留连接当前方向")
        }

        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.jpeg
        ])

        if photoOutput.enabledSemanticSegmentationMatteTypes.contains(.skin) {
            settings.enabledSemanticSegmentationMatteTypes = [.skin]
            settings.embedsSemanticSegmentationMattesInPhoto = false
        }

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
    private let completion: (Result<PhotoCaptureResult, Error>) -> Void
    private let onFinish: (Int64) -> Void
    private let context = CIContext()
    private var didComplete = false

    init(
        completion: @escaping (Result<PhotoCaptureResult, Error>) -> Void,
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

        complete(
            .success(
                PhotoCaptureResult(
                    imageData: data,
                    skinMask: normalizedSkinMask(from: photo)
                )
            )
        )
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

    private func normalizedSkinMask(from photo: AVCapturePhoto) -> NormalizedPhotoMask? {
        guard let matte = photo.semanticSegmentationMatte(for: .skin) else {
            return nil
        }

        let orientedMatte: AVSemanticSegmentationMatte
        if
            let orientationNumber = photo.metadata[String(kCGImagePropertyOrientation)] as? NSNumber,
            let orientation = CGImagePropertyOrientation(
                rawValue: orientationNumber.uint32Value
            )
        {
            orientedMatte = matte.applyingExifOrientation(orientation)
        } else {
            orientedMatte = matte
        }

        let pixelBuffer = orientedMatte.mattingImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        var pixels = [UInt8](repeating: 0, count: width * height)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: width,
            bounds: image.extent,
            format: .L8,
            colorSpace: nil
        )

        let activePixels = pixels.reduce(into: 0) { count, value in
            if value > 8 {
                count += 1
            }
        }
        guard activePixels >= max(4, pixels.count / 1_000) else { return nil }

        let mask = NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(pixels)
        )
        return mask.isValid ? mask : nil
    }

    private func complete(_ result: Result<PhotoCaptureResult, Error>) {
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

