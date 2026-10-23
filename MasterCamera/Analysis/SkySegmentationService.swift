import CoreImage
import CoreML
import Foundation

struct SkySegmentationResult: Equatable, Sendable {
    let mask: NormalizedPhotoMask?
    let coverage: Float
    let groundMask: NormalizedPhotoMask?
    let vegetationMask: NormalizedPhotoMask?
    let waterMask: NormalizedPhotoMask?
    let architectureMask: NormalizedPhotoMask?
}

final class SkySegmentationService {
    private static let modelName = "DETRResnet50SemanticSegmentationF16P6"
    private static let inputName = "image"
    private static let outputName = "semanticPredictions"
    private static let skyClassID: Int32 = 187
    // IDs come from this bundled model's labels metadata. semanticPredictions emits
    // the original COCO panoptic IDs rather than contiguous training indices.
    private static let groundClassIDs: Set<Int32> = [118, 125, 144, 149, 154, 190, 191, 194, 200]
    private static let vegetationClassIDs: Set<Int32> = [64, 119, 184, 193]
    private static let waterClassIDs: Set<Int32> = [148, 155, 178]
    private static let architectureClassIDs: Set<Int32> = [95, 112, 128, 151, 161, 171, 175, 176, 177, 180, 181, 185, 186, 197, 199]
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
        var groundPixels = [UInt8](repeating: 0, count: expectedPixelCount)
        var vegetationPixels = [UInt8](repeating: 0, count: expectedPixelCount)
        var waterPixels = [UInt8](repeating: 0, count: expectedPixelCount)
        var architecturePixels = [UInt8](repeating: 0, count: expectedPixelCount)
        var activePixelCount = 0
        var topContactCount = 0
        let topBandHeight = Self.inputSize / 10

        for index in 0..<expectedPixelCount {
            let classID = predictions[index].int32Value
            if classID == Self.skyClassID {
                pixels[index] = 255
                activePixelCount += 1
                if index / Self.inputSize < topBandHeight {
                    topContactCount += 1
                }
            }
            if Self.groundClassIDs.contains(classID) { groundPixels[index] = 255 }
            if Self.vegetationClassIDs.contains(classID) { vegetationPixels[index] = 255 }
            if Self.waterClassIDs.contains(classID) { waterPixels[index] = 255 }
            if Self.architectureClassIDs.contains(classID) { architecturePixels[index] = 255 }
        }

        let coverage = Float(activePixelCount) / Float(expectedPixelCount)
        let minimumSkyPixels = expectedPixelCount / 200
        let maximumSkyPixels = Int(Float(expectedPixelCount) * 0.82)
        let minimumTopContact = Self.inputSize

        let skyIsValid = activePixelCount >= minimumSkyPixels
            && activePixelCount <= maximumSkyPixels
            && topContactCount >= minimumTopContact
        let skyMask = skyIsValid
            ? NormalizedPhotoMask(
                width: Self.inputSize,
                height: Self.inputSize,
                pixels: Data(pixels)
            )
            : nil

        return SkySegmentationResult(
            mask: skyMask?.isValid == true ? skyMask : nil,
            coverage: skyMask?.isValid == true ? coverage : 0,
            groundMask: validatedRegionMask(groundPixels),
            vegetationMask: validatedRegionMask(vegetationPixels),
            waterMask: validatedRegionMask(waterPixels),
            architectureMask: validatedRegionMask(architecturePixels)
        )
    }

    private func validatedRegionMask(_ pixels: [UInt8]) -> NormalizedPhotoMask? {
        let active = pixels.reduce(into: 0) { count, value in
            if value > 0 { count += 1 }
        }
        let total = Self.inputSize * Self.inputSize
        guard active >= total / 300, active <= Int(Float(total) * 0.9) else {
            return nil
        }
        let mask = NormalizedPhotoMask(
            width: Self.inputSize,
            height: Self.inputSize,
            pixels: Data(pixels)
        )
        return mask.isValid ? mask : nil
    }
}
