import Foundation

enum PhotographyReferenceUsageMode: String, Equatable, Sendable {
    case diagnosticValidation
    case production
}

struct PhotographyReferenceIndexDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let usageScope: String
    let productionUseAllowed: Bool
    let modelTrainingAllowed: Bool
    let referencePixelsBundled: Bool
    let records: [PhotographyReferenceFeatureRecord]
}

struct PhotographyReferenceFeatureRecord: Codable, Equatable, Sendable {
    let id: String
    let usage: PhotographyReferenceUsage
    let license: PhotographyReferenceLicenseSummary
    let source: PhotographyReferenceSourceSummary
    let semantics: PhotographyReferenceSemantics
    let vector: PhotographyReferenceFeatureVector
    let nonTransferable: [String]
}

struct PhotographyReferenceUsage: Codable, Equatable, Sendable {
    let validationModeAllowed: Bool
    let productionUseAllowed: Bool
    let modelTrainingAllowed: Bool
    let reason: String
}

struct PhotographyReferenceLicenseSummary: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let attributionRequired: Bool
    let shareAlike: Bool
}

struct PhotographyReferenceSourceSummary: Codable, Equatable, Sendable {
    let pageUrl: String
    let creator: String
    let title: String
}

struct PhotographyReferenceSemantics: Codable, Equatable, Sendable {
    let categories: [String]
    let subjects: [String]
    let lighting: [String]
    let annotationStatus: String
}

struct PhotographyReferenceFeatureVector: Codable, Equatable, Sendable {
    let averageLuminance: Float
    let contrastRange: Float
    let shadowRatio: Float
    let highlightRatio: Float
    let averageSaturation: Float
    let redAverage: Float
    let greenAverage: Float
    let blueAverage: Float
    let neutralCoverage: Float
    let warmPixelRatio: Float
    let coolPixelRatio: Float
    let localContrast: Float
    let gradientEnergy: Float
    let centerLuminanceDelta: Float
    let centerSaturationDelta: Float
}

enum PhotographyReferenceMatchStatus: String, Equatable, Sendable {
    case matchedForValidation
    case insufficientReferenceEvidence
    case prohibitedByUsagePolicy
    case indexUnavailable
}

struct PhotographyReferenceMatch: Equatable, Sendable {
    let record: PhotographyReferenceFeatureRecord
    let similarity: Float
    let metricSimilarity: Float
    let semanticSimilarity: Float
    let reasons: [String]
    let nonTransferableFeatures: [String]
}

struct PhotographyReferenceMatchResult: Equatable, Sendable {
    let status: PhotographyReferenceMatchStatus
    let confidence: Float
    let matches: [PhotographyReferenceMatch]
    let fallbackReason: String?

    var isApplicable: Bool {
        status == .matchedForValidation && confidence >= 0.54 && !matches.isEmpty
    }

    static func unavailable(_ reason: String) -> PhotographyReferenceMatchResult {
        PhotographyReferenceMatchResult(
            status: .indexUnavailable,
            confidence: 0,
            matches: [],
            fallbackReason: reason
        )
    }
}

/// Searches a compact, licensed-feature index. It never loads reference pixels
/// and never returns an editing recipe. The result is only applicability evidence
/// for a bounded per-image target calibration.
struct PhotographyReferenceMatcher: Sendable {
    private let records: [PhotographyReferenceFeatureRecord]
    private let usageMode: PhotographyReferenceUsageMode
    private let indexProductionUseAllowed: Bool

    init(
        index: PhotographyReferenceIndexDocument,
        usageMode: PhotographyReferenceUsageMode
    ) {
        self.usageMode = usageMode
        self.indexProductionUseAllowed = index.productionUseAllowed
        self.records = index.records.filter { record in
            switch usageMode {
            case .diagnosticValidation:
                return record.usage.validationModeAllowed
            case .production:
                return index.productionUseAllowed && record.usage.productionUseAllowed
            }
        }
    }

