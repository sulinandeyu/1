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
    let skinMask: NormalizedPhotoMask?
    let skyMask: NormalizedPhotoMask?
    let skyCoverage: Float
    let groundMask: NormalizedPhotoMask?
    let vegetationMask: NormalizedPhotoMask?
    let waterMask: NormalizedPhotoMask?
    let architectureMask: NormalizedPhotoMask?
    let semanticLabels: [SceneLabel]
    var sceneRecognitionDiagnostics: SceneRecognitionDiagnostics = .notEvaluated
    var segmentationDiagnostics: SceneSegmentationDiagnostics = .notEvaluated

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
        let redBlueDelta = redAverage - blueAverage
        let greenBalance = greenAverage - ((redAverage + blueAverage) * 0.5)

        if redBlueDelta > 0.08 {
            return .warm
        }

        if redBlueDelta < -0.08 {
            return .cool
        }

        if greenBalance > 0.08 {
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

        if averageLuminance < 0.27 || shadowRatio > 0.55 || identifiers.containsKeyword(["night", "nighttime"] ) {
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
        return String(
            format: "semantic=%@ recognition=%@/%.3f segmentation=%@ labels=[%@] facets=[%@] lighting=[%@] style=%@ luma=%.3f contrast=%.3f shadow=%.3f highlight=%.3f saturation=%.3f rgb=%.3f/%.3f/%.3f masks=person:%@,subject:%@,skin:%@,sky:%@(%.3f),ground:%@,vegetation:%@,water:%@,architecture:%@",
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
            personMask?.isValid == true ? "yes" : "no",
            salientSubjectMask?.isValid == true ? "yes" : "no",
            skinMask?.isValid == true ? "yes" : "no",
            skyMask?.isValid == true ? "yes" : "no",
            skyCoverage,
            groundMask?.isValid == true ? "yes" : "no",
            vegetationMask?.isValid == true ? "yes" : "no",
            waterMask?.isValid == true ? "yes" : "no",
            architectureMask?.isValid == true ? "yes" : "no"
        )
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
        skinMask: nil,
        skyMask: nil,
        skyCoverage: 0,
        groundMask: nil,
        vegetationMask: nil,
        waterMask: nil,
        architectureMask: nil,
        semanticLabels: []
    )
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

struct PhotographyContext: Equatable, Sendable {
    let sceneFacets: [SceneFacet]
    let lightingConditions: [LightingCondition]
    let lightDirection: LightDirection
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

        let looksNight = analysis.averageLuminance < 0.3 || analysis.shadowRatio > 0.55 || labels.containsKeyword(["night", "nighttime"])
        if looksNight {
            lighting.insert(.night)
            if facets.contains(.city) || facets.contains(.street) || facets.contains(.architecture) { facets.insert(.nightCity) }
        }
        if labels.containsKeyword(["sunrise", "dawn"]) { lighting.insert(.sunrise) }
        if labels.containsKeyword(["sunset", "dusk", "twilight"]) { lighting.insert(.dusk) }

        let blueBias = analysis.blueAverage - analysis.redAverage
        let warmBias = analysis.redAverage - analysis.blueAverage
        if analysis.skyCoverage > 0.08 && analysis.averageLuminance < 0.52 && blueBias > 0.035 {
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
        if facets.contains(.sky) && analysis.averageSaturation < 0.22 && analysis.contrastRange < 0.5 {
            lighting.insert(.overcast)
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
        } else if facets.contains(.architecture) || facets.contains(.city) || facets.contains(.street) {
            style = .urbanArchitecture; reason = "城市结构、道路和点光源需要独立的高光与结构层次控制。"
        } else if !facets.isDisjoint(with: [.nature, .sky, .water, .coast, .mountain, .forest, .countryRoad]) {
            style = .professionalLandscape; reason = "自然场景以天空、远近层次和可信色彩为主要约束。"
        } else if facets.contains(.stillLife) || facets.contains(.food) {
            style = .stillLife; reason = "静物需要保护材质、反光和主体颜色，避免统一风格覆盖。"
        } else {
            style = .naturalDocumentary; reason = "语义证据不足，采用保真且可解释的自然纪实策略。"
        }

        if facets.isEmpty { facets.insert(.other) }
        let semanticConfidence = analysis.semanticLabels.map(\.confidence).max() ?? 0
        let subjectConfidence = max(semanticConfidence, analysis.faceCount > 0 ? 0.92 : (analysis.salientSubjectMask?.isValid == true ? 0.72 : 0.35))
        let depth = min(1, max(0, analysis.spatialLuminanceVariance * 2.3 + analysis.contrastRange * 0.35))
        let atmosphere = min(1, max(0, analysis.mixedLightScore * 1.5 + analysis.highlightConcentration * 0.45 + (looksNight ? 0.2 : 0)))

        return PhotographyContext(
            sceneFacets: facets.sorted { $0.rawValue < $1.rawValue },
            lightingConditions: lighting.sorted { $0.rawValue < $1.rawValue },
            lightDirection: direction,
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

