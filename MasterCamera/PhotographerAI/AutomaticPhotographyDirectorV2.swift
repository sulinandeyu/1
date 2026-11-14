import Foundation

/// PT-V2-INTENT-001 / PT-V2-LOOK-001.
///
/// V2 deliberately separates measured scene evidence, photographic intent and
/// executable parameters.  Scene labels are retained only as trace evidence;
/// no label selects a LUT or a stored recipe.
struct PhotographySceneUnderstandingV2: Equatable, Sendable {
    let visualUnderstanding: VisualSceneUnderstandingResult
    let diagnosis: StructuredPhotographyDiagnosis
    let reliableRegions: [VisualRegionEvidence]
    let protectedRegions: [String]
    let containsPerson: Bool
    let neutralEvidenceReliable: Bool
    let unknowns: [String]

    var traceSummary: String {
        let regions = reliableRegions.map { $0.kind.rawValue }.joined(separator: ",")
        return "status=\(visualUnderstanding.status.rawValue);regions=[\(regions)];person=\(containsPerson);neutral=\(neutralEvidenceReliable);protected=[\(protectedRegions.joined(separator: ","))];unknown=[\(unknowns.joined(separator: ","))]"
    }
}

struct SceneUnderstandingAdapterV2 {
    func adapt(
        analysis: PhotoAnalysis,
        diagnosis: StructuredPhotographyDiagnosis
    ) -> PhotographySceneUnderstandingV2 {
        let understanding = analysis.visualSceneUnderstanding
        let reliable = understanding.regionEvidence.filter {
            $0.status == .reliable && $0.isExecutableForLocalAdjustment
        }
        var protected = understanding.protectedRegions
        if analysis.containsPersonEvidence {
            protected.append("人物真实肤色、皮肤纹理、五官与身体结构")
        }
        if analysis.semanticObjectRegions.contains(where: {
            $0.role == .vehicle && $0.confidence >= 0.55 && $0.mask.qualityAssessment.isUsable
        }) {
            protected.append("可靠车辆语义区域")
        } else {
            protected.append("无可靠车辆实例时的高亮低色度端点")
        }
        return PhotographySceneUnderstandingV2(
            visualUnderstanding: understanding,
            diagnosis: diagnosis,
            reliableRegions: reliable,
            protectedRegions: Array(Set(protected)).sorted(),
            containsPerson: analysis.containsPersonEvidence,
            neutralEvidenceReliable: analysis.neutralColorStatistics?.isReliable == true,
            unknowns: Array(Set(understanding.unknowns + diagnosis.unknowns)).sorted()
        )
    }
}

enum PhotographyIntentBasisV2: String, CaseIterable, Equatable, Hashable, Sendable {
    case naturalDocumentary
    case dimensionalHierarchy
    case atmosphericCinematic

    var title: String {
        switch self {
        case .naturalDocumentary: return "自然纪实"
        case .dimensionalHierarchy: return "空间层次"
        case .atmosphericCinematic: return "氛围电影"
        }
    }
}

struct PhotographyRegionTargetV2: Equatable, Sendable {
    let region: TreatmentRegion
    let sourceLuminance: Float
    let targetLuminance: Float
    let contrastTarget: Float
    let saturationScale: Float
    let rationale: String
}

struct PhotographyIntentV2: Equatable, Sendable {
    let identifier: String
    let basis: PhotographyIntentBasisV2
    let overallDirection: String
    let regionTargets: [PhotographyRegionTargetV2]
    let warmAccentStrength: Float
    let ambientColorSeparation: Float
    let protectedConditions: [String]
    let confidence: Float
    let rationale: [String]

    var traceSummary: String {
        let targets = regionTargets.map {
            String(
                format: "%@ %.3f->%.3f contrast=%.3f saturation=%.3f",
                $0.region.rawValue,
                $0.sourceLuminance,
                $0.targetLuminance,
                $0.contrastTarget,
                $0.saturationScale
            )
        }.joined(separator: " | ")
        return "id=\(identifier);basis=\(basis.rawValue);confidence=\(String(format: "%.3f", confidence));direction=\(overallDirection);targets=[\(targets)];warmAccent=\(String(format: "%.3f", warmAccentStrength));separation=\(String(format: "%.3f", ambientColorSeparation));protected=[\(protectedConditions.joined(separator: ","))];rationale=[\(rationale.joined(separator: " | "))]"
    }
}

