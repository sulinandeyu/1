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
            + analysis.semanticObjectRegions.map { $0.role.rawValue }
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
    let hypothesisIdentifier: String
    let baselineTarget: AdaptivePhotographyTarget
    let resolvedTarget: AdaptivePhotographyTarget
    let referenceMatch: PhotographyReferenceMatchResult
    let referenceInfluence: Float
    let localContrastTarget: Float
    let regionalColorSeparationTarget: Float
    let subjectBackgroundDeltaTarget: Float?
    let rationale: [String]
    let preservedProperties: [String]

    var referenceApplied: Bool {
        referenceInfluence > 0 && referenceMatch.isApplicable
    }

    /// Builds a reference-free profile so the aesthetic planner can be exercised
    /// independently of the licensed-reference experiment. Every target remains
    /// derived from the current photo and its detected problems.
    static func measuredBaseline(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> PhotographyTargetProfile {
        let baseline = AdaptivePhotographyTargetGenerator().makeTarget(
            analysis: analysis,
            problems: problems
        )
        // The production B target deliberately remains unchanged. D uses this
        // source-relative target so a bright image with a large white sky is not
        // compared against a generic mid-grey destination. Every correction is
        // derived from recoverable endpoint evidence in the current photo.
        let recoverableHighlights = max(0, analysis.highlightRatio - analysis.whiteRatio)
        let recoverableShadows = max(0, analysis.shadowRatio - analysis.blackRatio)
        let whitePressure = max(0, analysis.whiteRatio - 0.04)
        let blackPressure = max(0, analysis.blackRatio - 0.035)
        let noiseHeadroom = max(0.25, 1 - analysis.noiseEstimate * 2.5)
        let measuredLuminanceShift = (
            recoverableShadows * 0.08 * noiseHeadroom
                - recoverableHighlights * 0.22
                - whitePressure * 0.12
                + blackPressure * 0.05
        ).clamped(to: -0.075...0.055)
        let measuredLuminance = (analysis.averageLuminance + measuredLuminanceShift)
            .clamped(to: 0.26...0.7)
        let measuredHalfWidth = (0.042 + baseline.atmosphereProtection * 0.018)
            .clamped(to: 0.038...0.06)
        // A high source range is not itself a request to flatten the photograph.
        // Preserve most of the measured range and let endpoint/region controls
        // handle recoverable highlights and spatial hierarchy.  This remains
        // source-relative and is used only by the diagnostic D path.
        let measuredContrast = max(
            baseline.contrast,
            analysis.contrastRange
                - max(0, analysis.contrastRange - 0.72) * 0.28
        ).clamped(to: 0.46...0.82)
        let measuredTarget = AdaptivePhotographyTarget(
            luminance: measuredLuminance,
            luminanceMinimum: (measuredLuminance - measuredHalfWidth).clamped(to: 0.2...0.68),
            luminanceMaximum: (measuredLuminance + measuredHalfWidth).clamped(to: 0.3...0.76),
            contrast: measuredContrast,
            shadowRatio: baseline.shadowRatio,
            highlightRatio: baseline.highlightRatio,
            saturation: baseline.saturation,
            atmosphereProtection: baseline.atmosphereProtection,
            rationale: String(
                format: "D 使用同一测量定义的源图相对目标：亮度 %.3f%+.3f→%.3f；反差 %.3f→%.3f；可恢复高光 %.3f、可恢复阴影 %.3f、白位压力 %.3f、噪声余量 %.3f。",
                analysis.averageLuminance,
                measuredLuminanceShift,
                measuredLuminance,
                analysis.contrastRange,
                measuredContrast,
                recoverableHighlights,
                recoverableShadows,
                whitePressure,
                noiseHeadroom
            )
        )
        let subjectDelta = analysis.nonPersonPrimarySubjectStatistics.map {
            $0.averageLuminance - analysis.averageLuminance
        }
        var protections = ["真实场景结构", "不可恢复的高光与暗部", "中性色与现场光氛围"]
        if analysis.containsPersonEvidence {
            protections += ["人物身份与身体结构", "真实肤色与皮肤纹理"]
        }
        return PhotographyTargetProfile(
            hypothesisIdentifier: "D-measured-continuity",
            baselineTarget: baseline,
            resolvedTarget: measuredTarget,
            referenceMatch: .unavailable("D 路径不读取摄影参考；只使用当前照片测量。"),
            referenceInfluence: 0,
            localContrastTarget: measuredTarget.contrast,
            regionalColorSeparationTarget: 0,
            subjectBackgroundDeltaTarget: subjectDelta,
            rationale: [measuredTarget.rationale, "目标与渲染后复测共用 PhotoAnalyzer 指标，不使用场景预设或摄影参考参数。"],
            preservedProperties: protections
        )
    }
}

