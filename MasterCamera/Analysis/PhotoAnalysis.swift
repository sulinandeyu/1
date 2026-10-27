import Foundation

struct PhotoAnalysis: Equatable, Sendable {
    let averageLuminance: Float
    let contrastRange: Float
    let redAverage: Float
    let greenAverage: Float
    let blueAverage: Float
    let shadowRatio: Float
    let highlightRatio: Float
    let averageSaturation: Float
    /// 0...1 的可重复图像质量代理指标；来自低分辨率亮度邻域，不伪装成传感器噪声实测值。
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
    let faceCount: Int
    let faceRegions: [NormalizedPhotoRegion]
    let faceAverageLuminance: Float?
    let backgroundAverageLuminance: Float?
    let personMask: NormalizedPhotoMask?
    let salientSubjectMask: NormalizedPhotoMask?
    let salientSubjectStatistics: PhotoRegionStatistics?
    let skinMask: NormalizedPhotoMask?
    let skyMask: NormalizedPhotoMask?
    let skyCoverage: Float
    let groundMask: NormalizedPhotoMask?
    let vegetationMask: NormalizedPhotoMask?
    let waterMask: NormalizedPhotoMask?
    let architectureMask: NormalizedPhotoMask?
    let skyStatistics: PhotoRegionStatistics?
    let groundStatistics: PhotoRegionStatistics?
    let vegetationStatistics: PhotoRegionStatistics?
    let waterStatistics: PhotoRegionStatistics?
    let architectureStatistics: PhotoRegionStatistics?
    let semanticLabels: [SceneLabel]
    var sceneRecognitionDiagnostics: SceneRecognitionDiagnostics = .notEvaluated
    var segmentationDiagnostics: SceneSegmentationDiagnostics = .notEvaluated
    /// Low-chroma, non-face pixels that may support a conservative illuminant
    /// estimate. A nil or unreliable value means that global RGB averages must
    /// not be presented as white-balance evidence.
    var neutralColorStatistics: NeutralColorStatistics? = nil

    var exposureProfile: ExposureProfile {
        if averageLuminance < 0.32 {
            return .underexposed
        }

        if averageLuminance > 0.72 {
            return .overexposed
        }

        return .balanced
    }

    var contrastProfile: ContrastProfile {
        if contrastRange < 0.34 {
            return .flat
        }

        if contrastRange > 0.78 {
            return .highContrast
        }

        return .balanced
    }

    var colorCast: ColorCast {
        guard let neutral = neutralColorStatistics, neutral.isReliable else {
            return .neutral
        }
        let redBlueDelta = neutral.warmBias
        let greenBalance = neutral.greenBias

        if redBlueDelta > 0.028 {
            return .warm
        }

        if redBlueDelta < -0.028 {
            return .cool
        }

        if greenBalance > 0.022 {
            return .green
        }

        return .neutral
    }

    var containsFaces: Bool {
        faceCount > 0
    }

    var faceToBackgroundLuminanceDelta: Float? {
        guard
            let faceAverageLuminance,
            let backgroundAverageLuminance
        else {
            return nil
        }

        return faceAverageLuminance - backgroundAverageLuminance
    }

    var largestFaceCoverage: Float {
        faceRegions.map { $0.width * $0.height }.max() ?? 0
    }

    var personCoverage: Float {
        personMask?.activeCoverage ?? 0
    }

    var salientSubjectCoverage: Float {
        salientSubjectMask?.activeCoverage ?? 0
    }

    /// Confidence that the generic Vision saliency region is useful as a photographic
    /// priority. This deliberately does not claim object identity (for example fruit).
    var salientSubjectPriorityConfidence: Float {
        guard
            faceCount == 0,
            let mask = salientSubjectMask,
            mask.qualityAssessment.isUsable,
            mask.activeCoverage <= 0.72,
            let statistics = salientSubjectStatistics
        else { return 0 }

        let coverageEvidence = min(1, max(0, (mask.activeCoverage - 0.004) / 0.16))
        let luminanceSeparation = abs(statistics.averageLuminance - averageLuminance)
        let saturationSeparation = abs(statistics.averageSaturation - averageSaturation)
        let contrastEvidence = min(1, max(0, statistics.contrastRange / 0.5))
        let visualEvidence = min(
            1,
            (luminanceSeparation * 3.2)
                + (saturationSeparation * 2.4)
                + (contrastEvidence * 0.28)
        )
        let semanticEvidence = min(1, sceneRecognitionDiagnostics.topConfidence / 0.55)
        let breadthPenalty = min(0.5, max(0, (mask.activeCoverage - 0.48) / 0.24) * 0.5)
        return min(
            0.92,
            max(
                0,
                0.46
                    + coverageEvidence * 0.14
                    + visualEvidence * 0.22
                    + semanticEvidence * 0.1
                    - breadthPenalty
            )
        )
    }

    var subjectPriorityProfile: SubjectPriorityProfile {
        SubjectPriorityProfile.make(from: self)
    }

    /// V7 keeps the legacy single scene for compatibility, while exposing a
    /// multi-label photography context to the actual decision engine.
    var photographyContext: PhotographyContext {
        PhotographyContext.make(from: self)
    }