struct PhotographyCandidatePlanV2: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let sceneUnderstanding: PhotographySceneUnderstandingV2
    let intent: PhotographyIntentV2
    let recipe: AutomaticEditingRecipe
    let regionalTonePlan: AdaptiveRegionalTonePlan?
    let knowledgeRuleIDs: [PhotographyKnowledgeRuleID]
    let lifecycle: [String]
}

/// Generates photography goals from relationships measured in the current
/// image.  The three bases describe a visual language, never a scene preset.
struct PhotographyIntentGeneratorV2 {
    func generate(
        analysis: PhotoAnalysis,
        understanding: PhotographySceneUnderstandingV2
    ) -> [PhotographyIntentV2] {
        PhotographyIntentBasisV2.allCases.enumerated().map { index, basis in
            makeIntent(
                identifier: "V2-\(index + 1)",
                basis: basis,
                analysis: analysis,
                understanding: understanding
            )
        }
    }

    private func makeIntent(
        identifier: String,
        basis: PhotographyIntentBasisV2,
        analysis: PhotoAnalysis,
        understanding: PhotographySceneUnderstandingV2
    ) -> PhotographyIntentV2 {
        let reliable = understanding.reliableRegions
        let endpointRisk = (analysis.shadowRatio + analysis.highlightRatio).clamped(to: 0...1)
        let colorHeadroom = ((0.46 - analysis.averageSaturation) / 0.46).clamped(to: 0...1)
        let subjectConfidence = understanding.visualUnderstanding.subjectConfidence
        let baseConfidence = (
            0.42
                + Float(reliable.count) * 0.055
                + subjectConfidence * 0.16
                - endpointRisk * 0.12
        ).clamped(to: 0.32...0.88)
        let regionalStrength: Float
        let contrastLift: Float
        let saturationScale: Float
        switch basis {
        case .naturalDocumentary:
            regionalStrength = 0.32
            contrastLift = 0.025
            saturationScale = 1.0
        case .dimensionalHierarchy:
            regionalStrength = 0.68
            contrastLift = 0.075
            saturationScale = 0.985
        case .atmosphericCinematic:
            regionalStrength = understanding.containsPerson ? 0.38 : 0.56
            contrastLift = understanding.containsPerson ? 0.035 : 0.055
            saturationScale = understanding.containsPerson ? 0.995 : 0.965
        }

        let globalTarget = globalLuminanceTarget(for: basis, analysis: analysis)
        var targets: [PhotographyRegionTargetV2] = []
        for evidence in reliable {
            guard let statistics = evidence.statistics,
                  let treatment = treatmentRegion(for: evidence.kind)
            else { continue }
            let relation = statistics.averageLuminance - analysis.averageLuminance
            var desired = globalTarget + relation * (1 - regionalStrength * 0.42)
            if basis == .dimensionalHierarchy {
                if evidence.kind == .ground, statistics.averageLuminance > analysis.averageLuminance + 0.035 {
                    desired -= min(0.10, (statistics.averageLuminance - analysis.averageLuminance) * 0.42)
                }
                if evidence.kind == .salientSubject {
                    desired += min(0.07, subjectConfidence * 0.07)
                }
            } else if basis == .atmosphericCinematic {
                if [.ground, .architecture].contains(evidence.kind) {
                    desired -= min(0.075, statistics.averageLuminance * 0.09)
                }
                if evidence.kind == .sky {
                    desired = min(desired, max(globalTarget + 0.16, 0.65))
                }
            }
            desired = desired.clamped(to: 0.16...0.88)
            targets.append(PhotographyRegionTargetV2(
                region: treatment,
                sourceLuminance: statistics.averageLuminance,
                targetLuminance: desired,
                contrastTarget: max(statistics.contrastRange, analysis.contrastRange + contrastLift)
                    .clamped(to: 0.32...0.82),
                saturationScale: saturationScale,
                rationale: "来自当前区域亮度、全图亮度和该候选的关系目标；不声明对象身份。"
            ))
        }

        let vegetation = analysis.vegetationStatistics
        let warmAccent = vegetation.map {
            ($0.yellowColorRatio * colorHeadroom * (basis == .naturalDocumentary ? 0.18 : 0.42))
                .clamped(to: 0...0.22)
        } ?? 0
        let separation = (
            colorHeadroom
                * (basis == .naturalDocumentary ? 0.12 : (basis == .dimensionalHierarchy ? 0.32 : 0.42))
        ).clamped(to: 0...0.36)
        let direction: String
        switch basis {
        case .naturalDocumentary:
            direction = "修正可测量的曝光与动态范围问题，保留现场光线和综合色彩。"
        case .dimensionalHierarchy:
            direction = "利用可靠区域和显著性关系建立主体、前中后景的明暗层次。"
        case .atmosphericCinematic:
            direction = understanding.containsPerson
                ? "在人物真实性硬约束下，以环境影调和克制色彩形成柔和氛围。"
                : "以中间调结构、冷暖分离和柔和高光形成克制电影氛围。"
        }
        return PhotographyIntentV2(
            identifier: identifier,
            basis: basis,
            overallDirection: direction,
            regionTargets: targets,
            warmAccentStrength: warmAccent,
            ambientColorSeparation: separation,
            protectedConditions: understanding.protectedRegions,
            confidence: baseConfidence,
            rationale: [
                "globalLuma=\(String(format: "%.3f", analysis.averageLuminance)) contrast=\(String(format: "%.3f", analysis.contrastRange)) shadow=\(String(format: "%.3f", analysis.shadowRatio)) highlight=\(String(format: "%.3f", analysis.highlightRatio))",
                "reliableRegions=\(reliable.map { $0.kind.rawValue }.joined(separator: ","))",
                "subjectConfidence=\(String(format: "%.3f", subjectConfidence)); unknown evidence remains unknown"
            ]
        )
    }

