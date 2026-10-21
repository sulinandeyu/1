import CoreGraphics
import CoreImage
import Foundation

final class QualityCheckService {
    private let analyzer = PhotoAnalyzer()
    private let context = CIContext(options: [.cacheIntermediates: true])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func check(
        originalData: Data,
        editedData: Data
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
            .expandedPureWhite
        ]
        if issues.contains(where: criticalIssues.contains) {
            return .failed
        }

        return .warning
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

enum QualityValidationError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        "无法解码质量检查所需的原图或成片。"
    }
}