    var semanticScene: SemanticScene {
        if containsFaces {
            let faceIsBacklit = faceToBackgroundLuminanceDelta.map { $0 < -0.1 } ?? false
            let backgroundIsBright = (backgroundAverageLuminance ?? averageLuminance) > 0.56

            if faceIsBacklit && (backgroundIsBright || highlightRatio > 0.06) {
                return .backlitPortrait
            }
            return .portrait
        }

        let identifiers = semanticLabels.map { $0.identifier.lowercased() }

        if identifiers.containsKeyword(["sunset", "sunrise", "dusk", "twilight"]) {
            return .sunset
        }

        let hasNightLabel = identifiers.containsKeyword(["night", "nighttime"])
        let hasMetricNightEvidence = averageLuminance < 0.27
            || (averageLuminance < 0.36 && shadowRatio > 0.55)
        if hasNightLabel || hasMetricNightEvidence {
            return .night
        }

        if identifiers.containsKeyword([
            "street", "city", "downtown", "road", "traffic", "alley", "urban"
        ]) {
            return .street
        }

        if identifiers.containsKeyword([
            "outdoor", "park", "garden", "field", "daylight", "courtyard"
        ]) {
            return .outdoor
        }

        if identifiers.containsKeyword(["food", "dish", "meal", "cuisine", "dessert", "fruit", "vegetable"] ) {
            return .food
        }

        if identifiers.containsKeyword(["building", "architecture", "skyscraper", "bridge", "church", "house"] ) {
            return .architecture
        }

        if identifiers.containsKeyword(["landscape", "scenery", "mountain", "beach", "seashore", "lake", "forest", "valley", "sky"] ) {
            return .landscape
        }

        if identifiers.containsKeyword([
            "desk", "computer", "keyboard", "monitor", "laptop", "electronics", "office"
        ]) {
            return .workspace
        }

        if identifiers.containsKeyword([
            "indoor", "interior", "room", "living room", "furniture", "couch", "television"
        ]) {
            return .indoor
        }

        return .general
    }

    var traceSummary: String {
        let labels = semanticLabels.map {
            "\($0.identifier)=\(String(format: "%.3f", $0.confidence))"
        }.joined(separator: ",")
        let context = photographyContext
        func regionMetrics(_ name: String, _ statistics: PhotoRegionStatistics?) -> String {
            statistics.map {
                String(format: "%@=l%.3f/c%.3f/s%.3f/h%.3f", name, $0.averageLuminance, $0.contrastRange, $0.averageSaturation, $0.highlightRatio)
            } ?? "\(name)=n/a"
        }
        let regionalMetrics = [
            regionMetrics("subject", salientSubjectStatistics),
            regionMetrics("sky", skyStatistics),
            regionMetrics("ground", groundStatistics),
            regionMetrics("vegetation", vegetationStatistics),
            regionMetrics("water", waterStatistics),
            regionMetrics("architecture", architectureStatistics)
        ].joined(separator: ",")
        let neutralMetrics = neutralColorStatistics?.traceSummary ?? "unavailable"
        let base = String(
            format: "semantic=%@ recognition=%@/%.3f segmentation=%@ labels=[%@] facets=[%@] lighting=[%@] style=%@ luma=%.3f contrast=%.3f shadow=%.3f highlight=%.3f saturation=%.3f rgb=%.3f/%.3f/%.3f neutral=[%@] personCoverage=%.3f faceCoverage=%.3f subjectCoverage=%.3f subjectPriority=%.3f masks=person:%@,subject:%@,skin:%@,sky:%@(%.3f),ground:%@,vegetation:%@,water:%@,architecture:%@ regionMetrics=[%@]",
            semanticScene.rawValue,
            sceneRecognitionDiagnostics.status.rawValue,
            sceneRecognitionDiagnostics.topConfidence,
            segmentationDiagnostics.status.rawValue,
            labels,
            context.sceneFacets.map(\.rawValue).joined(separator: ","),
            context.lightingConditions.map(\.rawValue).joined(separator: ","),
            context.style.rawValue,
            averageLuminance,
            contrastRange,
            shadowRatio,
            highlightRatio,
            averageSaturation,
            redAverage,
            greenAverage,
            blueAverage,
            neutralMetrics,
            personCoverage,
            largestFaceCoverage,
            salientSubjectCoverage,
            salientSubjectPriorityConfidence,
            personMask?.isValid == true ? "yes" : "no",
            salientSubjectMask?.isValid == true ? "yes" : "no",
            skinMask?.isValid == true ? "yes" : "no",
            skyMask?.isValid == true ? "yes" : "no",
            skyCoverage,
            groundMask?.isValid == true ? "yes" : "no",
            vegetationMask?.isValid == true ? "yes" : "no",
            waterMask?.isValid == true ? "yes" : "no",
            architectureMask?.isValid == true ? "yes" : "no",
            regionalMetrics
        )
        return "\(base) sceneProfile=[\(context.sceneProfile.weightSummary)] subjectProfile=[\(subjectPriorityProfile.traceSummary)]"
    }

    static let fallback = PhotoAnalysis(
        averageLuminance: 0.5,
        contrastRange: 0.5,
        redAverage: 0.5,
        greenAverage: 0.5,
        blueAverage: 0.5,
        shadowRatio: 0.0,
        highlightRatio: 0.0,
        averageSaturation: 0.0,
        detailScore: 0.0,
        noiseEstimate: 0.0,
        blackRatio: 0.0,
        whiteRatio: 0.0,
        midtoneRatio: 1.0,
        mixedLightScore: 0.0,
        highlightConcentration: 0.0,
        highlightSourceCount: 0,
        highlightCentroidX: 0.5,
        highlightCentroidY: 0.5,
        spatialLuminanceVariance: 0.0,
        faceCount: 0,
        faceRegions: [],
        faceAverageLuminance: nil,
        backgroundAverageLuminance: nil,
        personMask: nil,
        salientSubjectMask: nil,
        salientSubjectStatistics: nil,
        skinMask: nil,
        skyMask: nil,
        skyCoverage: 0,
        groundMask: nil,
        vegetationMask: nil,
        waterMask: nil,
        architectureMask: nil,
        skyStatistics: nil,
        groundStatistics: nil,
        vegetationStatistics: nil,
        waterStatistics: nil,
        architectureStatistics: nil,
        semanticLabels: []
    )
}

