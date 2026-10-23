import CoreGraphics
import CoreImage
import Foundation

final class QualityCheckService {
    private let analyzer = PhotoAnalyzer()
    private let context = CIContext(options: [.cacheIntermediates: true])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func check(
        originalData: Data,
        editedData: Data,
        sourceAnalysis: PhotoAnalysis? = nil
    ) throws -> QualityCheckResult {
        let originalAnalysis = try analyzer.analyzeImageQuality(data: originalData)
        let editedAnalysis = try analyzer.analyzeImageQuality(data: editedData)
        var issues: [QualityIssue] = []

        guard
            let originalImage = CIImage(data: originalData, options: [.applyOrientationProperty: true]),
            let editedImage = CIImage(data: editedData, options: [.applyOrientationProperty: true])
        else {
            throw QualityValidationError.invalidImageData
        }

        let originalSize = originalImage.extent.integral.size
        let editedSize = editedImage.extent.integral.size
        if abs(originalSize.width - editedSize.width) > 1
            || abs(originalSize.height - editedSize.height) > 1 {
            issues.append(.canvasMismatch)
        }

        if editedAnalysis.averageLuminance < 0.06,
           editedAnalysis.averageLuminance < originalAnalysis.averageLuminance - 0.06 {
            issues.append(.tooDark)
        }

        if editedAnalysis.averageLuminance > 0.82 {
            issues.append(.tooBright)
        }

        if editedAnalysis.contrastRange < 0.24 {
            issues.append(.tooFlat)
        }

        if editedAnalysis.contrastRange > 0.9 {
            issues.append(.tooHarsh)
        }

        if editedAnalysis.highlightRatio > max(0.12, originalAnalysis.highlightRatio + 0.055) {
            issues.append(.clippedHighlights)
        }

        if editedAnalysis.highlightRatio > max(0.08, (originalAnalysis.highlightRatio * 2.2) + 0.025) {
            issues.append(.excessiveHighlightSpread)
        }

        if editedAnalysis.shadowRatio > 0.62,
           editedAnalysis.shadowRatio > originalAnalysis.shadowRatio + 0.08 {
            issues.append(.crushedShadows)
        }

        if editedAnalysis.averageSaturation > 0.62,
           editedAnalysis.averageSaturation > originalAnalysis.averageSaturation + 0.1 {
            issues.append(.oversaturated)
        }

        if editedAnalysis.noiseEstimate > max(0.16, originalAnalysis.noiseEstimate + 0.055) {
            issues.append(.amplifiedNoise)
        }

        if editedAnalysis.detailScore > max(0.42, originalAnalysis.detailScore * 1.75),
           editedAnalysis.noiseEstimate >= originalAnalysis.noiseEstimate {
            issues.append(.overprocessedDetail)
        }

        if editedAnalysis.whiteRatio > max(0.035, originalAnalysis.whiteRatio + 0.025) {
            issues.append(.expandedPureWhite)
        }

        if editedData == originalData {
            issues.append(.possibleRenderFallback)
        }

        let originalCanvas = try canvasStatistics(for: originalImage)
        let editedCanvas = try canvasStatistics(for: editedImage)
        if editedCanvas.nearlyBlackTileRatio > 0.45,
           editedCanvas.nearlyBlackTileRatio > originalCanvas.nearlyBlackTileRatio + 0.22 {
            issues.append(.abnormalBlackCoverage)
        }

        let originalCyanBalance = ((originalAnalysis.greenAverage + originalAnalysis.blueAverage) * 0.5)
            - originalAnalysis.redAverage
        let editedCyanBalance = ((editedAnalysis.greenAverage + editedAnalysis.blueAverage) * 0.5)
            - editedAnalysis.redAverage
        if editedCyanBalance - originalCyanBalance > 0.065 {
            issues.append(.abnormalColorCast)
        }

        if let sourceAnalysis, !sourceAnalysis.faceRegions.isEmpty {
            let integrity = try portraitIntegrity(
                original: originalImage,
                edited: editedImage,
                faceRegions: sourceAnalysis.faceRegions
            )
            if abs(integrity.faceLuminanceShift - integrity.backgroundLuminanceShift) > 0.055
                || integrity.faceColorDifference > integrity.backgroundColorDifference + 0.045 {
                issues.append(.portraitRegionOverAltered)
            }
            if integrity.faceTextureRatio < 0.62 || integrity.faceTextureRatio > 1.65 {
                issues.append(.portraitTextureAltered)
            }
        }

        return QualityCheckResult(
            status: status(for: issues),
            issues: issues,
            measuredAnalysis: editedAnalysis,
            fallbackApplied: false
        )
    }

    private func status(for issues: [QualityIssue]) -> QualityStatus {
        guard !issues.isEmpty else {
            return .passed
        }

        let criticalIssues: Set<QualityIssue> = [
            .tooDark,
            .tooBright,
            .possibleRenderFallback,
            .canvasMismatch,
            .abnormalBlackCoverage,
            .excessiveHighlightSpread,
            .abnormalColorCast,
            .crushedShadows,
            .amplifiedNoise,
            .overprocessedDetail,
            .expandedPureWhite,
            .portraitRegionOverAltered,
            .portraitTextureAltered
        ]
        if issues.contains(where: criticalIssues.contains) {
            return .failed
        }

        return .warning
    }

