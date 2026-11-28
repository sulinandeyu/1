import Foundation

struct ProcessingConfiguration: Equatable, Sendable {
    let analysis: AnalysisConfiguration
    let quality: QualityConfiguration
    let portrait: PortraitConfiguration
    let referenceValidation: ReferenceValidationConfiguration
    let diagnosticValidation: DiagnosticValidationConfiguration

    static let current = ProcessingConfiguration(
        analysis: .default,
        quality: .default,
        portrait: .default,
        referenceValidation: .diagnosticImportsOnly,
        diagnosticValidation: .diagnosticImportsOnly
    )

    /// PT-LEARN-007 internal-only inverse-expression verification. Formal B is
    /// still produced by the normal pipeline; only diagnostic M is replaced by
    /// the immutable ORACLE contract for the user-selected A.
    static let ptLearnOracleDiagnostic = ProcessingConfiguration(
        analysis: .default,
        quality: .default,
        portrait: .default,
        referenceValidation: .disabled,
        diagnosticValidation: .ptLearnOracleOnly
    )
}

struct DiagnosticValidationConfiguration: Equatable, Sendable {
    let measuredAestheticCandidateEnabled: Bool
    let manualParameters: ManualPhotographyParameters?
    let isolatedManualOnly: Bool

    static let diagnosticImportsOnly = DiagnosticValidationConfiguration(
        measuredAestheticCandidateEnabled: true,
        manualParameters: .task2ACinematicExpression,
        isolatedManualOnly: false
    )

    static let ptLearnOracleOnly = DiagnosticValidationConfiguration(
        measuredAestheticCandidateEnabled: false,
        manualParameters: .ptLearnOracleAutumnStreetV1,
        isolatedManualOnly: true
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

    static let disabled = ReferenceValidationConfiguration(
        mode: .disabled,
        maximumMatches: 0
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