/// Evidence for a possible neutral reference in the current rendered image.
/// This is deliberately not called an illuminant estimate: low-chroma image
/// pixels are only a conservative clue, and the confidence must be respected.
struct NeutralColorStatistics: Equatable, Sendable {
    let sampleCount: Int
    let coverage: Float
    let spatialZoneCoverage: Float
    let redAverage: Float
    let greenAverage: Float
    let blueAverage: Float
    let averageLuminance: Float
    let averageChroma: Float
    let confidence: Float

    var warmBias: Float { redAverage - blueAverage }
    var greenBias: Float { greenAverage - ((redAverage + blueAverage) * 0.5) }

    var isReliable: Bool {
        sampleCount >= 24
            && coverage >= 0.015
            && spatialZoneCoverage >= (2.0 / 9.0)
            && confidence >= 0.5
    }

    var traceSummary: String {
        String(
            format: "samples=%d coverage=%.3f zones=%.3f rgb=%.3f/%.3f/%.3f luma=%.3f chroma=%.3f warm=%+.3f green=%+.3f confidence=%.3f reliable=%@",
            sampleCount,
            coverage,
            spatialZoneCoverage,
            redAverage,
            greenAverage,
            blueAverage,
            averageLuminance,
            averageChroma,
            warmBias,
            greenBias,
            confidence,
            isReliable ? "yes" : "no"
        )
    }
}

struct PhotoRegionStatistics: Equatable, Sendable {
    let averageLuminance: Float
    let contrastRange: Float
    let redAverage: Float
    let greenAverage: Float
    let blueAverage: Float
    let averageSaturation: Float
    let shadowRatio: Float
    let highlightRatio: Float

    var blueBias: Float { blueAverage - redAverage }
    var warmBias: Float { redAverage - blueAverage }

    static func measure(
        rgbaPixels: [UInt8],
        width: Int,
        height: Int,
        mask: NormalizedPhotoMask?
    ) -> PhotoRegionStatistics? {
        guard
            let mask,
            mask.isValid,
            width > 0,
            height > 0,
            rgbaPixels.count == width * height * 4
        else { return nil }

        var luminances: [Float] = []
        var redTotal: Float = 0
        var greenTotal: Float = 0
        var blueTotal: Float = 0
        var saturationTotal: Float = 0
        var shadowCount = 0
        var highlightCount = 0

        for y in 0..<height {
            let maskY = min(mask.height - 1, Int(Float(y) / Float(height) * Float(mask.height)))
            for x in 0..<width {
                let maskX = min(mask.width - 1, Int(Float(x) / Float(width) * Float(mask.width)))
                guard mask.pixels[(maskY * mask.width) + maskX] >= 32 else { continue }

                let index = ((y * width) + x) * 4
                let red = Float(rgbaPixels[index]) / 255
                let green = Float(rgbaPixels[index + 1]) / 255
                let blue = Float(rgbaPixels[index + 2]) / 255
                let value = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)

                redTotal += red
                greenTotal += green
                blueTotal += blue
                saturationTotal += maximum > 0 ? (maximum - minimum) / maximum : 0
                luminances.append(value)
                if value < 0.18 { shadowCount += 1 }
                if value > 0.85 { highlightCount += 1 }
            }
        }

        guard luminances.count >= 12 else { return nil }
        let sorted = luminances.sorted()
        let count = Float(luminances.count)
        let low = sorted[Int(Float(sorted.count - 1) * 0.05)]
        let high = sorted[Int(Float(sorted.count - 1) * 0.95)]
        return PhotoRegionStatistics(
            averageLuminance: luminances.reduce(0, +) / count,
            contrastRange: max(0, high - low),
            redAverage: redTotal / count,
            greenAverage: greenTotal / count,
            blueAverage: blueTotal / count,
            averageSaturation: saturationTotal / count,
            shadowRatio: Float(shadowCount) / count,
            highlightRatio: Float(highlightCount) / count
        )
    }
}

struct NormalizedPhotoMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    var isValid: Bool {
        width > 0 && height > 0 && pixels.count == width * height
    }

    var activeCoverage: Float {
        guard isValid, !pixels.isEmpty else { return 0 }
        let active = pixels.reduce(into: 0) { count, value in
            if value >= 32 { count += 1 }
        }
        return Float(active) / Float(pixels.count)
    }

    var qualityAssessment: PhotoMaskQualityAssessment {
        guard isValid, !pixels.isEmpty else {
            return PhotoMaskQualityAssessment(
                coverage: 0,
                softEdgeRatio: 0,
                boundaryDensity: 1,
                reliability: 0,
                isUsable: false,
                reason: "蒙版尺寸或像素数据无效"
            )
        }
        let coverage = activeCoverage
        var activeCount = 0
        var softCount = 0
        var boundaryCount = 0
        var adjacencyCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let value = pixels[(y * width) + x]
                let active = value >= 32
                if active {
                    activeCount += 1
                    if value < 224 { softCount += 1 }
                }
                if x + 1 < width {
                    adjacencyCount += 1
                    if active != (pixels[(y * width) + x + 1] >= 32) { boundaryCount += 1 }
                }
                if y + 1 < height {
                    adjacencyCount += 1
                    if active != (pixels[((y + 1) * width) + x] >= 32) { boundaryCount += 1 }
                }
            }
        }
        let softEdgeRatio = activeCount > 0 ? Float(softCount) / Float(activeCount) : 0
        let boundaryDensity = adjacencyCount > 0 ? Float(boundaryCount) / Float(adjacencyCount) : 0
        let coverageReliability: Float
        if coverage < 0.004 || coverage > 0.86 {
            coverageReliability = 0
        } else if coverage < 0.015 || coverage > 0.8 {
            coverageReliability = 0.58
        } else {
            coverageReliability = 0.94
        }
        let fragmentationReliability: Float = width * height < 64
            ? 1
            : max(0.5, 1 - max(0, boundaryDensity - 0.38) * 1.25)
        let edgeReliability = min(1, 0.92 + softEdgeRatio * 0.08)
        let reliability = coverageReliability * fragmentationReliability * edgeReliability
        let usable = reliability >= 0.42
        let reason: String
        if coverageReliability == 0 {
            reason = String(format: "覆盖率 %.2f%% 超出安全范围", coverage * 100)
        } else if fragmentationReliability < 0.72 {
            reason = String(format: "边界密度 %.1f%%，存在碎片或误伤风险", boundaryDensity * 100)
        } else {
            reason = "覆盖率与边界结构可用于有边界的局部调整"
        }
        return PhotoMaskQualityAssessment(
            coverage: coverage,
            softEdgeRatio: softEdgeRatio,
            boundaryDensity: boundaryDensity,
            reliability: reliability,
            isUsable: usable,
            reason: reason
        )
    }

    func activeCoverage(excluding exclusions: [NormalizedPhotoMask]) -> Float {
        guard isValid else { return 0 }
        var remaining = 0
        for y in 0..<height {
            for x in 0..<width {
                guard pixels[(y * width) + x] >= 32 else { continue }
                let excluded = exclusions.contains { exclusion in
                    guard exclusion.isValid else { return false }
                    let exclusionX = min(
                        exclusion.width - 1,
                        Int(Float(x) / Float(width) * Float(exclusion.width))
                    )
                    let exclusionY = min(
                        exclusion.height - 1,
                        Int(Float(y) / Float(height) * Float(exclusion.height))
                    )
                    return exclusion.pixels[(exclusionY * exclusion.width) + exclusionX] >= 32
                }
                if !excluded { remaining += 1 }
            }
        }
        return Float(remaining) / Float(width * height)
    }

    func inverted() -> NormalizedPhotoMask? {
        guard isValid else { return nil }
        return NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(pixels.map { 255 - $0 })
        )
    }
}