/// PT-AESTHETIC-005: diagnostic-only, source-measured alternatives to the D
/// continuity target. These are target hypotheses, not looks or scene presets:
/// every value is recomputed from this image's endpoints, noise, reliable masks
/// and regional colour relationships. Human preference remains unknown until a
/// blind comparison is recorded.
enum AestheticTargetHypothesisKind: String, Equatable, Sendable {
    case spatialEmphasis = "E1-spatial-emphasis"
    case restrainedDepth = "E2-restrained-depth"
}

struct AestheticTargetHypothesis: Equatable, Sendable {
    let kind: AestheticTargetHypothesisKind
    let displayName: String
    let profile: PhotographyTargetProfile
    let targetQualityStatus: String
    let evidenceConfidence: Float
    let rationale: [String]
}

struct AestheticTargetHypothesisGenerator {
    func makeHypotheses(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> [AestheticTargetHypothesis] {
        let continuity = PhotographyTargetProfile.measuredBaseline(
            analysis: analysis,
            problems: problems
        )
        let source = analysis
        let noiseHeadroom = (1 - source.noiseEstimate * 2.7).clamped(to: 0.25...1)
        let atmosphereHeadroom = (1 - continuity.resolvedTarget.atmosphereProtection * 0.72)
            .clamped(to: 0.25...1)
        let usableRegionalCoverage = [
            source.groundMask?.qualityAssessment.isUsable == true ? source.groundMask?.activeCoverage : nil,
            source.vegetationMask?.qualityAssessment.isUsable == true ? source.vegetationMask?.activeCoverage : nil,
            source.architectureMask?.qualityAssessment.isUsable == true ? source.architectureMask?.activeCoverage : nil
        ]
            .compactMap { $0 }
            .reduce(0, +)
            .clamped(to: 0...0.9)
        let regionEvidenceConfidence = (
            0.24
                + usableRegionalCoverage * 0.44
                + max(source.sceneRecognitionDiagnostics.topConfidence, source.subjectPriorityProfile.confidence) * 0.22
        ).clamped(to: 0.18...0.82)
        let colorSeparationEvidence: Float = {
            guard
                source.vegetationMask?.qualityAssessment.isUsable == true,
                let vegetation = source.vegetationStatistics
            else { return 0 }
            let yellowEvidence = (vegetation.yellowColorRatio / 0.42).clamped(to: 0...1)
            let greenEvidence = (vegetation.greenColorRatio / 0.30).clamped(to: 0...1)
            let coexistence = min(yellowEvidence, greenEvidence)
            let yellowDominance = max(0, yellowEvidence - greenEvidence * 0.35)
            let saturationHeadroom = ((0.46 - vegetation.averageSaturation) / 0.46)
                .clamped(to: 0...1)
            return (max(coexistence * 0.72, yellowDominance * 0.48) * saturationHeadroom * 0.065)
                .clamped(to: 0...0.055)
        }()
        let portraitColorProtection: Float = source.containsPersonEvidence ? 0.25 : 1
        let e1SaturationLift = min(0.016, colorSeparationEvidence * 0.30) * portraitColorProtection
        let e2SaturationLift = min(0.010, colorSeparationEvidence * 0.20) * portraitColorProtection

        let recoverableHighlight = max(0, source.highlightRatio - source.whiteRatio)
        let endpointPressure = (
            recoverableHighlight * 0.14 + max(0, source.whiteRatio - 0.035) * 0.10
        ).clamped(to: 0...0.035)
        let spatialDepthOpportunity = (
            max(0, source.averageLuminance - 0.46) * 0.105
                + usableRegionalCoverage * 0.012
        ) * noiseHeadroom * atmosphereHeadroom
        let e1LuminanceShift = -(endpointPressure + spatialDepthOpportunity)
            .clamped(to: 0.010...0.052)
        let e1Luminance = (continuity.resolvedTarget.luminance + e1LuminanceShift)
            .clamped(to: 0.25...0.68)
        let e1Contrast = max(
            continuity.resolvedTarget.contrast,
            source.contrastRange - max(0, source.contrastRange - 0.70) * 0.38
        ).clamped(to: 0.50...0.79)
        let e1Target = AdaptivePhotographyTarget(
            luminance: e1Luminance,
            luminanceMinimum: (e1Luminance - 0.040).clamped(to: 0.20...0.66),
            luminanceMaximum: (e1Luminance + 0.045).clamped(to: 0.30...0.73),
            contrast: e1Contrast,
            shadowRatio: continuity.resolvedTarget.shadowRatio,
            highlightRatio: continuity.resolvedTarget.highlightRatio,
            saturation: (continuity.resolvedTarget.saturation + e1SaturationLift)
                .clamped(to: 0.12...0.46),
            atmosphereProtection: continuity.resolvedTarget.atmosphereProtection,
            rationale: String(
                format: "E1 由本图区域覆盖 %.3f、源亮度 %.3f、源反差 %.3f、可恢复高光 %.3f、噪声余量 %.3f 求得；目标亮度 %.3f、反差 %.3f。",
                usableRegionalCoverage,
                source.averageLuminance,
                source.contrastRange,
                recoverableHighlight,
                noiseHeadroom,
                e1Luminance,
                e1Contrast
            )
        )
        let e1Profile = PhotographyTargetProfile(
            hypothesisIdentifier: AestheticTargetHypothesisKind.spatialEmphasis.rawValue,
            baselineTarget: continuity.baselineTarget,
            resolvedTarget: e1Target,
            referenceMatch: .unavailable("E1 不读取摄影参考；目标只来自当前照片测量。"),
            referenceInfluence: 0,
            localContrastTarget: (source.contrastRange + usableRegionalCoverage * 0.030 * noiseHeadroom)
                .clamped(to: source.contrastRange...(source.contrastRange + 0.055)),
            regionalColorSeparationTarget: colorSeparationEvidence,
            subjectBackgroundDeltaTarget: continuity.subjectBackgroundDeltaTarget,
            rationale: [e1Target.rationale, "强调现有空间关系，不创建原图不存在的光源、颜色或主体。"],
            preservedProperties: continuity.preservedProperties
        )

        let lowKeyHeadroom = (
            max(0, source.averageLuminance - 0.38)
                * noiseHeadroom
                * atmosphereHeadroom
        ).clamped(to: 0...0.26)
        let e2AdditionalDepth = (0.018 + lowKeyHeadroom * 0.13 + usableRegionalCoverage * 0.008)
            .clamped(to: 0.018...0.060)
        let e2Luminance = (continuity.resolvedTarget.luminance - e2AdditionalDepth)
            .clamped(to: 0.24...0.63)
        let e2Contrast = max(
            continuity.resolvedTarget.contrast,
            source.contrastRange - max(0, source.contrastRange - 0.68) * 0.46
        ).clamped(to: 0.48...0.765)
        let e2Target = AdaptivePhotographyTarget(
            luminance: e2Luminance,
            luminanceMinimum: (e2Luminance - 0.045).clamped(to: 0.19...0.61),
            luminanceMaximum: (e2Luminance + 0.050).clamped(to: 0.28...0.70),
            contrast: e2Contrast,
            shadowRatio: max(source.blackRatio, continuity.resolvedTarget.shadowRatio - lowKeyHeadroom * 0.018),
            highlightRatio: continuity.resolvedTarget.highlightRatio,
            saturation: (continuity.resolvedTarget.saturation + e2SaturationLift)
                .clamped(to: 0.12...0.44),
            atmosphereProtection: continuity.resolvedTarget.atmosphereProtection,
            rationale: String(
                format: "E2 由本图暗调余量 %.3f、区域覆盖 %.3f、噪声余量 %.3f 求得；目标亮度 %.3f、反差 %.3f，并保持源黑位为硬边界。",
                lowKeyHeadroom,
                usableRegionalCoverage,
                noiseHeadroom,
                e2Luminance,
                e2Contrast
            )
        )
        let e2Profile = PhotographyTargetProfile(
            hypothesisIdentifier: AestheticTargetHypothesisKind.restrainedDepth.rawValue,
            baselineTarget: continuity.baselineTarget,
            resolvedTarget: e2Target,
            referenceMatch: .unavailable("E2 不读取摄影参考；目标只来自当前照片测量。"),
            referenceInfluence: 0,
            localContrastTarget: (source.contrastRange + usableRegionalCoverage * 0.020 * noiseHeadroom)
                .clamped(to: source.contrastRange...(source.contrastRange + 0.040)),
            regionalColorSeparationTarget: colorSeparationEvidence * 0.82,
            subjectBackgroundDeltaTarget: continuity.subjectBackgroundDeltaTarget,
            rationale: [e2Target.rationale, "暗调假设只有技术可行性，不代表自动审美优胜；必须盲测。"],
            preservedProperties: continuity.preservedProperties
        )

        return [
            AestheticTargetHypothesis(
                kind: .spatialEmphasis,
                displayName: "E1 动态空间层次",
                profile: e1Profile,
                targetQualityStatus: "uncertain_pending_render_and_human_review",
                evidenceConfidence: regionEvidenceConfidence,
                rationale: e1Profile.rationale
            ),
            AestheticTargetHypothesis(
                kind: .restrainedDepth,
                displayName: "E2 动态克制暗调",
                profile: e2Profile,
                targetQualityStatus: "uncertain_pending_render_and_human_review",
                evidenceConfidence: min(regionEvidenceConfidence, 0.68),
                rationale: e2Profile.rationale
            )
        ]
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
                hypothesisIdentifier: "C-reference-calibration",
                baselineTarget: baseline,
                resolvedTarget: baseline,
                referenceMatch: matchResult,
                referenceInfluence: 0,
                localContrastTarget: baseline.contrast,
                regionalColorSeparationTarget: 0,
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
            hypothesisIdentifier: "C-reference-calibration",
            baselineTarget: baseline,
            resolvedTarget: resolved,
            referenceMatch: matchResult,
            referenceInfluence: influence,
            localContrastTarget: bounded(
                baseline.contrast + (weighted.localContrast - 0.12) * influence * 0.4,
                0.44...0.68
            ),
            regionalColorSeparationTarget: 0,
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
