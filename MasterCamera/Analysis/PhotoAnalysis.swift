import Foundation

struct PhotoAnalysis: Equatable, Sendable {
    let averageLuminance: Float
    let contrastRange: Float
    let redAverage: Float
    let greenAverage: Float
    let blueAverage: Float
    let faceCount: Int
    let faceRegions: [NormalizedPhotoRegion]

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

    static let fallback = PhotoAnalysis(
        averageLuminance: 0.5,
        contrastRange: 0.5,
        redAverage: 0.5,
        greenAverage: 0.5,
        blueAverage: 0.5,
        faceCount: 0,
        faceRegions: []
    )
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