struct PhotoMaskQualityAssessment: Equatable, Sendable {
    let coverage: Float
    let softEdgeRatio: Float
    let boundaryDensity: Float
    let reliability: Float
    let isUsable: Bool
    let reason: String

    var traceSummary: String {
        String(
            format: "coverage=%.3f softEdge=%.3f boundary=%.3f reliability=%.3f usable=%@ reason=%@",
            coverage,
            softEdgeRatio,
            boundaryDensity,
            reliability,
            isUsable ? "yes" : "no",
            reason
        )
    }
}

enum SubjectPriorityMode: String, Equatable, Sendable {
    case primarySubject
    case globalHarmony
}

struct SubjectMaskLayer: Equatable, Sendable {
    let role: String
    let mask: NormalizedPhotoMask
    let confidence: Float
    let reason: String
}

/// Describes which reliable masks may receive visual priority. It intentionally
/// does not invent object identity when Vision only supplied generic saliency.
struct SubjectPriorityProfile: Equatable, Sendable {
    let mode: SubjectPriorityMode
    let primarySubjectMask: NormalizedPhotoMask?
    let secondarySubjectMasks: [SubjectMaskLayer]
    let backgroundMask: NormalizedPhotoMask?
    let lowPriorityDistractorMasks: [SubjectMaskLayer]
    let confidence: Float
    let typeDescription: String
    let evidence: String

    var traceSummary: String {
        let secondary = secondarySubjectMasks.map { "\($0.role)=\(Int(($0.confidence * 100).rounded()))%" }.joined(separator: ",")
        let distractors = lowPriorityDistractorMasks.map { "\($0.role)=\(Int(($0.confidence * 100).rounded()))%" }.joined(separator: ",")
        return String(
            format: "mode=%@ primary=%@ confidence=%.3f type=%@ secondary=[%@] background=%@ lowPriority=[%@] evidence=%@",
            mode.rawValue,
            primarySubjectMask?.isValid == true ? "yes" : "no",
            confidence,
            typeDescription,
            secondary,
            backgroundMask?.isValid == true ? "yes" : "no",
            distractors,
            evidence
        )
    }

    static func make(from analysis: PhotoAnalysis) -> SubjectPriorityProfile {
        let hasProtectedPerson = analysis.faceCount > 0 && analysis.personMask?.isValid == true
        let confidence: Float = hasProtectedPerson ? 0.92 : analysis.salientSubjectPriorityConfidence
        let primary = hasProtectedPerson
            ? analysis.personMask
            : (confidence >= 0.54 ? analysis.salientSubjectMask : nil)
        let labels = analysis.semanticLabels.map { $0.identifier.lowercased() }
        let type: String
        if analysis.faceCount > 0 {
            type = "人物（由人物保护链处理）"
        } else if labels.containsKeyword(["food", "fruit", "produce"]) {
            type = "食物/果实语义与视觉显著区域"
        } else if labels.containsKeyword(["animal", "pet", "cat", "dog", "bird"]) {
            type = "动物语义与视觉显著区域"
        } else if primary != nil {
            type = "通用视觉显著区域（未推断具体物体身份）"
        } else {
            type = "无可靠单一主体"
        }

        var secondary: [SubjectMaskLayer] = []
        if let vegetation = analysis.vegetationMask, vegetation.qualityAssessment.isUsable {
            secondary.append(SubjectMaskLayer(
                role: "vegetation",
                mask: vegetation,
                confidence: min(0.9, max(0.45, vegetation.activeCoverage * 1.4)),
                reason: "植被构成主体环境或画面结构。"
            ))
        }
        if let ground = analysis.groundMask, ground.qualityAssessment.isUsable {
            secondary.append(SubjectMaskLayer(
                role: "ground/road",
                mask: ground,
                confidence: min(0.82, max(0.38, ground.activeCoverage * 1.2)),
                reason: "地面可承担空间引导，但不自动视为主要主体。"
            ))
        }

        var distractors: [SubjectMaskLayer] = []
        if let architecture = analysis.architectureMask,
           architecture.qualityAssessment.isUsable,
           architecture.activeCoverage < 0.12,
           primary != nil {
            distractors.append(SubjectMaskLayer(
                role: "minorArchitecture",
                mask: architecture,
                confidence: min(0.8, 1 - architecture.activeCoverage * 2),
                reason: "建筑覆盖较小且不是显著主体，只作为低优先级背景处理。"
            ))
        }

        return SubjectPriorityProfile(
            mode: primary == nil ? .globalHarmony : .primarySubject,
            primarySubjectMask: primary,
            secondarySubjectMasks: secondary,
            backgroundMask: primary?.inverted(),
            lowPriorityDistractorMasks: distractors,
            confidence: confidence,
            typeDescription: type,
            evidence: primary == nil
                ? "显著性覆盖或区域分离证据不足，明确进入整图协调模式。"
                : "Vision 显著性、覆盖范围、区域亮度/色彩分离与细节共同达到执行阈值。"
        )
    }
}

