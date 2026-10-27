import Foundation

struct ProcessingConfiguration: Equatable, Sendable {
    let analysis: AnalysisConfiguration
    let quality: QualityConfiguration
    let portrait: PortraitConfiguration
    let referenceValidation: ReferenceValidationConfiguration

    static let current = ProcessingConfiguration(
        analysis: .default,
        quality: .default,
        portrait: .default,
        referenceValidation: .diagnosticImportsOnly
    )
}

enum ReferenceValidationMode: String, Equatable, Sendable {
    case disabled
    case diagnosticImportsOnly
}

struct ReferenceValidationConfiguration: Equatable, Sendable {
    let mode: ReferenceValidationMode
    let maximumMatches: Int

    static let diagnosticImportsOnly = ReferenceValidationConfiguration(
        mode: .diagnosticImportsOnly,
        maximumMatches: 3
    )

    func isEnabled(isDiagnosticImport: Bool) -> Bool {
        mode == .diagnosticImportsOnly && isDiagnosticImport
    }
}

struct AnalysisConfiguration: Equatable, Sendable {
    let underexposedLuminanceThreshold: Float
    let overexposedLuminanceThreshold: Float
    let flatContrastThreshold: Float
    let highContrastThreshold: Float
    let colorCastDeltaThreshold: Float

    static let `default` = AnalysisConfiguration(
        underexposedLuminanceThreshold: 0.32,
        overexposedLuminanceThreshold: 0.72,
        flatContrastThreshold: 0.34,
        highContrastThreshold: 0.78,
        colorCastDeltaThreshold: 0.08
    )
}

struct QualityConfiguration: Equatable, Sendable {
    let minimumUsableLuminance: Float
    let maximumUsableLuminance: Float
    let minimumUsableContrast: Float
    let maximumUsableContrast: Float

    static let `default` = QualityConfiguration(
        minimumUsableLuminance: 0.22,
        maximumUsableLuminance: 0.82,
        minimumUsableContrast: 0.24,
        maximumUsableContrast: 0.90
    )
}

struct PortraitConfiguration: Equatable, Sendable {
    let faceRelightExposureEV: Float
    let maximumPortraitSaturation: Float
    let maximumPortraitVibrance: Float
    let maximumPortraitSharpening: Float

    static let `default` = PortraitConfiguration(
        faceRelightExposureEV: 0.16,
        maximumPortraitSaturation: 1.035,
        maximumPortraitVibrance: 0.22,
        maximumPortraitSharpening: 0.24
    )
}

