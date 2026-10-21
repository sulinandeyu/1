import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

struct ImageProcessingDiagnostics: Equatable, Sendable {
    let original: ImageFileDiagnostics
    let edited: ImageFileDiagnostics
    let difference: PixelDifferenceMetrics
    let executedModules: [String]
    let stages: [ProcessingStageRecord]
    let fallbackReason: String?
}

struct ImageFileDiagnostics: Equatable, Sendable {
    let identifier: String
    let encodedPixelWidth: Int
    let encodedPixelHeight: Int
    let decodedPixelWidth: Int
    let decodedPixelHeight: Int
    let exifOrientation: UInt32
    let colorModel: String
    let colorProfile: String
    let byteCount: Int
}

struct PixelDifferenceMetrics: Equatable, Sendable {
    let normalizedMeanAbsoluteRGBDifference: Float
    let meanAbsoluteLuminanceDifference: Float
    let meanAbsoluteColorDifference: Float
    let changedPixelRatio: Float
    let originalAverageLuminance: Float
    let editedAverageLuminance: Float
    let originalMeanRGB: [Float]
    let editedMeanRGB: [Float]
    let originalLuminanceHistogram: [Float]
    let editedLuminanceHistogram: [Float]
}

struct ProcessingStageRecord: Equatable, Sendable {
    let name: String
    let durationMilliseconds: Int
    let executed: Bool
    let detail: String
}

struct ProcessingStagePreview: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let imageData: Data

    init(name: String, imageData: Data) {
        self.id = name
        self.name = name
        self.imageData = imageData
    }
}

struct ImageDiagnosticsResult: Sendable {
    let diagnostics: ImageProcessingDiagnostics
    let differenceImageData: Data?
}

final class ImageProcessingDiagnosticsService {
    private let context = CIContext(options: [.cacheIntermediates: true])
    private let comparisonColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let comparisonLongEdge = 192
    private let differencePreviewLongEdge: CGFloat = 1_600

    func inspect(
        originalData: Data,
        editedData: Data,
        executedModules: [String],
        stages: [ProcessingStageRecord],
        fallbackReason: String?
    ) throws -> ImageDiagnosticsResult {
        guard
            let originalImage = CIImage(
                data: originalData,
                options: [.applyOrientationProperty: true]
            ),
            let editedImage = CIImage(
                data: editedData,
                options: [.applyOrientationProperty: true]
            )
        else {
            throw ImageDiagnosticsError.invalidImageData
        }

        let metrics = try comparePixels(
            original: originalImage,
            edited: editedImage
        )
        let result = ImageProcessingDiagnostics(
            original: try fileDiagnostics(data: originalData, decodedImage: originalImage),
            edited: try fileDiagnostics(data: editedData, decodedImage: editedImage),
            difference: metrics,
            executedModules: executedModules,
            stages: stages,
            fallbackReason: fallbackReason
        )

        AppLogger.imageEngine.info(
            "像素差异：RGB MAE=\(metrics.normalizedMeanAbsoluteRGBDifference)，亮度 MAE=\(metrics.meanAbsoluteLuminanceDifference)，颜色 MAE=\(metrics.meanAbsoluteColorDifference)，变化像素=\(metrics.changedPixelRatio)"
        )

        return ImageDiagnosticsResult(
            diagnostics: result,
            differenceImageData: makeDifferencePreview(
                original: originalImage,
                edited: editedImage
            )
        )
    }

    private func fileDiagnostics(
        data: Data,
        decodedImage: CIImage
    ) throws -> ImageFileDiagnostics {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            throw ImageDiagnosticsError.invalidImageData
        }