struct SceneLabel: Equatable, Sendable {
    let identifier: String
    let confidence: Float
}

enum SceneRecognitionStatus: String, Equatable, Sendable {
    case recognized
    case uncertain
    case failed
    case notEvaluated
}

struct SceneRecognitionDiagnostics: Equatable, Sendable {
    let status: SceneRecognitionStatus
    let topConfidence: Float
    let acceptedLabelCount: Int
    let reason: String?

    static let notEvaluated = SceneRecognitionDiagnostics(
        status: .notEvaluated,
        topConfidence: 0,
        acceptedLabelCount: 0,
        reason: "未请求场景识别"
    )
}

enum SceneSegmentationStatus: String, Equatable, Sendable {
    case available
    case noUsableRegion
    case failed
    case notEvaluated
}

struct SceneSegmentationDiagnostics: Equatable, Sendable {
    let status: SceneSegmentationStatus
    let reason: String?
    let skyCoverage: Float
    let groundCoverage: Float
    let vegetationCoverage: Float
    let waterCoverage: Float
    let architectureCoverage: Float

    static let notEvaluated = SceneSegmentationDiagnostics(
        status: .notEvaluated,
        reason: "未请求场景分割",
        skyCoverage: 0,
        groundCoverage: 0,
        vegetationCoverage: 0,
        waterCoverage: 0,
        architectureCoverage: 0
    )
}

enum SemanticScene: String, Equatable, Sendable {
    case portrait
    case backlitPortrait
    case landscape
    case night
    case street
    case outdoor
    case food
    case architecture
    case sunset
    case indoor
    case workspace
    case general
}

struct NormalizedPhotoRegion: Equatable, Sendable {
    let x: Float
    let y: Float
    let width: Float
    let height: Float

    var centerX: Float {
        x + (width * 0.5)
    }

    var centerY: Float {
        y + (height * 0.5)
    }

    var longestSide: Float {
        max(width, height)
    }
}

enum ExposureProfile: String, Equatable, Sendable {
    case underexposed
    case balanced
    case overexposed
}

enum ContrastProfile: String, Equatable, Sendable {
    case flat
    case balanced
    case highContrast
}

enum ColorCast: String, Equatable, Sendable {
    case cool
    case neutral
    case warm
    case green
}

enum SceneFacet: String, Hashable, Sendable {
    case nature, sky, mountain, water, coast, forest, countryRoad
    case city, architecture, street, interior, nightCity
    case portrait, groupPortrait, stillLife, pet, food, vehicle, workspace, other
}

enum LightingCondition: String, Hashable, Sendable {
    case sunrise, morning, midday, afternoon, goldenHour, blueHour, dusk, night
    case indoorNatural, indoorArtificial, mixed, backlit, sideLit, frontLit, topLit, overcast
}

enum LightDirection: String, Equatable, Sendable {
    case left, right, top, bottom, centered, diffuse, unknown
}

enum PhotographyStyle: String, Equatable, Sendable {
    case naturalDocumentary
    case professionalLandscape
    case urbanArchitecture
    case blueHour
    case goldenHour
    case lifestyle
    case commercialPortrait
    case environmentalPortrait
    case interiorAtmosphere
    case stillLife
}

/// Weighted description of what the photograph contains and how it is lit.
///
/// This deliberately keeps several simultaneous signals instead of turning the
/// first valid semantic mask into one exclusive scene label. Region values are
/// evidence weights, not claims that a specific object was recognized.
struct SceneProfile: Equatable, Sendable {
    let indoor: Float
    let outdoor: Float
    let rural: Float
    let urban: Float
    let overcast: Float
    let sunny: Float
    let goldenHour: Float
    let dusk: Float
    let night: Float
    let mixedLight: Float
    let vegetationDominant: Float
    let skyPresence: Float
    let groundOrRoadPresence: Float
    let architecturePresence: Float
    let waterPresence: Float
    let portraitPresence: Float
    let animalPresence: Float
    let foodOrFruitPresence: Float
    let documentaryTendency: Float
    let lifestyleTendency: Float
    let cinematicTendency: Float
    let cozyTendency: Float
    let commercialTendency: Float
    let naturalDocumentaryTendency: Float
    let landscapeTendency: Float
    let urbanArchitectureTendency: Float
    let overallContrastCondition: ContrastProfile
    let lightingSoftness: Float
    let colorTemperatureTrend: ColorCast

    var weightSummary: String {
        String(
            format: "environment indoor=%.2f outdoor=%.2f rural=%.2f urban=%.2f; light overcast=%.2f sunny=%.2f golden=%.2f dusk=%.2f night=%.2f mixed=%.2f softness=%.2f; regions vegetation=%.2f sky=%.2f ground=%.2f architecture=%.2f water=%.2f portrait=%.2f animal=%.2f foodOrFruit=%.2f; tendencies documentary=%.2f lifestyle=%.2f cinematic=%.2f cozy=%.2f commercial=%.2f naturalDocumentary=%.2f landscape=%.2f urbanArchitecture=%.2f; contrast=%@ temperature=%@",
            indoor,
            outdoor,
            rural,
            urban,
            overcast,
            sunny,
            goldenHour,
            dusk,
            night,
            mixedLight,
            lightingSoftness,
            vegetationDominant,
            skyPresence,
            groundOrRoadPresence,
            architecturePresence,
            waterPresence,
            portraitPresence,
            animalPresence,
            foodOrFruitPresence,
            documentaryTendency,
            lifestyleTendency,
            cinematicTendency,
            cozyTendency,
            commercialTendency,
            naturalDocumentaryTendency,
            landscapeTendency,
            urbanArchitectureTendency,
            overallContrastCondition.rawValue,
            colorTemperatureTrend.rawValue
        )
    }
}