    private func portraitIntegrity(
        original: CIImage,
        edited: CIImage,
        faceRegions: [NormalizedPhotoRegion]
    ) throws -> PortraitIntegrityMetrics {
        let width = 96
        let height = max(1, Int((CGFloat(width) * original.extent.height / original.extent.width).rounded()))
        let originalPixels = rgbaPixels(from: original, width: width, height: height)
        let editedPixels = rgbaPixels(from: edited, width: width, height: height)
        guard originalPixels.count == editedPixels.count else {
            throw QualityValidationError.invalidImageData
        }

        var faceLuminanceShift: Float = 0
        var backgroundLuminanceShift: Float = 0
        var faceColorDifference: Float = 0
        var backgroundColorDifference: Float = 0
        var faceCount: Float = 0
        var backgroundCount: Float = 0
        var originalTexture: Float = 0
        var editedTexture: Float = 0
        var textureCount: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let normalizedX = (Float(x) + 0.5) / Float(width)
                let normalizedY = (Float(y) + 0.5) / Float(height)
                let isFace = faceRegions.contains {
                    normalizedX >= $0.x && normalizedX <= $0.x + $0.width
                        && normalizedY >= $0.y && normalizedY <= $0.y + $0.height
                }
                let index = ((y * width) + x) * 4
                let originalRGB = rgb(at: index, in: originalPixels)
                let editedRGB = rgb(at: index, in: editedPixels)
                let originalLuminance = luminance(originalRGB)
                let editedLuminance = luminance(editedRGB)
                let colorDifference = chromaDifference(originalRGB, editedRGB)

                if isFace {
                    faceLuminanceShift += editedLuminance - originalLuminance
                    faceColorDifference += colorDifference
                    faceCount += 1
                    if x + 1 < width {
                        let rightIndex = index + 4
                        originalTexture += abs(originalLuminance - luminance(rgb(at: rightIndex, in: originalPixels)))
                        editedTexture += abs(editedLuminance - luminance(rgb(at: rightIndex, in: editedPixels)))
                        textureCount += 1
                    }
                } else {
                    backgroundLuminanceShift += editedLuminance - originalLuminance
                    backgroundColorDifference += colorDifference
                    backgroundCount += 1
                }
            }
        }

        guard faceCount >= 6 else {
            return .neutral
        }
        return PortraitIntegrityMetrics(
            faceLuminanceShift: faceLuminanceShift / faceCount,
            backgroundLuminanceShift: backgroundCount > 0 ? backgroundLuminanceShift / backgroundCount : 0,
            faceColorDifference: faceColorDifference / faceCount,
            backgroundColorDifference: backgroundCount > 0 ? backgroundColorDifference / backgroundCount : 0,
            faceTextureRatio: textureCount > 0 && originalTexture / textureCount > 0.006
                ? (editedTexture / textureCount) / (originalTexture / textureCount)
                : 1
        )
    }

    private func rgbaPixels(from image: CIImage, width: Int, height: Int) -> [UInt8] {
        let canonical = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )
        let scaled = canonical.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / canonical.extent.width,
                y: CGFloat(height) / canonical.extent.height
            )
        )
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )
        return pixels
    }

    private func rgb(at index: Int, in pixels: [UInt8]) -> (Float, Float, Float) {
        (Float(pixels[index]) / 255, Float(pixels[index + 1]) / 255, Float(pixels[index + 2]) / 255)
    }

    private func luminance(_ rgb: (Float, Float, Float)) -> Float {
        (0.2126 * rgb.0) + (0.7152 * rgb.1) + (0.0722 * rgb.2)
    }

    private func chromaDifference(
        _ original: (Float, Float, Float),
        _ edited: (Float, Float, Float)
    ) -> Float {
        let originalLuminance = luminance(original)
        let editedLuminance = luminance(edited)
        return (
            abs((original.0 - originalLuminance) - (edited.0 - editedLuminance))
                + abs((original.2 - originalLuminance) - (edited.2 - editedLuminance))
        ) / 2
    }


    private func canvasStatistics(for image: CIImage) throws -> CanvasStatistics {
        let canonical = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let width = 64
        let height = 64
        let scaled = canonical.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / canonical.extent.width,
                y: CGFloat(height) / canonical.extent.height
            )
        )
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let tileSize = 8
        var blackTiles = 0
        var tileCount = 0
        for tileY in stride(from: 0, to: height, by: tileSize) {
            for tileX in stride(from: 0, to: width, by: tileSize) {
                var luminanceTotal: Float = 0
                var count: Float = 0
                for y in tileY..<min(tileY + tileSize, height) {
                    for x in tileX..<min(tileX + tileSize, width) {
                        let offset = ((y * width) + x) * 4
                        let red = Float(pixels[offset]) / 255
                        let green = Float(pixels[offset + 1]) / 255
                        let blue = Float(pixels[offset + 2]) / 255
                        luminanceTotal += (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                        count += 1
                    }
                }
                if count > 0, luminanceTotal / count < 0.012 {
                    blackTiles += 1
                }
                tileCount += 1
            }
        }
        return CanvasStatistics(
            nearlyBlackTileRatio: tileCount > 0 ? Float(blackTiles) / Float(tileCount) : 0
        )
    }
}

private struct CanvasStatistics {
    let nearlyBlackTileRatio: Float
}

private struct PortraitIntegrityMetrics {
    let faceLuminanceShift: Float
    let backgroundLuminanceShift: Float
    let faceColorDifference: Float
    let backgroundColorDifference: Float
    let faceTextureRatio: Float

    static let neutral = PortraitIntegrityMetrics(
        faceLuminanceShift: 0,
        backgroundLuminanceShift: 0,
        faceColorDifference: 0,
        backgroundColorDifference: 0,
        faceTextureRatio: 1
    )
}

enum QualityValidationError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        "无法解码质量检查所需的原图或成片。"
    }
}