    static func loadBundledForValidation() -> PhotographyReferenceMatcher? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(
            forResource: "PhotographyReferenceIndex.v1",
            withExtension: "json"
        ) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let index = try JSONDecoder().decode(PhotographyReferenceIndexDocument.self, from: data)
            return PhotographyReferenceMatcher(index: index, usageMode: .diagnosticValidation)
        } catch {
            return nil
        }
    }

    func match(analysis: PhotoAnalysis, maximumResults: Int = 3) -> PhotographyReferenceMatchResult {
        if usageMode == .production && !indexProductionUseAllowed {
            return PhotographyReferenceMatchResult(
                status: .prohibitedByUsagePolicy,
                confidence: 0,
                matches: [],
                fallbackReason: "参考索引尚未完成人工法律与内容审核，禁止用于正式出片。"
            )
        }
        guard !records.isEmpty else {
            return .unavailable("没有符合当前使用范围的参考特征；继续使用原有逐图测量求解器。")
        }

        let queryTokens = semanticTokens(for: analysis)
        let scored = records.map { record -> PhotographyReferenceMatch in
            let metric = metricSimilarity(analysis: analysis, reference: record.vector)
            let semantic = tokenSimilarity(
                queryTokens,
                tokens(from: record.semantics.categories + record.semantics.subjects + record.semantics.lighting)
            )
            let similarity = clamp(metric * 0.90 + semantic * 0.10)
            let reasons = matchReasons(
                analysis: analysis,
                reference: record,
                metricSimilarity: metric,
                semanticSimilarity: semantic
            )
            var blocked = record.nonTransferable
            if semantic < 0.12 {
                blocked.append("语义内容关联弱：不得迁移主体、构图或场景色彩")
            }
            if analysis.faceCount > 0 {
                blocked.append("人物肤色、面部纹理及人物局部参数")
            }
            return PhotographyReferenceMatch(
                record: record,
                similarity: similarity,
                metricSimilarity: metric,
                semanticSimilarity: semantic,
                reasons: reasons,
                nonTransferableFeatures: Array(Set(blocked)).sorted()
            )
        }
        .sorted { left, right in
            if abs(left.similarity - right.similarity) > 0.0001 {
                return left.similarity > right.similarity
            }
            return left.record.id < right.record.id
        }

        let top = Array(scored.prefix(max(1, maximumResults)))
        let best = top.first?.similarity ?? 0
        let margin = top.count > 1 ? max(0, best - top[1].similarity) : 0
        let confidence = clamp(best * 0.82 + min(1, margin / 0.12) * 0.18)
        guard best >= 0.58, confidence >= 0.54 else {
            return PhotographyReferenceMatchResult(
                status: .insufficientReferenceEvidence,
                confidence: confidence,
                matches: top,
                fallbackReason: String(
                    format: "最佳参考相似度 %.1f%%、综合置信度 %.1f%%，未达到适用门槛；继续使用逐图测量求解器。",
                    best * 100,
                    confidence * 100
                )
            )
        }
        return PhotographyReferenceMatchResult(
            status: .matchedForValidation,
            confidence: confidence,
            matches: top,
            fallbackReason: nil
        )
    }

    private func metricSimilarity(
        analysis: PhotoAnalysis,
        reference: PhotographyReferenceFeatureVector
    ) -> Float {
        var weightedDistance: Float = 0
        var weight: Float = 0
        func add(_ current: Float, _ target: Float, scale: Float, weight itemWeight: Float) {
            weightedDistance += min(1, abs(current - target) / scale) * itemWeight
            weight += itemWeight
        }
        add(analysis.averageLuminance, reference.averageLuminance, scale: 0.25, weight: 0.17)
        add(analysis.contrastRange, reference.contrastRange, scale: 0.30, weight: 0.16)
        add(analysis.shadowRatio, reference.shadowRatio, scale: 0.25, weight: 0.10)
        add(analysis.highlightRatio, reference.highlightRatio, scale: 0.18, weight: 0.10)
        add(analysis.averageSaturation, reference.averageSaturation, scale: 0.35, weight: 0.12)
        add(
            analysis.redAverage - analysis.blueAverage,
            reference.redAverage - reference.blueAverage,
            scale: 0.18,
            weight: 0.07
        )
        add(
            analysis.greenAverage - (analysis.redAverage + analysis.blueAverage) * 0.5,
            reference.greenAverage - (reference.redAverage + reference.blueAverage) * 0.5,
            scale: 0.14,
            weight: 0.05
        )
        if let neutral = analysis.neutralColorStatistics, neutral.isReliable {
            add(neutral.coverage, reference.neutralCoverage, scale: 0.40, weight: 0.08)
        }
        if let subjectDelta = reliableSubjectBackgroundDelta(analysis) {
            // The dataset value is only a centre-versus-border composition proxy.
            // It receives a small weight and is never treated as subject identity.
            add(subjectDelta, reference.centerLuminanceDelta, scale: 0.24, weight: 0.05)
        }
        guard weight > 0 else { return 0 }
        return clamp(1 - weightedDistance / weight)
    }

    private func matchReasons(
        analysis: PhotoAnalysis,
        reference: PhotographyReferenceFeatureRecord,
        metricSimilarity: Float,
        semanticSimilarity: Float
    ) -> [String] {
        let vector = reference.vector
        var reasons = [
            String(format: "影调相似：亮度差 %.3f、动态范围差 %.3f", abs(analysis.averageLuminance - vector.averageLuminance), abs(analysis.contrastRange - vector.contrastRange)),
            String(format: "两端分布：阴影差 %.3f、高光差 %.3f", abs(analysis.shadowRatio - vector.shadowRatio), abs(analysis.highlightRatio - vector.highlightRatio)),
            String(format: "色彩关系：饱和度差 %.3f、R-B 差 %.3f", abs(analysis.averageSaturation - vector.averageSaturation), abs((analysis.redAverage - analysis.blueAverage) - (vector.redAverage - vector.blueAverage))),
            String(format: "度量相似 %.1f%%、语义辅助 %.1f%%；语义只用于适用性，不绑定参数", metricSimilarity * 100, semanticSimilarity * 100)
        ]
        if let subjectDelta = reliableSubjectBackgroundDelta(analysis) {
            reasons.append(String(
                format: "主体/背景亮度关系与参考构图代理差 %.3f；仅作低权重关系证据",
                abs(subjectDelta - vector.centerLuminanceDelta)
            ))
        } else {
            reasons.append("主体关系证据不足；构图代理未参与匹配")
        }
        return reasons
    }

    private func semanticTokens(for analysis: PhotoAnalysis) -> Set<String> {
        let values = analysis.semanticLabels.map(\.identifier)
            + analysis.photographyContext.sceneFacets.map(\.rawValue)
            + analysis.photographyContext.lightingConditions.map(\.rawValue)
        return tokens(from: values)
    }

    private func tokens(from values: [String]) -> Set<String> {
        Set(values.flatMap { value in
            value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }.filter { $0.count > 2 })
    }

    private func tokenSimilarity(_ left: Set<String>, _ right: Set<String>) -> Float {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Float(intersection) / Float(union)
    }

    private func reliableSubjectBackgroundDelta(_ analysis: PhotoAnalysis) -> Float? {
        if analysis.faceCount > 0,
           let faceDelta = analysis.faceToBackgroundLuminanceDelta {
            return faceDelta
        }
        guard
            analysis.salientSubjectPriorityConfidence >= 0.58,
            let statistics = analysis.salientSubjectStatistics
        else { return nil }
        return statistics.averageLuminance - analysis.averageLuminance
    }

    private func clamp(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

/// A reference-guided target is still a per-image measured target. Reference
/// statistics may only make a small, explainable correction to the baseline;
/// white balance, HSL, curves and local masks remain computed from the source.
struct PhotographyTargetProfile: Equatable, Sendable {
    let baselineTarget: AdaptivePhotographyTarget
    let resolvedTarget: AdaptivePhotographyTarget
    let referenceMatch: PhotographyReferenceMatchResult
    let referenceInfluence: Float
    let localContrastTarget: Float
    let subjectBackgroundDeltaTarget: Float?
    let rationale: [String]
    let preservedProperties: [String]

    var referenceApplied: Bool {
        referenceInfluence > 0 && referenceMatch.isApplicable
    }
}

struct PhotographyReferenceTargetGenerator {
    func makeProfile(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        matchResult: PhotographyReferenceMatchResult
    ) -> PhotographyTargetProfile {
        let baseline = AdaptivePhotographyTargetGenerator().makeTarget(
            analysis: analysis,
            problems: problems
        )
        guard matchResult.isApplicable else {
            return PhotographyTargetProfile(
                baselineTarget: baseline,
                resolvedTarget: baseline,
                referenceMatch: matchResult,
                referenceInfluence: 0,
                localContrastTarget: baseline.contrast,
                subjectBackgroundDeltaTarget: nil,
                rationale: [matchResult.fallbackReason ?? "参考适用性不足，未修改逐图目标。"],
                preservedProperties: defaultProtections(analysis: analysis)
            )
        }

        let weighted = weightedReferenceVector(matchResult.matches)
        let confidence = matchResult.confidence
        let atmosphereLimit = max(0.04, 1 - baseline.atmosphereProtection * 0.72)
        let portraitLimit: Float = analysis.faceCount > 0 ? 0.45 : 1
        let influence = min(0.16, max(0.04, (confidence - 0.48) * 0.30))
            * atmosphereLimit
            * portraitLimit

        let luminanceShift = bounded(
            (weighted.averageLuminance - baseline.luminance) * influence,
            -0.014...0.014
        )
        let contrastShift = bounded(
            (weighted.contrastRange - baseline.contrast) * influence,
            -0.014...0.014
        )
        let shadowShift = bounded(
            (weighted.shadowRatio - baseline.shadowRatio) * influence,
            -0.012...0.012
        )
        let highlightShift = bounded(
            (weighted.highlightRatio - baseline.highlightRatio) * influence,
            -0.010...0.010
        )
        let saturationShift = bounded(
            (weighted.averageSaturation - baseline.saturation) * influence,
            -0.012...0.012
        )
        let resolvedLuminance = bounded(baseline.luminance + luminanceShift, 0.27...0.54)
        let resolved = AdaptivePhotographyTarget(
            luminance: resolvedLuminance,
            luminanceMinimum: bounded(baseline.luminanceMinimum + luminanceShift, 0.22...0.52),
            luminanceMaximum: bounded(baseline.luminanceMaximum + luminanceShift, 0.34...0.62),
            contrast: bounded(baseline.contrast + contrastShift, 0.44...0.68),
            shadowRatio: bounded(baseline.shadowRatio + shadowShift, analysis.blackRatio...analysis.shadowRatio + 0.02),
            highlightRatio: bounded(baseline.highlightRatio + highlightShift, analysis.whiteRatio...analysis.highlightRatio + 0.02),
            saturation: bounded(baseline.saturation + saturationShift, 0.12...0.48),
            atmosphereProtection: baseline.atmosphereProtection,
            rationale: baseline.rationale + String(
                format: " 参考仅在诊断模式下以 %.1f%% 权重校准目标：亮度 %+.3f、反差 %+.3f、阴影 %+.3f、高光 %+.3f、饱和 %+.3f；不复制白平衡、HSL、曲线或局部参数。",
                influence * 100,
                luminanceShift,
                contrastShift,
                shadowShift,
                highlightShift,
                saturationShift
            )
        )
        let subjectDelta: Float?
        if analysis.salientSubjectPriorityConfidence >= 0.58,
           let statistics = analysis.salientSubjectStatistics {
            let currentDelta = statistics.averageLuminance - analysis.averageLuminance
            let correction = bounded(
                (weighted.centerLuminanceDelta - currentDelta) * influence,
                -0.035...0.035
            )
            subjectDelta = currentDelta + correction
        } else {
            subjectDelta = nil
        }
        return PhotographyTargetProfile(
            baselineTarget: baseline,
            resolvedTarget: resolved,
            referenceMatch: matchResult,
            referenceInfluence: influence,
            localContrastTarget: bounded(
                baseline.contrast + (weighted.localContrast - 0.12) * influence * 0.4,
                0.44...0.68
            ),
            subjectBackgroundDeltaTarget: subjectDelta,
            rationale: [
                "先由当前照片测量生成基线，再用通过适用性门控的参考统计做有限校准。",
                "参考置信度 \(Int((confidence * 100).rounded()))%，实际影响权重 \(String(format: "%.1f", influence * 100))%。",
                "参考只提供目标关系，不提供可直接迁移的滑块参数。"
            ],
            preservedProperties: defaultProtections(analysis: analysis)
        )
    }

    private func weightedReferenceVector(
        _ matches: [PhotographyReferenceMatch]
    ) -> PhotographyReferenceFeatureVector {
        let selected = Array(matches.prefix(3))
        let total = max(0.0001, selected.reduce(Float(0)) { $0 + max(0.01, $1.similarity) })
        func value(_ keyPath: KeyPath<PhotographyReferenceFeatureVector, Float>) -> Float {
            selected.reduce(Float(0)) { partial, match in
                partial + match.record.vector[keyPath: keyPath] * max(0.01, match.similarity) / total
            }
        }
        return PhotographyReferenceFeatureVector(
            averageLuminance: value(\.averageLuminance),
            contrastRange: value(\.contrastRange),
            shadowRatio: value(\.shadowRatio),
            highlightRatio: value(\.highlightRatio),
            averageSaturation: value(\.averageSaturation),
            redAverage: value(\.redAverage),
            greenAverage: value(\.greenAverage),
            blueAverage: value(\.blueAverage),
            neutralCoverage: value(\.neutralCoverage),
            warmPixelRatio: value(\.warmPixelRatio),
            coolPixelRatio: value(\.coolPixelRatio),
            localContrast: value(\.localContrast),
            gradientEnergy: value(\.gradientEnergy),
            centerLuminanceDelta: value(\.centerLuminanceDelta),
            centerSaturationDelta: value(\.centerSaturationDelta)
        )
    }

    private func defaultProtections(analysis: PhotoAnalysis) -> [String] {
        var items = [
            "原始现场冷暖氛围",
            "真实光源与已剪切高光",
            "未被可靠蒙版覆盖的区域",
            "参考图的绝对白平衡、HSL、曲线和内容特征"
        ]
        if analysis.faceCount > 0 {
            items.append("人物身份、五官、肤色色相、皮肤纹理与体型")
        }
        return items
    }

    private func bounded(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