struct PhotographyContext: Equatable, Sendable {
    let sceneFacets: [SceneFacet]
    let lightingConditions: [LightingCondition]
    let lightDirection: LightDirection
    let sceneProfile: SceneProfile
    let style: PhotographyStyle
    let styleReason: String
    let primarySubjectConfidence: Float
    let spatialDepthScore: Float
    let atmosphereScore: Float

    static func make(from analysis: PhotoAnalysis) -> PhotographyContext {
        let labels = analysis.semanticLabels.map { $0.identifier.lowercased() }
        var facets = Set<SceneFacet>()
        var lighting = Set<LightingCondition>()

        if analysis.faceCount > 0 {
            facets.insert(analysis.faceCount > 1 ? .groupPortrait : .portrait)
        }
        if analysis.skyCoverage > 0.03 || labels.containsKeyword(["sky", "cloud"]) { facets.insert(.sky) }
        // These facets come only from the bundled semantic model's validated masks.
        // They are stronger evidence than color thresholds, but still do not claim a
        // more specific object such as "forest" or "road" without classifier support.
        if analysis.vegetationMask?.qualityAssessment.isUsable == true { facets.insert(.nature) }
        if analysis.waterMask?.qualityAssessment.isUsable == true { facets.insert(.water) }
        if analysis.architectureMask?.qualityAssessment.isUsable == true { facets.insert(.architecture) }
        if labels.containsKeyword(["nature", "landscape", "field", "scenery", "park"]) { facets.insert(.nature) }
        if labels.containsKeyword(["mountain", "hill", "valley"]) { facets.insert(.mountain) }
        if labels.containsKeyword(["water", "lake", "river", "ocean", "sea"]) { facets.insert(.water) }
        if labels.containsKeyword(["coast", "beach", "seashore"]) { facets.insert(.coast) }
        if labels.containsKeyword(["forest", "woodland", "tree"]) { facets.insert(.forest) }
        if labels.containsKeyword(["trail", "country road", "path"]) { facets.insert(.countryRoad) }
        if labels.containsKeyword(["city", "urban", "downtown", "skyline"]) { facets.insert(.city) }
        if labels.containsKeyword(["building", "architecture", "bridge", "skyscraper", "house"]) { facets.insert(.architecture) }
        if labels.containsKeyword(["street", "road", "alley", "traffic"]) { facets.insert(.street) }
        if labels.containsKeyword(["indoor", "interior", "room", "bedroom", "living room", "furniture"]) { facets.insert(.interior) }
        if labels.containsKeyword(["food", "dish", "meal", "dessert"]) { facets.insert(.food) }
        if labels.containsKeyword(["desk", "computer", "keyboard", "monitor", "laptop", "office"]) { facets.insert(.workspace) }
        if labels.containsKeyword(["still life", "product", "object"]) { facets.insert(.stillLife) }
        if labels.containsKeyword(["cat", "dog", "pet", "animal"]) { facets.insert(.pet) }
        if labels.containsKeyword(["car", "vehicle", "motorcycle", "bicycle"]) { facets.insert(.vehicle) }

        let hasNightLabel = labels.containsKeyword(["night", "nighttime"])
        let hasMetricNightEvidence = analysis.averageLuminance < 0.27
            || (analysis.averageLuminance < 0.36 && analysis.shadowRatio > 0.55)
        let looksNight = hasNightLabel || hasMetricNightEvidence
        if looksNight {
            lighting.insert(.night)
            if facets.contains(.city) || facets.contains(.street) || facets.contains(.architecture) { facets.insert(.nightCity) }
        }
        if labels.containsKeyword(["sunrise", "dawn"]) { lighting.insert(.sunrise) }
        if labels.containsKeyword(["sunset", "dusk", "twilight"]) { lighting.insert(.dusk) }

        let skyLuminance = analysis.skyStatistics?.averageLuminance ?? analysis.averageLuminance
        let blueBias = analysis.skyStatistics?.blueBias ?? (analysis.blueAverage - analysis.redAverage)
        let warmBias = analysis.skyStatistics?.warmBias ?? (analysis.redAverage - analysis.blueAverage)
        let hasBlueHourLabel = labels.containsKeyword(["blue hour", "twilight", "dusk", "evening"])
        let hasMetricBlueHourEvidence = analysis.averageLuminance < 0.38
            && analysis.shadowRatio > 0.20
            && skyLuminance < 0.58
            && blueBias > 0.035
        if analysis.skyCoverage > 0.08 && (hasBlueHourLabel || hasMetricBlueHourEvidence) {
            lighting.insert(.blueHour)
        }
        if analysis.skyCoverage > 0.05 && warmBias > 0.045 && analysis.whiteRatio < 0.12 {
            lighting.insert(.goldenHour)
        }
        if analysis.mixedLightScore > 0.18 { lighting.insert(.mixed) }
        if analysis.faceToBackgroundLuminanceDelta.map({ $0 < -0.1 }) == true || labels.containsKeyword(["backlit", "backlight"]) {
            lighting.insert(.backlit)
        }
        if facets.contains(.interior) {
            lighting.insert(analysis.highlightSourceCount > 0 ? .indoorArtificial : .indoorNatural)
        }
        if labels.containsKeyword(["overcast", "cloudy"])
            || (facets.contains(.sky) && analysis.averageSaturation < 0.22 && analysis.contrastRange < 0.5) {
            lighting.insert(.overcast)
        }
        if facets.contains(.sky), !lighting.contains(.blueHour), !lighting.contains(.goldenHour),
           (analysis.averageLuminance >= 0.42 || skyLuminance >= 0.55) {
            lighting.insert(.midday)
        }
        if lighting.isEmpty { lighting.insert(.frontLit) }

        let direction: LightDirection
        if analysis.highlightSourceCount == 0 || analysis.highlightConcentration < 0.08 {
            direction = analysis.spatialLuminanceVariance < 0.05 ? .diffuse : .unknown
        } else if analysis.highlightCentroidY > 0.7 {
            direction = .top
        } else if analysis.highlightCentroidY < 0.3 {
            direction = .bottom
        } else if analysis.highlightCentroidX < 0.38 {
            direction = .left
        } else if analysis.highlightCentroidX > 0.62 {
            direction = .right
        } else {
            direction = .centered
        }

        let semanticConfidence: ([String]) -> Float = { keywords in
            analysis.semanticLabels
                .filter { label in
                    let identifier = label.identifier.lowercased()
                    return keywords.contains { identifier.contains($0) }
                }
                .map(\.confidence)
                .max() ?? 0
        }
        let skyPresence = max(analysis.skyCoverage, semanticConfidence(["sky", "cloud"]) * 0.75)
        let vegetationCoverage = analysis.vegetationMask?.activeCoverage ?? 0
        let groundCoverage = analysis.groundMask?.activeCoverage ?? 0
        let architectureCoverage = analysis.architectureMask?.activeCoverage ?? 0
        let waterCoverage = analysis.waterMask?.activeCoverage ?? 0
        let indoorWeight = semanticConfidence(["indoor", "interior", "room", "bedroom", "living room"])
        let outdoorWeight = max(
            semanticConfidence(["outdoor", "landscape", "nature", "garden", "park", "field"]),
            min(1, skyPresence + vegetationCoverage * 0.7 + groundCoverage * 0.25)
        )
        let explicitUrban = semanticConfidence(["city", "urban", "downtown", "skyline", "street", "traffic", "architecture", "building", "bridge", "skyscraper"])
        let architectureDominance = architectureCoverage >= 0.12
            && architectureCoverage >= max(0.08, vegetationCoverage * 0.45)
        let urbanWeight = max(
            explicitUrban,
            architectureDominance ? min(0.82, architectureCoverage * 1.8) : architectureCoverage * 0.55
        )
        let landscapeSemantic = semanticConfidence(["nature", "landscape", "field", "scenery", "park", "mountain", "valley"])
        let vegetationSemantic = semanticConfidence(["forest", "woodland", "tree", "plant", "garden", "vegetation"])
        let natureSemantic = max(landscapeSemantic, vegetationSemantic)
        let vegetationWeight = min(1, max(vegetationCoverage, vegetationSemantic * 0.82))
        let ruralSemantic = semanticConfidence(["rural", "country", "farm", "orchard", "village", "countryside"])
        let ruralWeight = max(
            ruralSemantic,
            min(0.78, outdoorWeight * vegetationWeight * (1 - urbanWeight) * 0.92)
        )
        let portraitWeight: Float = analysis.faceCount > 0
            ? min(1, 0.78 + analysis.largestFaceCoverage)
            : semanticConfidence(["portrait", "person", "people"])
        let animalWeight = semanticConfidence(["animal", "pet", "cat", "dog", "bird"])
        let foodFruitWeight = semanticConfidence(["food", "fruit", "dish", "meal", "dessert", "produce"])
        let overcastWeight = max(
            semanticConfidence(["overcast", "cloudy"]),
            lighting.contains(.overcast) ? min(0.9, 0.55 + skyPresence * 0.35) : 0
        )
        let sunnyWeight = max(
            semanticConfidence(["sunny", "sunlight", "clear sky"]),
            analysis.highlightConcentration > 0.22 && overcastWeight < 0.35 ? 0.55 : 0
        )
        let goldenWeight: Float = lighting.contains(.goldenHour) || lighting.contains(.sunrise) ? 0.9 : 0
        let duskWeight: Float = lighting.contains(.dusk) || lighting.contains(.blueHour) ? 0.9 : 0
        let nightWeight: Float = lighting.contains(.night) ? 0.95 : 0
        let mixedWeight = max(analysis.mixedLightScore, lighting.contains(.mixed) ? 0.7 : 0)
        let subjectPriority = analysis.salientSubjectPriorityConfidence
        let naturalDocumentaryWeight = min(
            1,
            max(
                ruralWeight,
                vegetationWeight * 0.58 + subjectPriority * 0.3 + outdoorWeight * 0.12
            )
        )
        let landscapeWeight = min(
            1,
            max(
                landscapeSemantic,
                vegetationWeight * 0.62 + skyPresence * 0.22 + waterCoverage * 0.22
            )
        )
        let urbanStyleWeight = min(1, urbanWeight * 0.82 + architectureCoverage * 0.18)
        let lightingSoftness = min(
            1,
            max(overcastWeight, 1 - analysis.highlightConcentration * 1.6 - analysis.spatialLuminanceVariance)
        )
        let sceneProfile = SceneProfile(
            indoor: indoorWeight,
            outdoor: outdoorWeight,
            rural: ruralWeight,
            urban: urbanWeight,
            overcast: overcastWeight,
            sunny: sunnyWeight,
            goldenHour: goldenWeight,
            dusk: duskWeight,
            night: nightWeight,
            mixedLight: mixedWeight,
            vegetationDominant: vegetationWeight,
            skyPresence: skyPresence,
            groundOrRoadPresence: groundCoverage,
            architecturePresence: architectureCoverage,
            waterPresence: waterCoverage,
            portraitPresence: portraitWeight,
            animalPresence: animalWeight,
            foodOrFruitPresence: foodFruitWeight,
            documentaryTendency: max(ruralWeight, outdoorWeight * 0.55),
            lifestyleTendency: max(indoorWeight * 0.72, portraitWeight * 0.45),
            cinematicTendency: min(
                1,
                nightWeight * 0.65
                    + duskWeight * 0.45
                    + analysis.highlightConcentration * 0.18
                    + analysis.mixedLightScore * 0.2
            ),
            cozyTendency: min(1, indoorWeight * max(0, analysis.redAverage - analysis.blueAverage + 0.12) * 2.8),
            commercialTendency: max(foodFruitWeight * 0.72, portraitWeight * 0.55),
            naturalDocumentaryTendency: naturalDocumentaryWeight,
            landscapeTendency: landscapeWeight,
            urbanArchitectureTendency: urbanStyleWeight,
            overallContrastCondition: analysis.contrastProfile,
            lightingSoftness: lightingSoftness,
            colorTemperatureTrend: analysis.colorCast
        )

        let style: PhotographyStyle
        let reason: String
        if lighting.contains(.blueHour) {
            style = .blueHour; reason = "天空占比与实测冷色关系符合蓝调时刻，保留环境冷色而不全局染蓝。"
        } else if lighting.contains(.goldenHour) || lighting.contains(.sunrise) || lighting.contains(.dusk) {
            style = .goldenHour; reason = "天空暖色与高光余量支持暖调摄影，重点保护暖色渐变。"
        } else if facets.contains(.portrait) || facets.contains(.groupPortrait) {
            if facets.contains(.nature) || facets.contains(.city) || facets.contains(.street) {
                style = .environmentalPortrait; reason = "人物与环境同时构成画面，需要保护身份、肤色和现场光关系。"
            } else {
                style = .commercialPortrait; reason = "人物是主要主体，优先稳定肤色、受光与皮肤纹理。"
            }
        } else if facets.contains(.interior) || facets.contains(.workspace) {
            style = .interiorAtmosphere; reason = "室内空间与混合光决定观感，控制灯具高光并保留材质。"
        } else if facets.contains(.stillLife) || facets.contains(.food) {
            style = .stillLife; reason = "静物需要保护材质、反光和主体颜色，避免统一风格覆盖。"
        } else if sceneProfile.urbanArchitectureTendency >= max(
            0.52,
            max(
                sceneProfile.landscapeTendency + 0.08,
                sceneProfile.naturalDocumentaryTendency + 0.08
            )
        ) {
            style = .urbanArchitecture
            reason = String(
                format: "城市/建筑加权 %.0f%% 高于自然 %.0f%% 与纪实 %.0f%%；建筑覆盖 %.1f%%，不是仅因蒙版存在就判为城市。",
                sceneProfile.urbanArchitectureTendency * 100,
                sceneProfile.landscapeTendency * 100,
                sceneProfile.naturalDocumentaryTendency * 100,
                sceneProfile.architecturePresence * 100
            )
        } else if lighting.contains(.night)
                    && facets.contains(.countryRoad)
                    && facets.contains(.forest) {
            // A dark rural path with reliable road/vegetation evidence is still a
            // landscape-lighting problem. The documentary tendency can be slightly
            // higher because the frame is vegetation-heavy, but selecting that style
            // drops the measured ground and foliage treatment that the scene needs.
            style = .professionalLandscape
            reason = "夜间乡间道路同时具有道路引导与林木层次证据，采用夜景风光策略保留环境氛围并分别处理地面和植被。"
        } else if sceneProfile.naturalDocumentaryTendency > sceneProfile.landscapeTendency + 0.025 {
            style = .naturalDocumentary
            reason = String(
                format: "户外纪实加权 %.0f%%，植被 %.0f%%、乡村 %.0f%%、主体 %.0f%% 共同主导；建筑仅贡献 %.1f%%。",
                sceneProfile.naturalDocumentaryTendency * 100,
                sceneProfile.vegetationDominant * 100,
                sceneProfile.rural * 100,
                subjectPriority * 100,
                sceneProfile.architecturePresence * 100
            )
        } else if !facets.isDisjoint(with: [.nature, .sky, .water, .coast, .mountain, .forest, .countryRoad]) {
            style = .professionalLandscape
            reason = String(
                format: "自然风景加权 %.0f%% 高于城市建筑 %.0f%%，以天空、区域层次和可信色彩为主要约束。",
                sceneProfile.landscapeTendency * 100,
                sceneProfile.urbanArchitectureTendency * 100
            )
        } else {
            style = .naturalDocumentary; reason = "语义证据不足，采用保真且可解释的自然纪实策略。"
        }

        if facets.isEmpty { facets.insert(.other) }
        // A confident scene label is not evidence of one primary subject. Build 22
        // incorrectly reported 100% subject confidence by reusing scene confidence.
        let subjectConfidence: Float = analysis.faceCount > 0
            ? 0.92
            : analysis.salientSubjectPriorityConfidence
        let depth = min(1, max(0, analysis.spatialLuminanceVariance * 2.3 + analysis.contrastRange * 0.35))
        let atmosphere = min(1, max(0, analysis.mixedLightScore * 1.5 + analysis.highlightConcentration * 0.45 + (looksNight ? 0.2 : 0)))

        return PhotographyContext(
            sceneFacets: facets.sorted { $0.rawValue < $1.rawValue },
            lightingConditions: lighting.sorted { $0.rawValue < $1.rawValue },
            lightDirection: direction,
            sceneProfile: sceneProfile,
            style: style,
            styleReason: reason,
            primarySubjectConfidence: subjectConfidence,
            spatialDepthScore: depth,
            atmosphereScore: atmosphere
        )
    }
}

private extension Array where Element == String {
    func containsKeyword(_ keywords: [String]) -> Bool {
        contains { identifier in
            keywords.contains { identifier.contains($0) }
        }
    }
}

