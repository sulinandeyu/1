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
        sourceAnalysis: PhotoAnalysis? = nil,
        expectedRegions: [TreatmentRegion] = [],
        regionalExecutionDetails: [String] = []
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

        let processingImpact = compareProcessingImpact(
            original: originalImage,
            edited: editedImage
        )
        let hasPortrait = sourceAnalysis?.faceRegions.isEmpty == false
        let expectsLocalTreatment = expectedRegions.contains {
            ![.global, .person, .background, .subject].contains($0)
        }
        let sourceNeedsVisibleCorrection = sourceAnalysis.map { analysis in
            analysis.exposureProfile != .balanced
                || analysis.contrastProfile != .balanced
                || analysis.highlightRatio > 0.12
                || analysis.shadowRatio > 0.45
                || analysis.averageSaturation > 0.55
                || analysis.noiseEstimate > 0.12
        } ?? false
        // A technically healthy photo is allowed to remain visually close to the
        // original. A stronger minimum is used only when measurements or an actual
        // mask-backed regional plan say that visible intervention is required.
        let requiresVisibleCorrection = sourceNeedsVisibleCorrection || expectsLocalTreatment
        let minimumMeanDifference: Float
        if requiresVisibleCorrection {
            minimumMeanDifference = hasPortrait ? 0.003 : 0.004
        } else {
            minimumMeanDifference = 0.0005
        }
        if processingImpact.normalizedMeanAbsoluteRGBDifference < minimumMeanDifference {
            issues.append(.insufficientProcessingImpact)
        }

        if !expectedSceneRegionsWereExecuted(
            expectedRegions: expectedRegions,
            regionalExecutionDetails: regionalExecutionDetails
        ) {
            issues.append(.missingExpectedSceneTreatment)
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


        if let sourceAnalysis {
            let executedMasks: [(String, NormalizedPhotoMask?)] = [
                ("天空：已执行", sourceAnalysis.skyMask),
                ("地面/道路：已执行", sourceAnalysis.groundMask),
                ("植被：已执行", sourceAnalysis.vegetationMask),
                ("水面：已执行", sourceAnalysis.waterMask),
                ("建筑：已执行", sourceAnalysis.architectureMask)
            ]
            let masks: [NormalizedPhotoMask] = executedMasks.compactMap { item -> NormalizedPhotoMask? in
                let (prefix, mask) = item
                guard regionalExecutionDetails.contains(where: { $0.hasPrefix(prefix) }) else {
                    return nil
                }
                return mask
            }
            let boundaryScore = masks
                .map { maskBoundaryArtifactScore(original: originalImage, edited: editedImage, mask: $0) }
                .max() ?? 0
            if boundaryScore > 0.075 {
                issues.append(.localMaskBoundaryArtifact)
            }
        }

        return QualityCheckResult(
            status: status(for: issues),
            issues: issues,
            measuredAnalysis: editedAnalysis,
            fallbackApplied: false,
            processingImpact: processingImpact
        )
    }

    func measureRegionImpacts(
        originalData: Data,
        editedData: Data,
        analysis: PhotoAnalysis
    ) throws -> [PhotographyRegionImpact] {
        guard
            let original = CIImage(data: originalData, options: [.applyOrientationProperty: true]),
            let edited = CIImage(data: editedData, options: [.applyOrientationProperty: true])
        else {
            throw QualityValidationError.invalidImageData
        }
        let width = 96
        let height = max(1, Int((CGFloat(width) * original.extent.height / original.extent.width).rounded()))
        let originalPixels = rgbaPixels(from: original, width: width, height: height)
        let editedPixels = rgbaPixels(from: edited, width: width, height: height)
        guard originalPixels.count == editedPixels.count, !originalPixels.isEmpty else {
            throw QualityValidationError.invalidImageData
        }

        let regions: [(TreatmentRegion, NormalizedPhotoMask?)] = [
            (.sky, analysis.skyMask),
            (.ground, analysis.groundMask),
            (.vegetation, analysis.vegetationMask),
            (.water, analysis.waterMask),
            (.architecture, analysis.architectureMask),
            (.person, analysis.personMask),
            (.subject, analysis.salientSubjectMask)
        ]
        return regions.compactMap { region, optionalMask in
            guard let mask = optionalMask, mask.isValid else { return nil }
            var luminanceDelta: Float = 0
            var colorDelta: Float = 0
            var contrastDelta: Float = 0
            var contrastCount: Float = 0
            var changed: Float = 0
            var count: Float = 0
            for y in 0..<height {
                for x in 0..<width {
                    let maskX = min(mask.width - 1, max(0, Int(Float(x) / Float(width) * Float(mask.width))))
                    let maskY = min(mask.height - 1, max(0, Int(Float(y) / Float(height) * Float(mask.height))))
                    guard mask.pixels[(maskY * mask.width) + maskX] >= 128 else { continue }
                    let index = ((y * width) + x) * 4
                    let sourceRGB = rgb(at: index, in: originalPixels)
                    let resultRGB = rgb(at: index, in: editedPixels)
                    let sourceLuminance = luminance(sourceRGB)
                    let resultLuminance = luminance(resultRGB)
                    luminanceDelta += resultLuminance - sourceLuminance
                    let difference = chromaDifference(sourceRGB, resultRGB)
                    colorDelta += difference
                    if x + 1 < width {
                        let rightMaskX = min(mask.width - 1, max(0, Int(Float(x + 1) / Float(width) * Float(mask.width))))
                        if mask.pixels[(maskY * mask.width) + rightMaskX] >= 128 {
                            let rightIndex = index + 4
                            let sourceGradient = abs(sourceLuminance - luminance(rgb(at: rightIndex, in: originalPixels)))
                            let resultGradient = abs(resultLuminance - luminance(rgb(at: rightIndex, in: editedPixels)))
                            contrastDelta += resultGradient - sourceGradient
                            contrastCount += 1
                        }
                    }
                    if abs(resultLuminance - sourceLuminance) + difference > (3.0 / 255.0) {
                        changed += 1
                    }
                    count += 1
                }
            }
            guard count >= 4 else { return nil }
            return PhotographyRegionImpact(
                region: region,
                maskCoverage: mask.activeCoverage,
                luminanceDelta: luminanceDelta / count,
                colorDelta: colorDelta / count,
                contrastDelta: contrastCount > 0 ? contrastDelta / contrastCount : 0,
                changedPixelRatio: changed / count
            )
        }
    }

    private func status(for issues: [QualityIssue]) -> QualityStatus {
        guard !issues.isEmpty else {
            return .passed
        }

        let criticalIssues: Set<QualityIssue> = [
            .tooDark,
            .tooBright,
            .possibleRenderFallback,
            .insufficientProcessingImpact,
            .canvasMismatch,
            .abnormalBlackCoverage,
            .excessiveHighlightSpread,
            .abnormalColorCast,
            .crushedShadows,
            .amplifiedNoise,
            .overprocessedDetail,
            .expandedPureWhite,
            .portraitRegionOverAltered,
            .portraitTextureAltered,
            .localMaskBoundaryArtifact,
            .missingExpectedSceneTreatment
        ]
        if issues.contains(where: criticalIssues.contains) {
            return .failed
        }

        return .warning
    }

    private func expectedSceneRegionsWereExecuted(
        expectedRegions: [TreatmentRegion],
        regionalExecutionDetails: [String]
    ) -> Bool {
        let expectedNames = expectedRegions.compactMap { region -> String? in
            switch region {
            case .sky: return "天空：已执行"
            case .ground: return "地面/道路：已执行"
            case .vegetation: return "植被：已执行"
            case .water: return "水面：已执行"
            case .architecture: return "建筑：已执行"
            case .global, .person, .background, .subject: return nil
            }
        }
        return expectedNames.allSatisfy { expected in
            regionalExecutionDetails.contains { $0.hasPrefix(expected) }
        }
    }

    private func maskBoundaryArtifactScore(
        original: CIImage,
        edited: CIImage,
        mask: NormalizedPhotoMask
    ) -> Float {
        guard mask.isValid else { return 0 }
        let width = 96
        let height = max(1, Int((CGFloat(width) * original.extent.height / original.extent.width).rounded()))
        let originalPixels = rgbaPixels(from: original, width: width, height: height)
        let editedPixels = rgbaPixels(from: edited, width: width, height: height)
        guard originalPixels.count == editedPixels.count, !originalPixels.isEmpty else { return 0 }

        func isActive(x: Int, y: Int) -> Bool {
            let maskX = min(mask.width - 1, max(0, Int(Float(x) / Float(width) * Float(mask.width))))
            let maskY = min(mask.height - 1, max(0, Int(Float(y) / Float(height) * Float(mask.height))))
            return mask.pixels[(maskY * mask.width) + maskX] >= 128
        }
        func luminanceDelta(x: Int, y: Int) -> Float {
            let index = ((y * width) + x) * 4
            return luminance(rgb(at: index, in: editedPixels))
                - luminance(rgb(at: index, in: originalPixels))
        }

        var total: Float = 0
        var count: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let active = isActive(x: x, y: y)
                if x + 1 < width, active != isActive(x: x + 1, y: y) {
                    total += abs(luminanceDelta(x: x, y: y) - luminanceDelta(x: x + 1, y: y))
                    count += 1
                }
                if y + 1 < height, active != isActive(x: x, y: y + 1) {
                    total += abs(luminanceDelta(x: x, y: y) - luminanceDelta(x: x, y: y + 1))
                    count += 1
                }
            }
        }
        return count >= 8 ? total / count : 0
    }

    private func compareProcessingImpact(
        original: CIImage,
        edited: CIImage
    ) -> ProcessingImpactMetrics {
        let width = 96
        let height = max(1, Int((CGFloat(width) * original.extent.height / original.extent.width).rounded()))
        let originalPixels = rgbaPixels(from: original, width: width, height: height)
        let editedPixels = rgbaPixels(from: edited, width: width, height: height)
        guard originalPixels.count == editedPixels.count, !originalPixels.isEmpty else {
            return ProcessingImpactMetrics(
                normalizedMeanAbsoluteRGBDifference: 0,
                changedPixelRatio: 0
            )
        }

        var totalDifference: Float = 0
        var changedPixels = 0
        for index in stride(from: 0, to: originalPixels.count, by: 4) {
            let difference = (
                abs(Float(originalPixels[index]) - Float(editedPixels[index]))
                    + abs(Float(originalPixels[index + 1]) - Float(editedPixels[index + 1]))
                    + abs(Float(originalPixels[index + 2]) - Float(editedPixels[index + 2]))
            ) / (3 * 255)
            totalDifference += difference
            if difference > (3.0 / 255.0) {
                changedPixels += 1
            }
        }
        let pixelCount = Float(originalPixels.count / 4)
        return ProcessingImpactMetrics(
            normalizedMeanAbsoluteRGBDifference: totalDifference / pixelCount,
            changedPixelRatio: Float(changedPixels) / pixelCount
        )
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

