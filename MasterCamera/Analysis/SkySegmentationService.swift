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
    /// Additional class-level masks exposed by the same bundled panoptic model.
    /// These are semantic regions, not instance detections.
    let semanticObjectMasks: [SemanticObjectRole: NormalizedPhotoMask]
}

enum SceneSegmentationOutcome: Sendable {
    case success(SkySegmentationResult)
    case failure(String)
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
    // COCO panoptic IDs carried by this model. They are grouped only to expose
    // evidence to the planner; no group selects a recipe or fixed parameter.
    private static let semanticObjectClassIDs: [SemanticObjectRole: Set<Int32>] = [
        .person: [1],
        .vehicle: [2, 3, 4, 6, 7, 8, 9],
        .animal: [16, 17, 18, 19, 20, 21, 22, 23, 24, 25],
        .foodOrFruit: [52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 122, 196],
        .furnitureOrWorkspace: [62, 63, 65, 67, 72, 73, 74, 75, 76, 77, 84],
        .artificialLight: [10, 130],
        .pathOrRoad: [147, 149, 191]
    ]
    private static let inputSize = 448

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cachedModel: MLModel?
    private var didFailLoadingModel = false

    func segmentSky(in data: Data) -> SceneSegmentationOutcome {
        guard let model = loadModel() else {
            return .failure("Core ML 场景分割模型不可用")
        }
        guard
            let image = CIImage(
                data: data,
                options: [.applyOrientationProperty: true]
            ),
            image.extent.width > 0,
            image.extent.height > 0
        else {
            return .failure("场景分割无法解码输入图片")
        }
        guard let modelInput = makeInputPixelBuffer(from: image) else {
            return .failure("场景分割无法创建模型输入")
        }

        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                Self.inputName: MLFeatureValue(pixelBuffer: modelInput.pixelBuffer)
            ])
            let output = try model.prediction(from: provider)

            guard
                let predictions = output
                    .featureValue(for: Self.outputName)?
                    .multiArrayValue
            else {
                AppLogger.imageEngine.error("天空分割模型没有返回语义预测。")
                return .failure("Core ML 模型没有返回 semanticPredictions")
            }

            guard let result = makeValidatedSkyMask(
                from: predictions,
                contentRect: modelInput.contentRect
            ) else {
                return .failure("Core ML 语义输出尺寸或内容无效")
            }
            return .success(result)
        } catch {
            AppLogger.imageEngine.error("天空语义分割失败：\(error.localizedDescription)")
            return .failure("Core ML 推理失败：\(error.localizedDescription)")
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

    private func makeInputPixelBuffer(from image: CIImage) -> SegmentationModelInput? {
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
        let uniformScale = min(
            CGFloat(Self.inputSize) / normalized.extent.width,
            CGFloat(Self.inputSize) / normalized.extent.height
        )
        let scaledSize = CGSize(
            width: normalized.extent.width * uniformScale,
            height: normalized.extent.height * uniformScale
        )
        let origin = CGPoint(
            x: (CGFloat(Self.inputSize) - scaledSize.width) * 0.5,
            y: (CGFloat(Self.inputSize) - scaledSize.height) * 0.5
        )
        let fitted = normalized
            .transformed(by: CGAffineTransform(scaleX: uniformScale, y: uniformScale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize)
        )
        let composed = fitted.composited(over: canvas)
        context.render(composed, to: pixelBuffer)
        let contentRect = CGRect(origin: origin, size: scaledSize).integral
            .intersection(CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize))
        return SegmentationModelInput(pixelBuffer: pixelBuffer, contentRect: contentRect)
    }

    private func makeValidatedSkyMask(
        from predictions: MLMultiArray,
        contentRect: CGRect
    ) -> SkySegmentationResult? {
        let expectedPixelCount = Self.inputSize * Self.inputSize
        guard predictions.count == expectedPixelCount else {
            AppLogger.imageEngine.error(
                "天空分割输出尺寸异常：\(predictions.count)，预期 \(expectedPixelCount)。"
            )
            return nil
        }

        let minX = max(0, Int(contentRect.minX.rounded(.down)))
        let minY = max(0, Int(contentRect.minY.rounded(.down)))
        let width = min(Self.inputSize - minX, Int(contentRect.width.rounded(.down)))
        let height = min(Self.inputSize - minY, Int(contentRect.height.rounded(.down)))
        guard width > 0, height > 0 else { return nil }
        let contentPixelCount = width * height
        var pixels = [UInt8](repeating: 0, count: contentPixelCount)
        var groundPixels = [UInt8](repeating: 0, count: contentPixelCount)
        var vegetationPixels = [UInt8](repeating: 0, count: contentPixelCount)
        var waterPixels = [UInt8](repeating: 0, count: contentPixelCount)
        var architecturePixels = [UInt8](repeating: 0, count: contentPixelCount)
        var semanticObjectPixels = Dictionary(
            uniqueKeysWithValues: Self.semanticObjectClassIDs.keys.map {
                ($0, [UInt8](repeating: 0, count: contentPixelCount))
            }
        )
        var activePixelCount = 0
        var topContactCount = 0
        let topBandHeight = max(1, height / 10)

        for y in 0..<height {
            for x in 0..<width {
                let outputIndex = (y * width) + x
                let predictionIndex = ((minY + y) * Self.inputSize) + minX + x
                let classID = predictions[predictionIndex].int32Value
                if classID == Self.skyClassID {
                    pixels[outputIndex] = 255
                    activePixelCount += 1
                    if y < topBandHeight {
                        topContactCount += 1
                    }
                }
                if Self.groundClassIDs.contains(classID) { groundPixels[outputIndex] = 255 }
                if Self.vegetationClassIDs.contains(classID) { vegetationPixels[outputIndex] = 255 }
                if Self.waterClassIDs.contains(classID) { waterPixels[outputIndex] = 255 }
                if Self.architectureClassIDs.contains(classID) { architecturePixels[outputIndex] = 255 }
                for (role, classIDs) in Self.semanticObjectClassIDs where classIDs.contains(classID) {
                    semanticObjectPixels[role]?[outputIndex] = 255
                }
            }
        }

        let coverage = Float(activePixelCount) / Float(contentPixelCount)
        let minimumSkyPixels = contentPixelCount / 200
        let maximumSkyPixels = Int(Float(contentPixelCount) * 0.82)
        let minimumTopContact = width

        let skyIsValid = activePixelCount >= minimumSkyPixels
            && activePixelCount <= maximumSkyPixels
            && topContactCount >= minimumTopContact
        let skyMask = skyIsValid
            ? NormalizedPhotoMask(
                width: width,
                height: height,
                pixels: Data(pixels)
            )
            : nil

        let semanticObjectMasks = semanticObjectPixels.reduce(
            into: [SemanticObjectRole: NormalizedPhotoMask]()
        ) { result, entry in
            if let mask = validatedRegionMask(entry.value, width: width, height: height) {
                result[entry.key] = mask
            }
        }
        return SkySegmentationResult(
            mask: skyMask?.isValid == true ? skyMask : nil,
            coverage: skyMask?.isValid == true ? coverage : 0,
            groundMask: validatedRegionMask(groundPixels, width: width, height: height),
            vegetationMask: validatedRegionMask(vegetationPixels, width: width, height: height),
            waterMask: validatedRegionMask(waterPixels, width: width, height: height),
            architectureMask: validatedRegionMask(architecturePixels, width: width, height: height),
            semanticObjectMasks: semanticObjectMasks
        )
    }

    private func validatedRegionMask(
        _ pixels: [UInt8],
        width: Int,
        height: Int
    ) -> NormalizedPhotoMask? {
        let active = pixels.reduce(into: 0) { count, value in
            if value > 0 { count += 1 }
        }
        let total = width * height
        guard active >= total / 300, active <= Int(Float(total) * 0.9) else {
            return nil
        }
        let mask = NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(pixels)
        )
        return mask.isValid ? mask : nil
    }
}

private struct SegmentationModelInput {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
}