        let identifier = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return ImageFileDiagnostics(
            identifier: String(identifier.prefix(16)),
            encodedPixelWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            encodedPixelHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            decodedPixelWidth: Int(decodedImage.extent.width.rounded()),
            decodedPixelHeight: Int(decodedImage.extent.height.rounded()),
            exifOrientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
            colorModel: properties[kCGImagePropertyColorModel] as? String ?? "未知",
            colorProfile: properties[kCGImagePropertyProfileName] as? String ?? "未标注",
            byteCount: data.count
        )
    }

    private func comparePixels(
        original: CIImage,
        edited: CIImage
    ) throws -> PixelDifferenceMetrics {
        let targetSize = comparisonSize(for: original.extent)
        let originalPixels = try rgbaPixels(from: original, targetSize: targetSize)
        let editedPixels = try rgbaPixels(from: edited, targetSize: targetSize)
        guard originalPixels.count == editedPixels.count, !originalPixels.isEmpty else {
            throw ImageDiagnosticsError.incompatibleImages
        }

        var rgbDifference: Float = 0
        var luminanceDifference: Float = 0
        var colorDifference: Float = 0
        var changedPixels = 0
        var originalLuminanceTotal: Float = 0
        var editedLuminanceTotal: Float = 0
        var originalRGBTotal = [Float](repeating: 0, count: 3)
        var editedRGBTotal = [Float](repeating: 0, count: 3)
        var originalHistogram = [Float](repeating: 0, count: 16)
        var editedHistogram = [Float](repeating: 0, count: 16)
        let pixelCount = originalPixels.count / 4

        for index in stride(from: 0, to: originalPixels.count, by: 4) {
            let originalRed = Float(originalPixels[index]) / 255
            let originalGreen = Float(originalPixels[index + 1]) / 255
            let originalBlue = Float(originalPixels[index + 2]) / 255
            let editedRed = Float(editedPixels[index]) / 255
            let editedGreen = Float(editedPixels[index + 1]) / 255
            let editedBlue = Float(editedPixels[index + 2]) / 255

            let redDifference = abs(originalRed - editedRed)
            let greenDifference = abs(originalGreen - editedGreen)
            let blueDifference = abs(originalBlue - editedBlue)
            let meanRGBDifference = (redDifference + greenDifference + blueDifference) / 3
            rgbDifference += meanRGBDifference

            let originalLuminance = luminance(
                red: originalRed,
                green: originalGreen,
                blue: originalBlue
            )
            let editedLuminance = luminance(
                red: editedRed,
                green: editedGreen,
                blue: editedBlue
            )
            luminanceDifference += abs(originalLuminance - editedLuminance)
            originalLuminanceTotal += originalLuminance
            editedLuminanceTotal += editedLuminance
            originalRGBTotal[0] += originalRed
            originalRGBTotal[1] += originalGreen
            originalRGBTotal[2] += originalBlue
            editedRGBTotal[0] += editedRed
            editedRGBTotal[1] += editedGreen
            editedRGBTotal[2] += editedBlue
            originalHistogram[min(15, Int(originalLuminance * 16))] += 1
            editedHistogram[min(15, Int(editedLuminance * 16))] += 1

            let originalRedChroma = originalRed - originalLuminance
            let originalBlueChroma = originalBlue - originalLuminance
            let editedRedChroma = editedRed - editedLuminance
            let editedBlueChroma = editedBlue - editedLuminance
            colorDifference += (
                abs(originalRedChroma - editedRedChroma)
                    + abs(originalBlueChroma - editedBlueChroma)
            ) / 2

            if meanRGBDifference > (3.0 / 255.0) {
                changedPixels += 1
            }
        }

        let count = Float(pixelCount)
        return PixelDifferenceMetrics(
            normalizedMeanAbsoluteRGBDifference: rgbDifference / count,
            meanAbsoluteLuminanceDifference: luminanceDifference / count,
            meanAbsoluteColorDifference: colorDifference / count,
            changedPixelRatio: Float(changedPixels) / count,
            originalAverageLuminance: originalLuminanceTotal / count,
            editedAverageLuminance: editedLuminanceTotal / count,
            originalMeanRGB: originalRGBTotal.map { $0 / count },
            editedMeanRGB: editedRGBTotal.map { $0 / count },
            originalLuminanceHistogram: originalHistogram.map { $0 / count },
            editedLuminanceHistogram: editedHistogram.map { $0 / count }
        )
    }

    private func rgbaPixels(
        from image: CIImage,
        targetSize: CGSize
    ) throws -> [UInt8] {
        guard image.extent.width > 0, image.extent.height > 0 else {
            throw ImageDiagnosticsError.invalidImageData
        }

        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: targetSize.width / translated.extent.width,
                y: targetSize.height / translated.extent.height
            )
        )
        let width = max(1, Int(targetSize.width.rounded()))
        let height = max(1, Int(targetSize.height.rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: comparisonColorSpace
        )
        return pixels
    }

    private func comparisonSize(for extent: CGRect) -> CGSize {
        let scale = CGFloat(comparisonLongEdge) / max(extent.width, extent.height)
        return CGSize(
            width: max(1, (extent.width * scale).rounded()),
            height: max(1, (extent.height * scale).rounded())
        )
    }

    private func makeDifferencePreview(
        original: CIImage,
        edited: CIImage
    ) -> Data? {
        let difference = edited
            .applyingFilter("CIDifferenceBlendMode", parameters: [
                kCIInputBackgroundImageKey: original
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 5, w: 0)
            ])
            .cropped(to: original.extent)

        let scale = min(
            1,
            differencePreviewLongEdge / max(difference.extent.width, difference.extent.height)
        )
        let translated = difference.transformed(
            by: CGAffineTransform(
                translationX: -difference.extent.minX,
                y: -difference.extent.minY
            )
        )
        let preview = translated.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return context.jpegRepresentation(
            of: preview,
            colorSpace: comparisonColorSpace,
            options: [:]
        )
    }

    private func luminance(red: Float, green: Float, blue: Float) -> Float {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }
}

enum ImageDiagnosticsError: LocalizedError {
    case invalidImageData
    case incompatibleImages

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法读取照片诊断信息。"
        case .incompatibleImages:
            return "原图与成片无法进行统一像素比较。"
        }
    }
}
