import CoreGraphics
import CoreImage
import Foundation
import Vision

final class PhotoAnalyzer {
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let sampleLongEdge = 128
    private let skySegmentationService: SkySegmentationService

    init(skySegmentationService: SkySegmentationService = SkySegmentationService()) {
        self.skySegmentationService = skySegmentationService
    }

    func analyze(
        data: Data,
        capturedSkinMask: NormalizedPhotoMask? = nil
    ) throws -> PhotoAnalysis {
        try analyze(
            data: data,
            includeFaceDetection: true,
            capturedSkinMask: capturedSkinMask
        )
    }

    func analyzeImageQuality(data: Data) throws -> PhotoAnalysis {
        try analyze(
            data: data,
            includeFaceDetection: false,
            capturedSkinMask: nil
        )
    }

    private func analyze(
        data: Data,
        includeFaceDetection: Bool,
        capturedSkinMask: NormalizedPhotoMask?
    ) throws -> PhotoAnalysis {
        guard let image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) else {
            throw PhotoAnalysisError.invalidImageData
        }

        let statistics = try pixelStatistics(for: image)
        let faceRegions = includeFaceDetection ? detectFaceRegions(in: data) : []
        let regionalTone = regionalToneStatistics(
            luminances: statistics.luminances,
            width: statistics.width,
            height: statistics.height,
            faceRegions: faceRegions
        )
        let personMask = includeFaceDetection ? generatePersonMask(in: data) : nil
        let salientSubjectMask = includeFaceDetection ? generateSalientSubjectMask(in: data) : nil
        let semanticLabels = includeFaceDetection ? classifyScene(in: data) : []
        let skySegmentation = includeFaceDetection
            ? skySegmentationService.segmentSky(in: data)
            : nil

