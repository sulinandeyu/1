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
        let neutralColorStatistics = neutralColorStatistics(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            excluding: faceRegions
        )
        let personMask = includeFaceDetection ? generatePersonMask(in: data) : nil
        let salientSubjectMask = includeFaceDetection ? generateSalientSubjectMask(in: data) : nil
        let classification = includeFaceDetection
            ? classifyScene(in: data)
            : SceneClassificationResult(labels: [], diagnostics: .notEvaluated)
        let segmentationOutcome = includeFaceDetection
            ? skySegmentationService.segmentSky(in: data)
            : nil
        let skySegmentation: SkySegmentationResult?
        let segmentationDiagnostics: SceneSegmentationDiagnostics
        switch segmentationOutcome {
        case .success(let result):
            skySegmentation = result
            let coverages = [
                result.mask?.activeCoverage ?? 0,
                result.groundMask?.activeCoverage ?? 0,
                result.vegetationMask?.activeCoverage ?? 0,
                result.waterMask?.activeCoverage ?? 0,
                result.architectureMask?.activeCoverage ?? 0
            ]
            let hasUsableRegion = coverages.contains { $0 >= 0.004 && $0 <= 0.86 }
            segmentationDiagnostics = SceneSegmentationDiagnostics(
                status: hasUsableRegion ? .available : .noUsableRegion,
                reason: hasUsableRegion
                    ? nil
                    : "模型推理成功，但没有通过覆盖率校验的局部区域",
                skyCoverage: result.mask?.activeCoverage ?? 0,
                groundCoverage: result.groundMask?.activeCoverage ?? 0,
                vegetationCoverage: result.vegetationMask?.activeCoverage ?? 0,
                waterCoverage: result.waterMask?.activeCoverage ?? 0,
                architectureCoverage: result.architectureMask?.activeCoverage ?? 0
            )
        case .failure(let reason):
            skySegmentation = nil
            segmentationDiagnostics = SceneSegmentationDiagnostics(
                status: .failed,
                reason: reason,
                skyCoverage: 0,
                groundCoverage: 0,
                vegetationCoverage: 0,
                waterCoverage: 0,
                architectureCoverage: 0
            )
        case nil:
            skySegmentation = nil
            segmentationDiagnostics = .notEvaluated
        }

        let skyStatistics = PhotoRegionStatistics.measure(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            mask: skySegmentation?.mask
        )
        let groundStatistics = PhotoRegionStatistics.measure(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            mask: skySegmentation?.groundMask
        )
        let vegetationStatistics = PhotoRegionStatistics.measure(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            mask: skySegmentation?.vegetationMask
        )
        let waterStatistics = PhotoRegionStatistics.measure(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            mask: skySegmentation?.waterMask
        )
        let architectureStatistics = PhotoRegionStatistics.measure(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            mask: skySegmentation?.architectureMask
        )
        let salientSubjectStatistics = PhotoRegionStatistics.measure(
            rgbaPixels: statistics.rgbaPixels,
            width: statistics.width,
            height: statistics.height,
            mask: salientSubjectMask
        )

        return PhotoAnalysis(
            averageLuminance: statistics.averageLuminance,
            contrastRange: statistics.contrastRange,
            redAverage: statistics.redAverage,
            greenAverage: statistics.greenAverage,
            blueAverage: statistics.blueAverage,
            shadowRatio: statistics.shadowRatio,
            highlightRatio: statistics.highlightRatio,
            averageSaturation: statistics.averageSaturation,
            detailScore: statistics.detailScore,
            noiseEstimate: statistics.noiseEstimate,
            blackRatio: statistics.blackRatio,
            whiteRatio: statistics.whiteRatio,
            midtoneRatio: statistics.midtoneRatio,
            mixedLightScore: statistics.mixedLightScore,
            highlightConcentration: statistics.highlightConcentration,
            highlightSourceCount: statistics.highlightSourceCount,
            highlightCentroidX: statistics.highlightCentroidX,
            highlightCentroidY: statistics.highlightCentroidY,
            spatialLuminanceVariance: statistics.spatialLuminanceVariance,
            faceCount: faceRegions.count,
            faceRegions: faceRegions,
            faceAverageLuminance: regionalTone.faceAverageLuminance,
            backgroundAverageLuminance: regionalTone.backgroundAverageLuminance,
            personMask: personMask,
            salientSubjectMask: salientSubjectMask,
            salientSubjectStatistics: salientSubjectStatistics,
            skinMask: capturedSkinMask?.isValid == true ? capturedSkinMask : nil,
            skyMask: skySegmentation?.mask,
            skyCoverage: skySegmentation?.coverage ?? 0,
            groundMask: skySegmentation?.groundMask,
            vegetationMask: skySegmentation?.vegetationMask,
            waterMask: skySegmentation?.waterMask,
            architectureMask: skySegmentation?.architectureMask,
            skyStatistics: skyStatistics,
            groundStatistics: groundStatistics,
            vegetationStatistics: vegetationStatistics,
            waterStatistics: waterStatistics,
            architectureStatistics: architectureStatistics,
            semanticLabels: classification.labels,
            sceneRecognitionDiagnostics: classification.diagnostics,
            segmentationDiagnostics: segmentationDiagnostics,
            neutralColorStatistics: neutralColorStatistics
        )
    }

    /// Measures low-chroma midtone/bright pixels outside face regions. This is
    /// an evidence source for conservative white-balance diagnosis, not a claim
    /// that every low-chroma surface is physically neutral.
    private func neutralColorStatistics(
        rgbaPixels: [UInt8],
        width: Int,
        height: Int,
        excluding faceRegions: [NormalizedPhotoRegion]
    ) -> NeutralColorStatistics? {
        guard width > 0, height > 0, rgbaPixels.count == width * height * 4 else {
            return nil
        }

        let excludedRegions = faceRegions.map { $0.insetForFaceMetering() }
        var redTotal: Float = 0
        var greenTotal: Float = 0
        var blueTotal: Float = 0
        var luminanceTotal: Float = 0
        var chromaTotal: Float = 0
        var sampleCount = 0
        var occupiedZones = Set<Int>()

        for y in 0..<height {
            let normalizedY = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let normalizedX = (Float(x) + 0.5) / Float(width)
                guard !excludedRegions.contains(where: {
                    $0.contains(x: normalizedX, y: normalizedY)
                }) else { continue }

                let index = ((y * width) + x) * 4
                let red = Float(rgbaPixels[index]) / 255
                let green = Float(rgbaPixels[index + 1]) / 255
                let blue = Float(rgbaPixels[index + 2]) / 255
                let value = luminance(red: red, green: green, blue: blue)
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let chroma = maximum - minimum
                let relativeChroma = maximum > 0 ? chroma / maximum : 0

                // Avoid clipped endpoints, deep noisy shadows and clearly
                // colored surfaces. The two chroma limits admit a moderate cast
                // while rejecting saturated subjects such as fruit or foliage.
                guard value >= 0.18, value <= 0.92 else { continue }
                guard chroma <= 0.12, relativeChroma <= 0.18 else { continue }

                redTotal += red
                greenTotal += green
                blueTotal += blue
                luminanceTotal += value
                chromaTotal += chroma
                sampleCount += 1
                let zoneX = min(2, x * 3 / width)
                let zoneY = min(2, y * 3 / height)
                occupiedZones.insert(zoneY * 3 + zoneX)
            }
        }

        guard sampleCount > 0 else { return nil }
        let totalPixels = Float(width * height)
        let coverage = Float(sampleCount) / totalPixels
        let zoneCoverage = Float(occupiedZones.count) / 9
        let averageChroma = chromaTotal / Float(sampleCount)
        let sampleEvidence = min(1, coverage / 0.08)
        let spatialEvidence = min(1, zoneCoverage / (5.0 / 9.0))
        let lowChromaEvidence = min(1, max(0, (0.10 - averageChroma) / 0.08))
        let confidence = min(
            0.95,
            sampleEvidence * 0.5 + spatialEvidence * 0.3 + lowChromaEvidence * 0.2
        )

        return NeutralColorStatistics(
            sampleCount: sampleCount,
            coverage: coverage,
            spatialZoneCoverage: zoneCoverage,
            redAverage: redTotal / Float(sampleCount),
            greenAverage: greenTotal / Float(sampleCount),
            blueAverage: blueTotal / Float(sampleCount),
            averageLuminance: luminanceTotal / Float(sampleCount),
            averageChroma: averageChroma,
            confidence: confidence
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
        var blackCount = 0
        var whiteCount = 0
        var midtoneCount = 0
        var warmCount = 0
        var coolCount = 0

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
            if pixelLuminance < 0.04 { blackCount += 1 }
            if pixelLuminance > 0.96 { whiteCount += 1 }
            if pixelLuminance >= 0.25 && pixelLuminance <= 0.75 { midtoneCount += 1 }
            if red - blue > 0.10 { warmCount += 1 }
            if blue - red > 0.10 { coolCount += 1 }
        }

        guard !luminances.isEmpty else {
            throw PhotoAnalysisError.analysisFailed
        }

        let sortedLuminances = luminances.sorted()
        let count = Float(luminances.count)
        let lowPercentile = sortedLuminances[Int(Float(sortedLuminances.count - 1) * 0.05)]
        let highPercentile = sortedLuminances[Int(Float(sortedLuminances.count - 1) * 0.95)]
        let neighborhood = neighborhoodQuality(luminances: luminances, width: width, height: height)
        let spatialLight = spatialLightStatistics(luminances: luminances, width: width, height: height)
        let warmRatio = Float(warmCount) / count
        let coolRatio = Float(coolCount) / count

        return PixelStatistics(
            averageLuminance: luminances.reduce(0, +) / count,
            contrastRange: max(0, highPercentile - lowPercentile),
            redAverage: redTotal / count,
            greenAverage: greenTotal / count,
            blueAverage: blueTotal / count,
            shadowRatio: Float(shadowCount) / count,
            highlightRatio: Float(highlightCount) / count,
            averageSaturation: saturationTotal / count,
            detailScore: neighborhood.detail,
            noiseEstimate: neighborhood.noise,
            blackRatio: Float(blackCount) / count,
            whiteRatio: Float(whiteCount) / count,
            midtoneRatio: Float(midtoneCount) / count,
            mixedLightScore: min(warmRatio, coolRatio) * 2,
            highlightConcentration: spatialLight.concentration,
            highlightSourceCount: spatialLight.sourceCount,
            highlightCentroidX: spatialLight.centroidX,
            highlightCentroidY: spatialLight.centroidY,
            spatialLuminanceVariance: spatialLight.zoneVariance,
            width: width,
            height: height,
            luminances: luminances,
            rgbaPixels: pixels
        )
    }

    private func spatialLightStatistics(
        luminances: [Float],
        width: Int,
        height: Int
    ) -> (concentration: Float, sourceCount: Int, centroidX: Float, centroidY: Float, zoneVariance: Float) {
        guard width > 0, height > 0, luminances.count == width * height else {
            return (0, 0, 0.5, 0.5, 0)
        }
        let threshold: Float = 0.88
        var visited = [Bool](repeating: false, count: luminances.count)
        var componentSizes: [Int] = []
        var brightX: Float = 0
        var brightY: Float = 0
        var brightCount = 0
        let neighbors = [(-1, 0), (1, 0), (0, -1), (0, 1)]

        for index in luminances.indices where luminances[index] >= threshold {
            let x = index % width
            let y = index / width
            brightX += (Float(x) + 0.5) / Float(width)
            brightY += (Float(y) + 0.5) / Float(height)
            brightCount += 1
            guard !visited[index] else { continue }
            var queue = [index]
            visited[index] = true
            var cursor = 0
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                let currentX = current % width
                let currentY = current / width
                for (dx, dy) in neighbors {
                    let nx = currentX + dx
                    let ny = currentY + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighbor = ny * width + nx
                    if !visited[neighbor], luminances[neighbor] >= threshold {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }
            if queue.count >= 2 { componentSizes.append(queue.count) }
        }

        var zoneMeans: [Float] = []
        for zoneY in 0..<3 {
            for zoneX in 0..<3 {
                var total: Float = 0
                var count: Float = 0
                let minX = zoneX * width / 3
                let maxX = (zoneX + 1) * width / 3
                let minY = zoneY * height / 3
                let maxY = (zoneY + 1) * height / 3
                for y in minY..<maxY {
                    for x in minX..<maxX {
                        total += luminances[y * width + x]
                        count += 1
                    }
                }
                zoneMeans.append(count > 0 ? total / count : 0)
            }
        }
        let zoneMean = zoneMeans.reduce(0, +) / Float(max(zoneMeans.count, 1))
        let variance = zoneMeans.reduce(Float(0)) { $0 + (($1 - zoneMean) * ($1 - zoneMean)) }
            / Float(max(zoneMeans.count, 1))
        let largest = componentSizes.max() ?? 0
        return (
            brightCount > 0 ? Float(largest) / Float(brightCount) : 0,
            componentSizes.count,
            brightCount > 0 ? brightX / Float(brightCount) : 0.5,
            brightCount > 0 ? brightY / Float(brightCount) : 0.5,
            min(1, variance * 12)
        )
    }

    private func neighborhoodQuality(
        luminances: [Float],
        width: Int,
        height: Int
    ) -> (detail: Float, noise: Float) {
        guard width > 2, height > 2 else { return (0, 0) }
        var edgeTotal: Float = 0
        var residualTotal: Float = 0
        var samples: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let center = luminances[index]
                let horizontal = abs(luminances[index + 1] - luminances[index - 1])
                let vertical = abs(luminances[index + width] - luminances[index - width])
                let neighborMean = (
                    luminances[index - 1] + luminances[index + 1] +
                    luminances[index - width] + luminances[index + width]
                ) * 0.25
                edgeTotal += (horizontal + vertical) * 0.5
                // 仅在非强边缘处估算高频残差，避免把真实轮廓误判为噪点。
                if horizontal + vertical < 0.12 {
                    residualTotal += abs(center - neighborMean)
                }
                samples += 1
            }
        }
        guard samples > 0 else { return (0, 0) }
        return (
            min(1, (edgeTotal / samples) * 6),
            min(1, (residualTotal / samples) * 12)
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

    private func classifyScene(in data: Data) -> SceneClassificationResult {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])

        do {
            try handler.perform([request])
            let labels = (request.results ?? [])
                .filter { $0.confidence >= 0.12 }
                .prefix(8)
                .map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }
            let topConfidence = labels.first?.confidence ?? 0
            let confidenceMass = labels.reduce(0) { $0 + $1.confidence }
            let recognized = topConfidence >= 0.28 || (topConfidence >= 0.18 && confidenceMass >= 0.48)
            return SceneClassificationResult(
                labels: labels,
                diagnostics: SceneRecognitionDiagnostics(
                    status: recognized ? .recognized : .uncertain,
                    topConfidence: topConfidence,
                    acceptedLabelCount: labels.count,
                    reason: recognized
                        ? nil
                        : (labels.isEmpty
                            ? "Vision 未返回达到 0.12 阈值的场景标签"
                            : "Vision 标签置信度不足，禁止把结果宣称为可靠场景识别")
                )
            )
        } catch {
            AppLogger.imageEngine.error("场景语义识别失败：\(error.localizedDescription)")
            return SceneClassificationResult(
                labels: [],
                diagnostics: SceneRecognitionDiagnostics(
                    status: .failed,
                    topConfidence: 0,
                    acceptedLabelCount: 0,
                    reason: "Vision 场景识别失败：\(error.localizedDescription)"
                )
            )
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
            guard let mask = normalizedMask(from: pixelBuffer) else { return nil }
            let coverage = mask.activeCoverage
            guard coverage >= 0.004, coverage <= 0.72 else {
                AppLogger.imageEngine.warning(
                    "显著主体蒙版覆盖率不可靠，已跳过：\(coverage)"
                )
                return nil
            }
            return mask
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

private struct SceneClassificationResult {
    let labels: [SceneLabel]
    let diagnostics: SceneRecognitionDiagnostics
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
    let detailScore: Float
    let noiseEstimate: Float
    let blackRatio: Float
    let whiteRatio: Float
    let midtoneRatio: Float
    let mixedLightScore: Float
    let highlightConcentration: Float
    let highlightSourceCount: Int
    let highlightCentroidX: Float
    let highlightCentroidY: Float
    let spatialLuminanceVariance: Float
    let width: Int
    let height: Int
    let luminances: [Float]
    let rgbaPixels: [UInt8]
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

