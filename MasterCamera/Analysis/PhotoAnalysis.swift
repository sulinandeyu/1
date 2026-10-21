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
    let faceCount: Int
    let faceRegions: [NormalizedPhotoRegion]
    let faceAverageLuminance: Float?
    let backgroundAverageLuminance: Float?
    let personMask: NormalizedPhotoMask?
    let salientSubjectMask: NormalizedPhotoMask?
    let skinMask: NormalizedPhotoMask?
    let skyMask: NormalizedPhotoMask?
    let skyCoverage: Float
    let semanticLabels: [SceneLabel]

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

    static let fallback = PhotoAnalysis(
        averageLuminance: 0.5,
        contrastRange: 0.5,
        redAverage: 0.5,
        greenAverage: 0.5,
        blueAverage: 0.5,
        shadowRatio: 0.0,
        highlightRatio: 0.0,
        averageSaturation: 0.0,
        faceCount: 0,
        faceRegions: [],
        faceAverageLuminance: nil,
        backgroundAverageLuminance: nil,
        personMask: nil,
        salientSubjectMask: nil,
        skinMask: nil,
        skyMask: nil,
        skyCoverage: 0,
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
}

struct SceneLabel: Equatable, Sendable {
    let identifier: String
    let confidence: Float
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

private extension Array where Element == String {
    func containsKeyword(_ keywords: [String]) -> Bool {
        contains { identifier in
            keywords.contains { identifier.contains($0) }
        }
    }
}

