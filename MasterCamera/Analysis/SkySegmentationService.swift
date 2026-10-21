import CoreImage
import CoreML
import Foundation

struct SkySegmentationResult: Equatable, Sendable {
    let mask: NormalizedPhotoMask
    let coverage: Float
}

final class SkySegmentationService {
    private static let modelName = "DETRResnet50SemanticSegmentationF16P6"
    private static let inputName = "image"
    private static let outputName = "semanticPredictions"
    private static let skyClassID: Int32 = 187
    private static let inputSize = 448

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cachedModel: MLModel?
    private var didFailLoadingModel = false

    func segmentSky(in data: Data) -> SkySegmentationResult? {
        guard
            let model = loadModel(),
            let image = CIImage(
                data: data,
                options: [.applyOrientationProperty: true]
            ),
            image.extent.width > 0,
            image.extent.height > 0,
            let pixelBuffer = makeInputPixelBuffer(from: image)
        else {
            return nil
        }

        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
            ])
            let output = try model.prediction(from: provider)

            guard
                let predictions = output
                    .featureValue(for: Self.outputName)?
                    .multiArrayValue
            else {
                AppLogger.imageEngine.error("天空分割模型没有返回语义预测。")
                return nil
            }

            return makeValidatedSkyMask(from: predictions)
        } catch {
            AppLogger.imageEngine.error("天空语义分割失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func loadModel() -> MLModel? {
        if let cachedModel {
            return cachedModel
        }

        guard !didFailLoadingModel else { return nil }
        didFailLoadingModel = true

        guard let modelURL = Bundle.main.url(
            forResource: Self.modelName,
            withExtension: "mlmodelc"
        ) else {
            AppLogger.imageEngine.error("应用包中缺少天空语义分割模型。")
            return nil
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            cachedModel = model
            didFailLoadingModel = false
            return model
        } catch {
            AppLogger.imageEngine.error("无法加载天空语义分割模型：\(error.localizedDescription)")
            return nil
        }
    }

    private func makeInputPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputSize,
            Self.inputSize,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let scale = CGAffineTransform(
            scaleX: CGFloat(Self.inputSize) / normalized.extent.width,
            y: CGFloat(Self.inputSize) / normalized.extent.height
        )
        context.render(normalized.transformed(by: scale), to: pixelBuffer)
        return pixelBuffer
    }

    private func makeValidatedSkyMask(
        from predictions: MLMultiArray
    ) -> SkySegmentationResult? {
        let expectedPixelCount = Self.inputSize * Self.inputSize
        guard predictions.count == expectedPixelCount else {
            AppLogger.imageEngine.error(
                "天空分割输出尺寸异常：\(predictions.count)，预期 \(expectedPixelCount)。"
            )
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: expectedPixelCount)
        var activePixelCount = 0
        var topContactCount = 0
        let topBandHeight = Self.inputSize / 10

        for index in 0..<expectedPixelCount where predictions[index].int32Value == Self.skyClassID {
            pixels[index] = 255
            activePixelCount += 1

            if index / Self.inputSize < topBandHeight {
                topContactCount += 1
            }
        }

        let coverage = Float(activePixelCount) / Float(expectedPixelCount)
        let minimumSkyPixels = expectedPixelCount / 200
        let maximumSkyPixels = Int(Float(expectedPixelCount) * 0.82)
        let minimumTopContact = Self.inputSize

        guard
            activePixelCount >= minimumSkyPixels,
            activePixelCount <= maximumSkyPixels,
            topContactCount >= minimumTopContact
        else {
            return nil
        }

        let mask = NormalizedPhotoMask(
            width: Self.inputSize,
            height: Self.inputSize,
            pixels: Data(pixels)
        )
        guard mask.isValid else { return nil }

        return SkySegmentationResult(mask: mask, coverage: coverage)
    }
}