    private func globalLuminanceTarget(
        for basis: PhotographyIntentBasisV2,
        analysis: PhotoAnalysis
    ) -> Float {
        let technical = (0.50 + max(0, analysis.shadowRatio - 0.18) * 0.10
            - max(0, analysis.highlightRatio - 0.08) * 0.14)
            .clamped(to: 0.40...0.60)
        switch basis {
        case .naturalDocumentary:
            return technical
        case .dimensionalHierarchy:
            return (technical - max(0, analysis.contrastRange - 0.62) * 0.035)
                .clamped(to: 0.38...0.57)
        case .atmosphericCinematic:
            return (technical - (analysis.averageLuminance > 0.46 ? 0.035 : 0.005))
                .clamped(to: 0.36...0.55)
        }
    }

    private func treatmentRegion(for kind: VisualRegionKind) -> TreatmentRegion? {
        switch kind {
        case .sky: return .sky
        case .ground, .pathOrRoad: return .ground
        case .vegetation: return .vegetation
        case .water: return .water
        case .architecture: return .architecture
        case .salientSubject: return .subject
        default: return nil
        }
    }
}

/// Converts an intent into the same recipe and mask-backed regional controls
/// consumed by the production Core Image renderer.
struct AdaptiveLookGeneratorV2 {
    func makePlan(
        intent: PhotographyIntentV2,
        understanding: PhotographySceneUnderstandingV2,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> PhotographyCandidatePlanV2 {
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        let lumaTarget = targetLuminance(intent: intent, analysis: analysis)
        recipe.exposureEV = exposureEV(from: analysis.averageLuminance, to: lumaTarget)
            .clamped(to: -0.24...0.28)
        recipe.highlightAmount = (1 - max(0, analysis.highlightRatio - 0.045) * 1.8)
            .clamped(to: 0.52...1)
        recipe.shadowAmount = (
            max(0, analysis.shadowRatio - 0.16)
                * (1 - analysis.noiseEstimate * 2.6)
                * 0.62
        ).clamped(to: 0...0.26)
        recipe.toneCurveAmount = toneStrength(intent: intent, analysis: analysis)
        recipe.toneCurveStyle = intent.basis == .naturalDocumentary ? .softHighlights : .cinematic
        recipe.localContrastAmount = localContrast(intent: intent, analysis: analysis)
        recipe.contrast = (1 + max(0, 0.57 - analysis.contrastRange) * 0.17)
            .clamped(to: 1...1.075)
        recipe.vibrance = min(0.16, max(0, 0.30 - analysis.averageSaturation) * 0.28)
        recipe.saturation = saturation(intent: intent, analysis: analysis)
        applyWhiteBalanceEvidence(to: &recipe, analysis: analysis)
        applyColorLanguage(to: &recipe, intent: intent, analysis: analysis)
        applyDetailControls(to: &recipe, analysis: analysis)
        applyPortraitProtection(to: &recipe, understanding: understanding)

        let adjustments = intent.regionTargets.compactMap { target in
            makeRegionalAdjustment(target: target, intent: intent, analysis: analysis)
        }
        let regionalPlan = adjustments.isEmpty ? nil : AdaptiveRegionalTonePlan(
            adjustments: adjustments,
            evidence: adjustments.map { adjustment in
                let target = intent.regionTargets.first { $0.region == adjustment.region }
                return String(
                    format: "V2 %@ source=%.3f target=%.3f EV=%+.3f range=%.2f...%.2f",
                    adjustment.region.rawValue,
                    target?.sourceLuminance ?? 0,
                    target?.targetLuminance ?? 0,
                    adjustment.exposureEV,
                    adjustment.luminanceLowerBound,
                    adjustment.luminanceUpperBound
                )
            }
        )
        let finalRecipe = recipe.clamped()
        return PhotographyCandidatePlanV2(
            identifier: intent.identifier,
            displayName: "V2 \(intent.basis.title)",
            sceneUnderstanding: understanding,
            intent: intent,
            recipe: finalRecipe,
            regionalTonePlan: regionalPlan,
            knowledgeRuleIDs: [
                .v2MeasuredIntent,
                .v2AdaptiveLook,
                .reliableSemanticMask,
                .portraitSourceRelativeProtection
            ],
            lifecycle: [
                "eligible: scene evidence adapted",
                "planned: \(intent.traceSummary)",
                "planned: recipe=\(finalRecipe.traceSummary)",
                "planned: regional=\(regionalPlan?.traceSummary ?? "none")",
                "executed: pending Core Image render"
            ]
        )
    }

    private func targetLuminance(intent: PhotographyIntentV2, analysis: PhotoAnalysis) -> Float {
        guard !intent.regionTargets.isEmpty else {
            return analysis.averageLuminance.clamped(to: 0.40...0.56)
        }
        let average = intent.regionTargets.map(\.targetLuminance).reduce(0, +)
            / Float(intent.regionTargets.count)
        return (average * 0.45 + analysis.averageLuminance * 0.55).clamped(to: 0.38...0.58)
    }

    private func toneStrength(intent: PhotographyIntentV2, analysis: PhotoAnalysis) -> Float {
        let flatness = max(0, 0.58 - analysis.contrastRange)
        switch intent.basis {
        case .naturalDocumentary: return (0.12 + flatness * 0.30).clamped(to: 0.10...0.28)
        case .dimensionalHierarchy: return (0.28 + flatness * 0.42).clamped(to: 0.26...0.52)
        case .atmosphericCinematic: return (0.38 + flatness * 0.38).clamped(to: 0.34...0.58)
        }
    }

    private func localContrast(intent: PhotographyIntentV2, analysis: PhotoAnalysis) -> Float {
        let noiseHeadroom = (1 - analysis.noiseEstimate * 3).clamped(to: 0.2...1)
        let base: Float = intent.basis == .naturalDocumentary ? 0.045
            : (intent.basis == .dimensionalHierarchy ? 0.13 : 0.085)
        return (base * noiseHeadroom).clamped(to: 0.015...0.15)
    }

    private func saturation(intent: PhotographyIntentV2, analysis: PhotoAnalysis) -> Float {
        let over = max(0, analysis.averageSaturation - 0.42)
        let base: Float = intent.basis == .atmosphericCinematic ? 0.975 : 1
        return (base - over * 0.18).clamped(to: 0.96...1.02)
    }

    private func applyWhiteBalanceEvidence(
        to recipe: inout AutomaticEditingRecipe,
        analysis: PhotoAnalysis
    ) {
        guard let neutral = analysis.neutralColorStatistics, neutral.isReliable else { return }
        recipe.temperatureShift = (-neutral.warmBias * 2_800).clamped(to: -260...260)
        recipe.tintShift = (-neutral.greenBias * 56).clamped(to: -5...5)
    }

    private func applyColorLanguage(
        to recipe: inout AutomaticEditingRecipe,
        intent: PhotographyIntentV2,
        analysis: PhotoAnalysis
    ) {
        var hsl = ProfessionalHSLAdjustment.neutral
        if let vegetation = analysis.vegetationStatistics {
            let saturationHeadroom = ((0.46 - vegetation.averageSaturation) / 0.46)
                .clamped(to: 0...1)
            hsl.yellowSaturation = (vegetation.yellowColorRatio * intent.warmAccentStrength * saturationHeadroom * 1.8)
                .clamped(to: 0...0.16)
            hsl.yellowLuminance = (vegetation.yellowColorRatio * intent.warmAccentStrength * 0.22)
                .clamped(to: 0...0.045)
            hsl.greenSaturation = (-intent.ambientColorSeparation * max(0, vegetation.yellowColorRatio - vegetation.greenColorRatio) * 0.22)
                .clamped(to: -0.07...0)
        }
        recipe.hsl = hsl
        guard intent.basis == .atmosphericCinematic, !analysis.containsPersonEvidence else { return }
        recipe.cinematicColorGradeMode = .measuredCoolCinematic
        recipe.shadowCoolAmount = (intent.ambientColorSeparation * 0.22).clamped(to: 0...0.075)
        recipe.midtoneCoolAmount = (intent.ambientColorSeparation * 0.12).clamped(to: 0...0.04)
        recipe.highlightWarmAmount = (intent.warmAccentStrength * 0.16).clamped(to: 0...0.035)
        recipe.colorGradeIntensity = (intent.ambientColorSeparation * 0.28).clamped(to: 0...0.09)
        recipe.colorContrast = (intent.ambientColorSeparation * 0.16).clamped(to: 0...0.055)
        recipe.neutralHighlightProtection = 0.78
    }

    private func applyDetailControls(
        to recipe: inout AutomaticEditingRecipe,
        analysis: PhotoAnalysis
    ) {
        recipe.noiseReductionAmount = (analysis.noiseEstimate * 0.045).clamped(to: 0...0.035)
        recipe.sharpeningAmount = ((0.6 - analysis.detailScore) * 0.16)
            .clamped(to: 0.02...0.12)
    }

    private func applyPortraitProtection(
        to recipe: inout AutomaticEditingRecipe,
        understanding: PhotographySceneUnderstandingV2
    ) {
        guard understanding.containsPerson else { return }
        recipe.faceExposureEV = 0
        recipe.subjectExposureEV = 0
        recipe.skinTextureProtection = 0.8
        recipe.temperatureShift = recipe.temperatureShift.clamped(to: -80...80)
        recipe.tintShift = recipe.tintShift.clamped(to: -2...2)
        recipe.colorGradeIntensity = 0
        recipe.shadowCoolAmount = 0
        recipe.midtoneCoolAmount = 0
        recipe.midtoneWarmAmount = 0
        recipe.highlightWarmAmount = 0
        recipe.hsl.orangeHue = 0
        recipe.hsl.orangeSaturation = 0
        recipe.hsl.orangeLuminance = 0
    }

    private func makeRegionalAdjustment(
        target: PhotographyRegionTargetV2,
        intent: PhotographyIntentV2,
        analysis: PhotoAnalysis
    ) -> ManualRegionalToneAdjustment? {
        guard target.sourceLuminance > 0.015 else { return nil }
        let ev = exposureEV(from: target.sourceLuminance, to: target.targetLuminance)
            .clamped(to: -0.52...0.30)
        let protectsBrightEndpoints = [.ground, .architecture].contains(target.region)
        var hsl = ProfessionalHSLAdjustment.neutral
        if target.region == .vegetation, let statistics = analysis.vegetationStatistics {
            let headroom = ((0.46 - statistics.averageSaturation) / 0.46).clamped(to: 0...1)
            hsl.yellowSaturation = (statistics.yellowColorRatio * intent.warmAccentStrength * headroom * 1.4)
                .clamped(to: 0...0.18)
            hsl.greenSaturation = (-intent.ambientColorSeparation * max(0, statistics.yellowColorRatio - statistics.greenColorRatio) * 0.2)
                .clamped(to: -0.08...0)
        }
        return ManualRegionalToneAdjustment(
            region: target.region,
            exposureEV: ev,
            highlightAmount: target.region == .sky ? 0.76 : 0.92,
            shadowAmount: ev < 0 ? 0.05 : min(0.12, max(0, analysis.shadowRatio - 0.18) * 0.25),
            lowerMidtoneLift: ev < -0.08 ? max(-0.09, ev * 0.16) : 0,
            midtoneBias: (ev * 0.20).clamped(to: -0.10...0.06),
            upperMidtoneSeparation: max(0, target.contrastTarget - analysis.contrastRange)
                .clamped(to: 0...0.06),
            highlightRollOff: target.region == .sky ? 0.12 : 0.04,
            contrast: (1 + max(0, target.contrastTarget - analysis.contrastRange) * 0.16)
                .clamped(to: 1...1.10),
            saturation: target.saturationScale,
            hsl: hsl,
            luminanceLowerBound: target.region == .sky ? 0.48 : 0.11,
            luminanceUpperBound: protectsBrightEndpoints ? 0.78 : 0.9,
            luminanceFeather: protectsBrightEndpoints ? 0.19 : 0.16
        ).diagnosticClamped()
    }

    private func exposureEV(from source: Float, to target: Float) -> Float {
        guard source > 0.015, target > 0.015 else { return 0 }
        return log2(target / source)
    }
}

struct AutomaticPhotographyDirectorV2 {
    private let adapter = SceneUnderstandingAdapterV2()
    private let intentGenerator = PhotographyIntentGeneratorV2()
    private let lookGenerator = AdaptiveLookGeneratorV2()

