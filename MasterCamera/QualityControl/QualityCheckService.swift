import Foundation

final class QualityCheckService {
    private let analyzer = PhotoAnalyzer()

    func check(
        originalData: Data,
        editedData: Data
    ) throws -> QualityCheckResult {
        let editedAnalysis = try analyzer.analyzeImageQuality(data: editedData)
        var issues: [QualityIssue] = []

        if editedAnalysis.averageLuminance < 0.22 {
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

        if editedData == originalData {
            issues.append(.possibleRenderFallback)
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

        if issues.contains(.tooDark) || issues.contains(.tooBright) || issues.contains(.possibleRenderFallback) {
            return .failed
        }

        return .warning
    }
}