        return PhotoAnalysis(
            averageLuminance: statistics.averageLuminance,
            contrastRange: statistics.contrastRange,
            redAverage: statistics.redAverage,
            greenAverage: statistics.greenAverage,
            blueAverage: statistics.blueAverage,
            shadowRatio: statistics.shadowRatio,
            highlightRatio: statistics.highlightRatio,
            averageSaturation: statistics.averageSaturation,
            faceCount: faceRegions.count,
            faceRegions: faceRegions,
            faceAverageLuminance: regionalTone.faceAverageLuminance,
            backgroundAverageLuminance: regionalTone.backgroundAverageLuminance,
            personMask: personMask,
            salientSubjectMask: salientSubjectMask,
            skinMask: capturedSkinMask?.isValid == true ? capturedSkinMask : nil,
            skyMask: skySegmentation?.mask,
            skyCoverage: skySegmentation?.coverage ?? 0,
            semanticLabels: semanticLabels
        )
    }

    private func pixelStatistics(for image: CIImage) throws -> PixelStatistics {
        guard image.extent.width > 0, image.extent.height > 0 else {
            throw PhotoAnalysisError.analysisFailed
        }

        let scale = CGFloat(sampleLongEdge) / max(image.extent.width, image.extent.height)
        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let sampledImage = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(sampledImage.extent.width.rounded(.down)))
        let height = max(1, Int(sampledImage.extent.height.rounded(.down)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        context.render(
            sampledImage,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        var luminances: [Float] = []
        luminances.reserveCapacity(width * height)
        var redTotal: Float = 0
        var greenTotal: Float = 0
        var blueTotal: Float = 0
        var saturationTotal: Float = 0
        var shadowCount = 0
        var highlightCount = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Float(pixels[index]) / 255.0
            let green = Float(pixels[index + 1]) / 255.0
            let blue = Float(pixels[index + 2]) / 255.0
            let pixelLuminance = luminance(red: red, green: green, blue: blue)
            let maximumChannel = max(red, green, blue)
            let minimumChannel = min(red, green, blue)

            redTotal += red
            greenTotal += green
            blueTotal += blue
            saturationTotal += maximumChannel > 0 ? (maximumChannel - minimumChannel) / maximumChannel : 0
            luminances.append(pixelLuminance)

            if pixelLuminance < 0.18 {
                shadowCount += 1
            }
            if pixelLuminance > 0.85 {
                highlightCount += 1
            }
        }

        guard !luminances.isEmpty else {
            throw PhotoAnalysisError.analysisFailed
        }

        let sortedLuminances = luminances.sorted()
        let count = Float(luminances.count)
        let lowPercentile = sortedLuminances[Int(Float(sortedLuminances.count - 1) * 0.05)]
        let highPercentile = sortedLuminances[Int(Float(sortedLuminances.count - 1) * 0.95)]

        return PixelStatistics(
            averageLuminance: luminances.reduce(0, +) / count,
            contrastRange: max(0, highPercentile - lowPercentile),
            redAverage: redTotal / count,
            greenAverage: greenTotal / count,
            blueAverage: blueTotal / count,
            shadowRatio: Float(shadowCount) / count,
            highlightRatio: Float(highlightCount) / count,
            averageSaturation: saturationTotal / count,
            width: width,
            height: height,
            luminances: luminances
        )
    }

    private func regionalToneStatistics(
        luminances: [Float],
        width: Int,
        height: Int,
        faceRegions: [NormalizedPhotoRegion]
    ) -> RegionalToneStatistics {
        guard
            !faceRegions.isEmpty,
            width > 0,
            height > 0,
            luminances.count == width * height
        else {
            return RegionalToneStatistics(
                faceAverageLuminance: nil,
                backgroundAverageLuminance: nil
            )
        }

        // Vision 与 Core Image 都使用左下角为归一化坐标原点。向内收缩人脸框，
        // 减少头发和背景对脸部测光的干扰。
        let meteringRegions = faceRegions.map { $0.insetForFaceMetering() }
        var faceTotal: Float = 0
        var facePixelCount = 0
        var backgroundTotal: Float = 0
        var backgroundPixelCount = 0

        for y in 0..<height {
            let normalizedY = (Float(y) + 0.5) / Float(height)

            for x in 0..<width {
                let normalizedX = (Float(x) + 0.5) / Float(width)
                let value = luminances[(y * width) + x]
                let isFacePixel = meteringRegions.contains {
                    $0.contains(x: normalizedX, y: normalizedY)
                }

                if isFacePixel {
                    faceTotal += value
                    facePixelCount += 1
                } else {
                    backgroundTotal += value
                    backgroundPixelCount += 1
                }
            }
        }

        let minimumFacePixels = max(4, (width * height) / 2_000)
        return RegionalToneStatistics(
            faceAverageLuminance: facePixelCount >= minimumFacePixels
                ? faceTotal / Float(facePixelCount)
                : nil,
            backgroundAverageLuminance: backgroundPixelCount > 0
                ? backgroundTotal / Float(backgroundPixelCount)
                : nil
        )
    }

    private func detectFaceRegions(in data: Data) -> [NormalizedPhotoRegion] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])

        do {
            try handler.perform([request])
            return request.results?.map { observation in
                NormalizedPhotoRegion(
                    x: Float(observation.boundingBox.origin.x),
                    y: Float(observation.boundingBox.origin.y),
                    width: Float(observation.boundingBox.width),
                    height: Float(observation.boundingBox.height)
                )
            } ?? []
        } catch {
            AppLogger.imageEngine.error("人脸检测失败：\(error.localizedDescription)")
            return []
        }
    }

    private func classifyScene(in data: Data) -> [SceneLabel] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])

        do {
            try handler.perform([request])
            return (request.results ?? [])
                .filter { $0.confidence >= 0.12 }
                .prefix(8)
                .map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }
        } catch {
            AppLogger.imageEngine.error("场景语义识别失败：\(error.localizedDescription)")
            return []
        }
    }

    private func generatePersonMask(in data: Data) -> NormalizedPhotoMask? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(data: data, options: [:])

        do {
            try handler.perform([request])
            guard let pixelBuffer = request.results?.first?.pixelBuffer else {
                return nil
            }
            return normalizedMask(from: pixelBuffer)
        } catch {
            AppLogger.imageEngine.error("人物分割失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func generateSalientSubjectMask(in data: Data) -> NormalizedPhotoMask? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])

        do {
            try handler.perform([request])
            guard let pixelBuffer = request.results?.first?.pixelBuffer else {
                return nil
            }
            return normalizedMask(from: pixelBuffer)
        } catch {
            AppLogger.imageEngine.error("显著主体分析失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func normalizedMask(from pixelBuffer: CVPixelBuffer) -> NormalizedPhotoMask? {
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

        let minimumActivePixels = max(4, pixels.count / 1_000)
        let activePixels = pixels.reduce(into: 0) { count, value in
            if value > 8 {
                count += 1
            }
        }
        guard activePixels >= minimumActivePixels else { return nil }

        let mask = NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(pixels)
        )
        return mask.isValid ? mask : nil
    }

    private func luminance(red: Float, green: Float, blue: Float) -> Float {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }
}

private struct PixelStatistics {
    let averageLuminance: Float
    let contrastRange: Float
    let redAverage: Float
    let greenAverage: Float
    let blueAverage: Float
    let shadowRatio: Float
    let highlightRatio: Float
    let averageSaturation: Float
    let width: Int
    let height: Int
    let luminances: [Float]
}

private struct RegionalToneStatistics {
    let faceAverageLuminance: Float?
    let backgroundAverageLuminance: Float?
}

private extension NormalizedPhotoRegion {
    func insetForFaceMetering() -> NormalizedPhotoRegion {
        NormalizedPhotoRegion(
            x: x + (width * 0.14),
            y: y + (height * 0.12),
            width: width * 0.72,
            height: height * 0.72
        )
    }

    func contains(x pointX: Float, y pointY: Float) -> Bool {
        pointX >= x && pointX <= x + width && pointY >= y && pointY <= y + height
    }
}

enum PhotoAnalysisError: LocalizedError {
    case invalidImageData
    case analysisFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法分析这张照片的数据。"
        case .analysisFailed:
            return "照片分析流程没有生成结果。"
        }
    }
}