    func makeCandidatePlans(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        diagnosis: StructuredPhotographyDiagnosis
    ) -> [PhotographyCandidatePlanV2] {
        let understanding = adapter.adapt(analysis: analysis, diagnosis: diagnosis)
        return intentGenerator.generate(analysis: analysis, understanding: understanding).map {
            lookGenerator.makePlan(
                intent: $0,
                understanding: understanding,
                analysis: analysis,
                problems: problems
            )
        }
    }
}

enum PhotographyTechnicalStatusV2: String, Equatable, Sendable {
    case passed
    case warning
    case rejected
}

struct PhotographyRenderedCandidateEvidenceV2: Equatable, Sendable {
    let identifier: String
    let technicalStatus: PhotographyTechnicalStatusV2
    let intentAlignment: Float
    let subjectBackgroundSeparation: Float
    let atmospherePreservation: Float
    let neutralProtection: Float
    let clippingPenalty: Float
    let artifactPenalty: Float
}

struct PhotographyCandidateSelectionV2: Equatable, Sendable {
    let selectedIdentifier: String?
    let eligibleIdentifiers: [String]
    let provisional: Bool
    let reason: String
}

/// PT-V2-SELECT-001. This is a replaceable engineering selector, not a learned
/// aesthetic model. It never rewards maximum darkness, saturation or RGB delta.
struct AestheticCandidateSelectorV2 {
    func select(
        candidates: [PhotographyRenderedCandidateEvidenceV2]
    ) -> PhotographyCandidateSelectionV2 {
        let eligible = candidates.filter { $0.technicalStatus != .rejected }
        guard !eligible.isEmpty else {
            return PhotographyCandidateSelectionV2(
                selectedIdentifier: nil,
                eligibleIdentifiers: [],
                provisional: true,
                reason: "全部候选被技术安全层拒绝；不得自动选择。"
            )
        }
        let selected = eligible.max { left, right in
            score(left) < score(right)
        }
        return PhotographyCandidateSelectionV2(
            selectedIdentifier: selected?.identifier,
            eligibleIdentifiers: eligible.map(\.identifier),
            provisional: true,
            reason: "仅按摄影意图一致性、主体/环境关系、氛围和保护指标暂定；尚无足够人工偏好数据，不代表专业审美通过。"
        )
    }

    private func score(_ evidence: PhotographyRenderedCandidateEvidenceV2) -> Float {
        evidence.intentAlignment * 0.34
            + evidence.subjectBackgroundSeparation * 0.20
            + evidence.atmospherePreservation * 0.20
            + evidence.neutralProtection * 0.26
            - evidence.clippingPenalty * 0.42
            - evidence.artifactPenalty * 0.48
    }
}
