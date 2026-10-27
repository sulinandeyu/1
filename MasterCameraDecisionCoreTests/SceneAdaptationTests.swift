import XCTest
@testable import MasterCameraDecisionCore

final class SceneAdaptationTests: XCTestCase {
    private let detector = PhotoProblemDetector()
    private let engine = PhotographyDecisionEngine()

    func testSpecificCoastEvidenceWinsOverGenericOutdoorLabel() {
        let analysis = fixture(labels: ["outdoor", "seashore", "ocean", "sky"])

        XCTAssertEqual(analysis.semanticScene, .outdoor, "This captures the old single-label priority bug")
        XCTAssertEqual(decision(for: analysis).sceneStrategy, .landscape)
    }

    func testSpecificArchitectureEvidenceWinsOverGenericOutdoorLabel() {
        let analysis = fixture(labels: ["outdoor", "building", "architecture", "sky"])

        XCTAssertEqual(analysis.semanticScene, .outdoor, "This captures the old single-label priority bug")
        XCTAssertEqual(decision(for: analysis).sceneStrategy, .architecture)
    }

    func testSceneLabelsDoNotInventDifferentTechnicalCorrectionsForIdenticalPixels() {
        let coast = decision(for: fixture(labels: ["outdoor", "seashore", "ocean", "sky"]))
        let plaza = decision(for: fixture(labels: ["outdoor", "building", "architecture", "sky"]))

        XCTAssertNotEqual(coast.sceneStrategy, plaza.sceneStrategy)
        XCTAssertEqual(coast.recipe.hsl, plaza.recipe.hsl)
        XCTAssertEqual(
            coast.parameterEvidence.map(\.actualValue),
            plaza.parameterEvidence.map(\.actualValue)
        )
        XCTAssertEqual(coast.treatmentPlan.finalLook, plaza.treatmentPlan.finalLook)
    }

    func testOvercastAndClearSkyDoNotReceiveOneFixedSkyPreset() {
        let mask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let overcast = decision(for: fixture(
            luminance: 0.48,
            contrast: 0.40,
            saturation: 0.15,
            labels: ["outdoor", "seashore", "ocean", "sky"],
            skyMask: mask,
            skyStatistics: regionStatistics(
                luminance: 0.7,
                contrast: 0.2,
                saturation: 0.08,
                red: 0.68,
                green: 0.7,
                blue: 0.72,
                highlightRatio: 0.22
            )
        ))
        let clear = decision(for: fixture(
            luminance: 0.56,
            contrast: 0.68,
            saturation: 0.18,
            labels: ["outdoor", "landscape", "sky"],
            skyMask: mask,
            skyStatistics: regionStatistics(
                luminance: 0.58,
                contrast: 0.5,
                saturation: 0.18,
                red: 0.34,
                green: 0.5,
                blue: 0.68,
                highlightRatio: 0.06
            )
        ))

        XCTAssertTrue(overcast.context.lightingConditions.contains(.overcast))
        XCTAssertLessThanOrEqual(overcast.recipe.skySaturation, 1)
        XCTAssertGreaterThan(clear.recipe.skySaturation, 1.0)
        XCTAssertNotEqual(overcast.recipe.skyExposureEV, clear.recipe.skyExposureEV)
        XCTAssertNotEqual(overcast.recipe.skyHighlightAmount, clear.recipe.skyHighlightAmount)
    }

    func testPortraitProtectionIsAHardConstraint() {
        let personMask = NormalizedPhotoMask(width: 1, height: 1, pixels: Data([255]))
        let portrait = decision(for: fixture(
            luminance: 0.324,
            contrast: 0.982,
            saturation: 0.36,
            red: 0.287,
            green: 0.328,
            blue: 0.396,
            labels: ["portrait", "person", "sky", "car"],
            skyMask: personMask,
            skyCoverage: 0.42,
            faceCount: 1,
            faceLuminance: 0.22,
            backgroundLuminance: 0.36,
            personMask: personMask
        ))

        XCTAssertEqual(portrait.sceneStrategy, .backlitPortrait)
        XCTAssertTrue(portrait.treatmentPlan.portraitProtection.isActive)
        XCTAssertFalse(portrait.treatmentPlan.portraitProtection.allowsFaceSpecificRelighting)
        XCTAssertFalse(portrait.treatmentPlan.portraitProtection.allowsGeometryChanges)
        XCTAssertFalse(portrait.treatmentPlan.portraitProtection.allowsGenerativeChanges)
        XCTAssertTrue(portrait.treatmentPlan.portraitProtection.preservesSkinTexture)
        XCTAssertEqual(portrait.recipe.faceExposureEV, 0)
        XCTAssertLessThanOrEqual(portrait.recipe.subjectExposureEV, 0.16)
        XCTAssertGreaterThanOrEqual(portrait.recipe.skinTextureProtection, 0.72)
        XCTAssertEqual(portrait.recipe.hsl.orangeLuminance, 0)
    }

    func testV82PortraitDoesNotManufactureOrangeSkinOrWarmSplitTone() {
        let personMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let portrait = decision(for: fixture(
            luminance: 0.53,
            contrast: 0.66,
            saturation: 0.25,
            red: 0.49,
            green: 0.48,
            blue: 0.45,
            labels: ["portrait", "person", "car", "indoor"],
            faceCount: 1,
            faceLuminance: 0.51,
            backgroundLuminance: 0.49,
            personMask: personMask
        ))

        XCTAssertEqual(portrait.recipe.hsl.orangeHue, 0)
        XCTAssertEqual(portrait.recipe.hsl.orangeSaturation, 0)
        XCTAssertEqual(portrait.recipe.hsl.orangeLuminance, 0)
        XCTAssertLessThanOrEqual(portrait.recipe.colorGradeIntensity, 0.055)
        XCTAssertLessThanOrEqual(portrait.recipe.highlightWarmAmount, 0.03)
        XCTAssertLessThanOrEqual(abs(portrait.recipe.temperatureShift), 35)
    }

    func testV82OvercastArchitectureDoesNotCreateBlueSkyOrHeavySplitTone() {
        let skyMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let architectureMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([0, 0, 255, 255]))
        let result = decision(for: fixture(
            luminance: 0.52,
            contrast: 0.62,
            saturation: 0.13,
            red: 0.50,
            green: 0.51,
            blue: 0.52,
            labels: ["outdoor", "building", "architecture", "sky", "cloudy"],
            skyMask: skyMask,
            architectureMask: architectureMask,
            architectureStatistics: regionStatistics(
                luminance: 0.48,
                contrast: 0.58,
                saturation: 0.08,
                red: 0.47,
                green: 0.48,
                blue: 0.49
            )
        ))

        XCTAssertTrue(result.context.lightingConditions.contains(.overcast))
        XCTAssertLessThanOrEqual(result.recipe.skySaturation, 1)
        XCTAssertLessThanOrEqual(result.recipe.hsl.cyanSaturation, 0)
        XCTAssertLessThanOrEqual(result.recipe.hsl.blueSaturation, 0)
        XCTAssertLessThanOrEqual(result.recipe.colorGradeIntensity, 0.05)
        XCTAssertLessThanOrEqual(result.recipe.shadowCoolAmount, 0.018)
        XCTAssertGreaterThanOrEqual(result.recipe.exposureEV, -0.025)
    }

    func testRealReferenceMeasurementsCreateDifferentDirectorialPlans() {
        // Measurements are extracted from the supplied real JPEGs at 128 px long-edge.
        let autumnNightPath = decision(for: fixture(
            luminance: 0.139,
            contrast: 0.424,
            saturation: 0.534,
            red: 0.159,
            green: 0.138,
            blue: 0.091,
            labels: ["night", "trail", "tree", "outdoor"]
        ))
        let warmBedroom = decision(for: fixture(
            luminance: 0.209,
            contrast: 0.498,
            saturation: 0.454,
            red: 0.249,
            green: 0.202,
            blue: 0.159,
            labels: ["indoor", "bedroom", "furniture", "desk"]
        ))

        XCTAssertEqual(autumnNightPath.sceneStrategy, .night)
        XCTAssertEqual(warmBedroom.sceneStrategy, .workspace)
        XCTAssertNotEqual(autumnNightPath.adaptiveTarget, warmBedroom.adaptiveTarget)
        XCTAssertNotEqual(autumnNightPath.treatmentPlan.finalLook, warmBedroom.treatmentPlan.finalLook)
        XCTAssertNotEqual(autumnNightPath.recipe, warmBedroom.recipe)
        XCTAssertNotEqual(
            autumnNightPath.parameterEvidence.map(\.actualValue),
            warmBedroom.parameterEvidence.map(\.actualValue)
        )
    }

    func testNightCountryRoadKeepsLandscapeFacetTreatment() {
        let regionMask = NormalizedPhotoMask(
            width: 2,
            height: 2,
            pixels: Data([255, 0, 0, 0])
        )
        let autumnNightPath = decision(for: fixture(
            luminance: 0.139,
            contrast: 0.424,
            saturation: 0.534,
            red: 0.159,
            green: 0.138,
            blue: 0.091,
            labels: ["night", "trail", "tree", "outdoor"],
            groundMask: regionMask,
            vegetationMask: regionMask,
            groundStatistics: regionStatistics(
                luminance: 0.12,
                contrast: 0.38,
                saturation: 0.24,
                red: 0.16,
                green: 0.13,
                blue: 0.08,
                shadowRatio: 0.58
            ),
            vegetationStatistics: regionStatistics(
                luminance: 0.11,
                contrast: 0.34,
                saturation: 0.42,
                red: 0.15,
                green: 0.13,
                blue: 0.07,
                shadowRatio: 0.62
            )
        ))

        XCTAssertEqual(autumnNightPath.sceneStrategy, .night)
        XCTAssertEqual(autumnNightPath.context.style, .professionalLandscape)
        XCTAssertTrue(autumnNightPath.context.sceneFacets.contains(.countryRoad))
        XCTAssertTrue(autumnNightPath.context.sceneFacets.contains(.forest))
        XCTAssertGreaterThan(autumnNightPath.recipe.hsl.yellowSaturation, -0.015)
        XCTAssertEqual(autumnNightPath.recipe.temperatureShift, 0)
        XCTAssertTrue(autumnNightPath.treatmentPlan.regionalTreatments.contains { $0.region == .ground })
        XCTAssertTrue(autumnNightPath.treatmentPlan.regionalTreatments.contains { $0.region == .vegetation })
    }

    func testRecognitionFailureRemovesSemanticColorAssumptions() {
        let failed = decision(for: fixture(
            labels: ["landscape", "sky", "forest"],
            recognition: SceneRecognitionDiagnostics(
                status: .failed,
                topConfidence: 0,
                acceptedLabelCount: 0,
                reason: "test failure"
            )
        ))

        XCTAssertEqual(failed.recipe.hsl, .neutral)
        XCTAssertLessThanOrEqual(failed.recipe.colorGradeIntensity, 0.12)
        XCTAssertTrue(failed.actions.contains { $0.title.contains("场景识别失败") })
    }

    func testSegmentationFailureUsesSafeNonRegionalTreatment() {
        let mask = NormalizedPhotoMask(width: 1, height: 1, pixels: Data([255]))
        let degraded = decision(for: fixture(
            labels: ["landscape", "sky"],
            skyMask: mask,
            segmentation: SceneSegmentationDiagnostics(
                status: .failed,
                reason: "test segmentation failure",
                skyCoverage: 0,
                groundCoverage: 0,
                vegetationCoverage: 0,
                waterCoverage: 0,
                architectureCoverage: 0
            )
        ))

        XCTAssertEqual(degraded.recipe.skyExposureEV, 0)
        XCTAssertEqual(degraded.recipe.skyHighlightAmount, 1)
        XCTAssertEqual(degraded.recipe.skySaturation, 1)
        XCTAssertTrue(degraded.actions.contains { $0.title.contains("局部分割降级") })
    }

    func testUnreliableMaskCoverageIsNotClaimedAsRegionalTreatment() {
        let empty = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([0, 0, 0, 0]))
        let full = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 255, 255]))
        let result = decision(for: fixture(
            labels: ["outdoor", "trail", "forest"],
            groundMask: empty,
            vegetationMask: full
        ))

        XCTAssertFalse(result.treatmentPlan.regionalTreatments.contains { $0.region == .ground })
        XCTAssertFalse(result.treatmentPlan.regionalTreatments.contains { $0.region == .vegetation })
    }

    func testFaceWithoutReliablePersonMaskBlocksSceneRegionClaims() {
        let regionMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 0, 0, 0]))
        let result = decision(for: fixture(
            labels: ["portrait", "street", "building"],
            faceCount: 1,
            architectureMask: regionMask
        ))

        XCTAssertTrue(result.treatmentPlan.portraitProtection.isActive)
        XCTAssertFalse(result.treatmentPlan.regionalTreatments.contains { $0.region == .architecture })
        XCTAssertFalse(result.treatmentPlan.regionalTreatments.contains { $0.region == .person })
    }

    func testSmallPersonInLandscapeUsesEnvironmentStrategyWithoutDisablingPortraitProtection() {
        let personMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        )
        let skyMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0])
        )
        let result = decision(for: fixture(
            luminance: 0.50,
            contrast: 0.62,
            saturation: 0.24,
            red: 0.40,
            green: 0.49,
            blue: 0.57,
            labels: ["portrait", "person", "landscape", "mountain", "sky"],
            skyMask: skyMask,
            skyCoverage: 0.5,
            faceCount: 1,
            faceLuminance: 0.48,
            backgroundLuminance: 0.50,
            personMask: personMask,
            skyStatistics: regionStatistics(luminance: 0.62, contrast: 0.38, saturation: 0.42, red: 0.35, green: 0.55, blue: 0.72)
        ))

        XCTAssertEqual(result.sceneStrategy, .landscape)
        XCTAssertEqual(result.context.style, .environmentalPortrait)
        XCTAssertTrue(result.treatmentPlan.portraitProtection.isActive)
        XCTAssertEqual(result.recipe.faceExposureEV, 0)
        XCTAssertLessThanOrEqual(result.recipe.skySaturation, 1)
        XCTAssertFalse(detector.detect(in: fixture(
            luminance: 0.50,
            contrast: 0.62,
            saturation: 0.24,
            red: 0.40,
            green: 0.49,
            blue: 0.57,
            labels: ["portrait", "person", "landscape", "mountain", "sky"],
            faceCount: 1,
            personMask: personMask
        )).contains(.coolCast))
    }

    func testBrightBlueDaylightIsNotMisclassifiedAsBlueHour() {
        let skyMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let daylight = fixture(
            luminance: 0.50,
            contrast: 0.60,
            saturation: 0.26,
            red: 0.39,
            green: 0.49,
            blue: 0.57,
            labels: ["landscape", "mountain", "sky"],
            skyMask: skyMask,
            skyCoverage: 0.5,
            skyStatistics: regionStatistics(luminance: 0.62, contrast: 0.34, saturation: 0.44, red: 0.34, green: 0.55, blue: 0.73)
        )

        XCTAssertFalse(daylight.photographyContext.lightingConditions.contains(.blueHour))
        XCTAssertTrue(daylight.photographyContext.lightingConditions.contains(.midday))
    }

    func testLowLightBlueSkyStillProducesBlueHourEvidence() {
        let skyMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let blueHour = fixture(
            luminance: 0.28,
            contrast: 0.48,
            saturation: 0.30,
            red: 0.25,
            green: 0.34,
            blue: 0.43,
            labels: ["portrait", "landscape", "sky"],
            skyMask: skyMask,
            skyCoverage: 0.5,
            skyStatistics: regionStatistics(luminance: 0.42, contrast: 0.34, saturation: 0.40, red: 0.22, green: 0.39, blue: 0.58),
            shadowRatio: 0.36
        )

        XCTAssertTrue(blueHour.photographyContext.lightingConditions.contains(.blueHour))
        XCTAssertEqual(blueHour.photographyContext.style, .blueHour)
    }

    func testBrightHighShadowLandscapeIsNotMisclassifiedAsNight() {
        let daylight = fixture(
            luminance: 0.48,
            contrast: 0.76,
            saturation: 0.24,
            labels: ["landscape", "mountain", "sky"],
            shadowRatio: 0.62,
            highlightRatio: 0.11
        )

        XCTAssertNotEqual(daylight.semanticScene, .night)
        XCTAssertFalse(daylight.photographyContext.lightingConditions.contains(.night))
    }

    func testLandscapeDynamicRangeIsDrivenByMeasuredClippingInsteadOfFixedFlattening() {
        let balanced = decision(for: fixture(
            luminance: 0.49,
            contrast: 0.62,
            saturation: 0.24,
            labels: ["landscape", "mountain", "sky"],
            shadowRatio: 0.12,
            highlightRatio: 0.06,
            blackRatio: 0.01,
            whiteRatio: 0.01
        ))
        let clipped = decision(for: fixture(
            luminance: 0.58,
            contrast: 0.72,
            saturation: 0.24,
            labels: ["landscape", "mountain", "sky"],
            shadowRatio: 0.12,
            highlightRatio: 0.20,
            blackRatio: 0.01,
            whiteRatio: 0.04
        ))

        XCTAssertGreaterThan(balanced.recipe.highlightAmount, 0.8)
        XCTAssertLessThan(balanced.recipe.shadowAmount, 0.1)
        XCTAssertLessThan(clipped.recipe.highlightAmount, balanced.recipe.highlightAmount)
    }

    func testRegionalStatisticsMeasureOnlyMaskedPixels() throws {
        var pixels: [UInt8] = []
        for index in 0..<16 {
            let pixel: [UInt8] = index < 12 ? [0, 0, 255, 255] : [255, 0, 0, 255]
            pixels.append(contentsOf: pixel)
        }
        let mask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0])
        )

        let statistics = try XCTUnwrap(PhotoRegionStatistics.measure(
            rgbaPixels: pixels,
            width: 4,
            height: 4,
            mask: mask
        ))

        XCTAssertEqual(statistics.redAverage, 0, accuracy: 0.0001)
        XCTAssertEqual(statistics.blueAverage, 1, accuracy: 0.0001)
        XCTAssertEqual(statistics.averageSaturation, 1, accuracy: 0.0001)
        XCTAssertEqual(statistics.shadowRatio, 1, accuracy: 0.0001)
    }

    func testGroundAdjustmentIsDrivenByGroundMeasurements() throws {
        let mask = NormalizedPhotoMask(
            width: 2,
            height: 2,
            pixels: Data([255, 0, 0, 0])
        )
        let darkGround = decision(for: fixture(
            labels: ["landscape", "mountain", "trail"],
            groundMask: mask,
            groundStatistics: regionStatistics(
                luminance: 0.18,
                contrast: 0.32,
                saturation: 0.16,
                red: 0.2,
                green: 0.18,
                blue: 0.15,
                shadowRatio: 0.52
            )
        ))
        let brightGround = decision(for: fixture(
            labels: ["landscape", "mountain", "trail"],
            groundMask: mask,
            groundStatistics: regionStatistics(
                luminance: 0.52,
                contrast: 0.62,
                saturation: 0.16,
                red: 0.4,
                green: 0.38,
                blue: 0.34,
                shadowRatio: 0.05
            )
        ))

        let darkPlan = try XCTUnwrap(darkGround.treatmentPlan.regionalTreatments.first { $0.region == .ground })
        let brightPlan = try XCTUnwrap(brightGround.treatmentPlan.regionalTreatments.first { $0.region == .ground })
        XCTAssertNotEqual(darkPlan.parameters, brightPlan.parameters)
        XCTAssertTrue(darkPlan.parameters.contains("EV=+"))
        XCTAssertTrue(brightPlan.parameters.contains("EV=-"))
    }

    func testRecognitionFailureKeepsMeasuredMaskBackedRegions() {
        let mask = NormalizedPhotoMask(
            width: 2,
            height: 2,
            pixels: Data([255, 0, 0, 0])
        )
        let result = decision(for: fixture(
            labels: ["landscape", "forest", "trail"],
            groundMask: mask,
            vegetationMask: mask,
            groundStatistics: regionStatistics(
                luminance: 0.2,
                contrast: 0.3,
                saturation: 0.18,
                red: 0.2,
                green: 0.2,
                blue: 0.2,
                shadowRatio: 0.45
            ),
            vegetationStatistics: regionStatistics(
                luminance: 0.2,
                contrast: 0.3,
                saturation: 0.18,
                red: 0.18,
                green: 0.24,
                blue: 0.16,
                shadowRatio: 0.45
            ),
            recognition: SceneRecognitionDiagnostics(
                status: .failed,
                topConfidence: 0,
                acceptedLabelCount: 0,
                reason: "test failure"
            )
        ))

        XCTAssertTrue(result.treatmentPlan.regionalTreatments.contains { $0.region == .ground })
        XCTAssertTrue(result.treatmentPlan.regionalTreatments.contains { $0.region == .vegetation })
        XCTAssertEqual(result.recipe.hsl, .neutral)
    }

    func testV8CandidatesComeFromMeasuredProblemsAndAreNotOnePreset() throws {
        let dark = fixture(
            luminance: 0.2,
            contrast: 0.3,
            saturation: 0.16,
            labels: ["landscape", "mountain", "sky"],
            shadowRatio: 0.54
        )
        let bright = fixture(
            luminance: 0.76,
            contrast: 0.72,
            saturation: 0.2,
            labels: ["landscape", "mountain", "sky"],
            highlightRatio: 0.2
        )
        let planner = PhotographyCandidatePlanner()
        let darkProblems = detector.detect(in: dark)
        let brightProblems = detector.detect(in: bright)
        let darkPlans = planner.makePlans(
            decision: engine.makeDecision(for: dark, problems: darkProblems),
            analysis: dark,
            problems: darkProblems
        )
        let brightPlans = planner.makePlans(
            decision: engine.makeDecision(for: bright, problems: brightProblems),
            analysis: bright,
            problems: brightProblems
        )

        XCTAssertGreaterThanOrEqual(darkPlans.count, 2)
        XCTAssertEqual(darkPlans.first?.intent, .natural)
        XCTAssertTrue(darkPlans.contains { $0.intent == .dimensional })
        XCTAssertGreaterThanOrEqual(Set(darkPlans.map { $0.recipe.traceSummary }).count, 2)
        let darkCorrection = try XCTUnwrap(darkPlans.first { $0.intent == .dimensional })
        let brightCorrection = try XCTUnwrap(brightPlans.first { $0.intent == .dimensional })
        XCTAssertGreaterThan(darkCorrection.recipe.exposureEV, brightCorrection.recipe.exposureEV)
        XCTAssertNotEqual(darkCorrection.recipe.traceSummary, brightCorrection.recipe.traceSummary)
        XCTAssertTrue(darkCorrection.adjustments.contains { $0.adjustmentType == .globalExposure })
    }

    func testV8RegionalProblemUsesMaskBackedMeasurements() throws {
        let mask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.58,
            saturation: 0.2,
            labels: ["landscape", "trail", "forest"],
            groundMask: mask,
            groundStatistics: regionStatistics(
                luminance: 0.14,
                contrast: 0.18,
                saturation: 0.15,
                red: 0.15,
                green: 0.14,
                blue: 0.12,
                shadowRatio: 0.62
            )
        )
        let problems = detector.detect(in: analysis)
        let darkGround = try XCTUnwrap(problems.problems.first {
            $0.kind == .regionalUnderexposure && $0.affectedRegions == [.ground]
        })

        XCTAssertGreaterThan(darkGround.confidence, 0.5)
        XCTAssertTrue(darkGround.evidence.contains("ground"))
        let plans = PhotographyCandidatePlanner().makePlans(
            decision: engine.makeDecision(for: analysis, problems: problems),
            analysis: analysis,
            problems: problems
        )
        let targeted = try XCTUnwrap(plans.first { $0.intent == .targeted })
        XCTAssertTrue(targeted.adjustments.contains {
            $0.targetRegion == .ground && $0.adjustmentType == .dodgeAndBurn
        })
    }

    func testV8EditPlanParametersRemainInsideDeclaredBounds() {
        let analysis = fixture(
            luminance: 0.21,
            contrast: 0.28,
            saturation: 0.61,
            labels: ["night", "street", "building"],
            shadowRatio: 0.6,
            highlightRatio: 0.18
        )
        let problems = detector.detect(in: analysis)
        let plans = PhotographyCandidatePlanner().makePlans(
            decision: engine.makeDecision(for: analysis, problems: problems),
            analysis: analysis,
            problems: problems
        )

        for adjustment in plans.flatMap(\.adjustments) {
            XCTAssertGreaterThanOrEqual(adjustment.intensity, adjustment.minimumValue)
            XCTAssertLessThanOrEqual(adjustment.intensity, adjustment.maximumValue)
            XCTAssertGreaterThanOrEqual(adjustment.confidence, 0)
            XCTAssertLessThanOrEqual(adjustment.confidence, 1)
        }
    }

    func testV8EveryPortraitCandidatePreservesHardProtection() {
        let personMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let analysis = fixture(
            luminance: 0.28,
            contrast: 0.72,
            saturation: 0.24,
            labels: ["portrait", "person", "sky"],
            faceCount: 1,
            faceLuminance: 0.2,
            backgroundLuminance: 0.42,
            personMask: personMask
        )
        let problems = detector.detect(in: analysis)
        let plans = PhotographyCandidatePlanner().makePlans(
            decision: engine.makeDecision(for: analysis, problems: problems),
            analysis: analysis,
            problems: problems
        )

        for plan in plans {
            XCTAssertEqual(plan.recipe.faceExposureEV, 0)
            XCTAssertLessThanOrEqual(plan.recipe.subjectExposureEV, 0.15)
            XCTAssertGreaterThanOrEqual(plan.recipe.skinTextureProtection, 0.72)
            XCTAssertEqual(plan.recipe.hsl.orangeLuminance, 0)
            XCTAssertEqual(plan.recipe.hsl.orangeHue, 0)
            XCTAssertEqual(plan.recipe.hsl.orangeSaturation, 0)
            XCTAssertLessThanOrEqual(plan.recipe.colorGradeIntensity, 0.055)
        }
    }

    func testCandidateSelectorRejectsTechnicallyFailedHigherScore() throws {
        let rejected = PhotographyCandidateEvaluation(
            planID: "rejected",
            title: "过强候选",
            status: .rejected,
            score: 99,
            problemImprovement: 1,
            preservationScore: 0.2,
            issues: ["clippedHighlights"],
            reason: "技术质量失败",
            durationMilliseconds: 10,
            selected: false
        )
        let accepted = PhotographyCandidateEvaluation(
            planID: "accepted",
            title: "自然候选",
            status: .passed,
            score: 72,
            problemImprovement: 0.7,
            preservationScore: 0.9,
            issues: [],
            reason: "问题改善且保真",
            durationMilliseconds: 12,
            selected: false
        )

        let selected = try XCTUnwrap(PhotographyCandidateSelector().select(from: [rejected, accepted]))
        XCTAssertEqual(selected.planID, "accepted")
    }

    func testProblemImprovementDoesNotRewardUnchangedImage() {
        let analysis = fixture(
            luminance: 0.21,
            contrast: 0.3,
            saturation: 0.2,
            labels: ["landscape"],
            shadowRatio: 0.58
        )
        let problems = detector.detect(in: analysis)

        let score = PhotographyProblemImprovementScorer().score(
            problems: problems,
            source: analysis,
            edited: analysis,
            regionImpacts: []
        )

        XCTAssertEqual(score, 0, accuracy: 0.0001)
    }

    func testProblemImprovementRewardsOnlyCorrectMeasuredDirection() {
        let source = fixture(
            luminance: 0.21,
            contrast: 0.52,
            saturation: 0.2,
            labels: ["landscape"],
            shadowRatio: 0.12
        )
        let brighter = fixture(
            luminance: 0.27,
            contrast: 0.52,
            saturation: 0.2,
            labels: ["landscape"],
            shadowRatio: 0.12
        )
        let darker = fixture(
            luminance: 0.17,
            contrast: 0.52,
            saturation: 0.2,
            labels: ["landscape"],
            shadowRatio: 0.12
        )
        let underexposure = PhotoProblemReport(problems: [PhotoProblem(
            kind: .underexposed,
            severity: .strong,
            evidence: "fixture",
            confidence: 1
        )])
        let scorer = PhotographyProblemImprovementScorer()

        XCTAssertGreaterThan(
            scorer.score(
                problems: underexposure,
                source: source,
                edited: brighter,
                regionImpacts: []
            ),
            0
        )
        XCTAssertEqual(
            scorer.score(
                problems: underexposure,
                source: source,
                edited: darker,
                regionImpacts: []
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testRegionalProblemWithoutMeasuredImpactGetsNoImprovementCredit() {
        let mask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.58,
            saturation: 0.2,
            labels: ["landscape", "trail"],
            groundMask: mask,
            groundStatistics: regionStatistics(
                luminance: 0.14,
                contrast: 0.18,
                saturation: 0.15,
                red: 0.15,
                green: 0.14,
                blue: 0.12,
                shadowRatio: 0.62
            )
        )
        let regionalProblems = PhotoProblemReport(problems: detector.detect(in: analysis).problems.filter {
            $0.kind == .regionalUnderexposure || $0.kind == .regionalFlatness
        })

        let score = PhotographyProblemImprovementScorer().score(
            problems: regionalProblems,
            source: analysis,
            edited: analysis,
            regionImpacts: []
        )

        XCTAssertEqual(score, 0, accuracy: 0.0001)
    }

    func testReliableSalientSubjectDrivesMeasuredLocalAdjustment() throws {
        let subjectMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                0, 0, 0, 0,
                0, 255, 255, 0,
                0, 255, 255, 0,
                0, 0, 0, 0
            ])
        )
        let subjectStatistics = regionStatistics(
            luminance: 0.24,
            contrast: 0.28,
            saturation: 0.34,
            red: 0.4,
            green: 0.23,
            blue: 0.12,
            shadowRatio: 0.48
        )
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.56,
            saturation: 0.18,
            labels: ["outdoor", "garden", "fruit"],
            salientSubjectMask: subjectMask,
            salientSubjectStatistics: subjectStatistics
        )
        let problems = detector.detect(in: analysis)
        let decision = engine.makeDecision(for: analysis, problems: problems)
        let adjustment = try XCTUnwrap(RegionalPixelAdjustment.make(
            region: .subject,
            analysis: analysis,
            recipe: decision.recipe
        ))

        XCTAssertGreaterThan(analysis.salientSubjectPriorityConfidence, 0.54)
        XCTAssertTrue(problems.problems.contains {
            $0.kind == .regionalUnderexposure && $0.affectedRegions == [.subject]
        })
        XCTAssertGreaterThan(adjustment.exposureEV, 0)
        XCTAssertGreaterThan(adjustment.contrast, 1)
        XCTAssertTrue(decision.treatmentPlan.regionalTreatments.contains { $0.region == .subject })
    }

    func testBroadSaliencyMaskIsNotTreatedAsReliableSubject() {
        let broadMask = NormalizedPhotoMask(
            width: 2,
            height: 2,
            pixels: Data([255, 255, 255, 255])
        )
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.56,
            saturation: 0.18,
            labels: ["outdoor"],
            salientSubjectMask: broadMask,
            salientSubjectStatistics: regionStatistics(
                luminance: 0.3,
                contrast: 0.3,
                saturation: 0.2,
                red: 0.3,
                green: 0.3,
                blue: 0.3
            )
        )

        XCTAssertEqual(analysis.salientSubjectPriorityConfidence, 0)
        XCTAssertNil(RegionalPixelAdjustment.make(
            region: .subject,
            analysis: analysis,
            recipe: decision(for: analysis).recipe
        ))
    }

    func testV81PersimmonLikeProfileDoesNotLetMinorArchitectureWin() throws {
        let vegetation = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                255, 255, 255, 255,
                255, 255, 255, 255,
                255, 0, 0, 0,
                0, 0, 0, 0
            ])
        )
        let architecture = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 255
            ])
        )
        let ground = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                0, 0, 0, 0,
                0, 0, 0, 0,
                255, 255, 0, 0,
                255, 255, 255, 0
            ])
        )
        let subject = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                255, 255, 0, 0,
                255, 255, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0
            ])
        )
        let analysis = fixture(
            luminance: 0.45,
            contrast: 0.83,
            saturation: 0.22,
            labels: ["outdoor", "sky", "cloudy", "plant"],
            skyCoverage: 0.069,
            salientSubjectMask: subject,
            salientSubjectStatistics: regionStatistics(
                luminance: 0.28,
                contrast: 0.34,
                saturation: 0.4,
                red: 0.48,
                green: 0.27,
                blue: 0.14,
                shadowRatio: 0.38
            ),
            groundMask: ground,
            vegetationMask: vegetation,
            architectureMask: architecture,
            groundStatistics: regionStatistics(
                luminance: 0.53,
                contrast: 0.67,
                saturation: 0.19,
                red: 0.55,
                green: 0.53,
                blue: 0.47
            ),
            vegetationStatistics: regionStatistics(
                luminance: 0.35,
                contrast: 0.84,
                saturation: 0.24,
                red: 0.35,
                green: 0.36,
                blue: 0.32
            ),
            architectureStatistics: regionStatistics(
                luminance: 0.53,
                contrast: 0.74,
                saturation: 0.13,
                red: 0.52,
                green: 0.53,
                blue: 0.53
            ),
            segmentation: SceneSegmentationDiagnostics(
                status: .available,
                reason: nil,
                skyCoverage: 0.069,
                groundCoverage: 0.3125,
                vegetationCoverage: 0.5625,
                waterCoverage: 0,
                architectureCoverage: 0.0625
            )
        )
        let context = analysis.photographyContext
        let result = decision(for: analysis)

        XCTAssertEqual(context.style, .naturalDocumentary)
        XCTAssertLessThan(context.sceneProfile.urbanArchitectureTendency, 0.12)
        XCTAssertGreaterThan(
            context.sceneProfile.naturalDocumentaryTendency,
            context.sceneProfile.urbanArchitectureTendency
        )
        XCTAssertTrue(result.treatmentPlan.regionalTreatments.contains { $0.region == .subject })
        let subjectAdjustment = try XCTUnwrap(
            RegionalPixelAdjustment.make(region: .subject, analysis: analysis, recipe: result.recipe)
        )
        XCTAssertGreaterThan(subjectAdjustment.exposureEV, 0)
    }

    func testV81SceneConfidenceIsNotReusedAsSubjectConfidence() {
        let analysis = fixture(
            labels: ["outdoor", "sky", "cloudy", "plant"],
            recognition: SceneRecognitionDiagnostics(
                status: .recognized,
                topConfidence: 1,
                acceptedLabelCount: 4,
                reason: nil
            )
        )

        XCTAssertEqual(analysis.photographyContext.primarySubjectConfidence, 0, accuracy: 0.0001)
        XCTAssertEqual(analysis.subjectPriorityProfile.mode, .globalHarmony)
    }

    func testV81AestheticScorerRewardsSubjectSeparationOverWeakChange() {
        let subjectMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                0, 0, 0, 0,
                0, 255, 255, 0,
                0, 255, 255, 0,
                0, 0, 0, 0
            ])
        )
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.56,
            saturation: 0.18,
            labels: ["outdoor", "garden", "fruit"],
            salientSubjectMask: subjectMask,
            salientSubjectStatistics: regionStatistics(
                luminance: 0.24,
                contrast: 0.28,
                saturation: 0.34,
                red: 0.4,
                green: 0.23,
                blue: 0.12,
                shadowRatio: 0.48
            )
        )
        let scorer = PhotographyAestheticProgressScorer()
        let weak = scorer.score(source: analysis, regionImpacts: [
            PhotographyRegionImpact(
                region: .subject,
                maskCoverage: 0.25,
                luminanceDelta: 0.003,
                colorDelta: 0.002,
                contrastDelta: 0.001,
                changedPixelRatio: 0.05
            )
        ])
        let improved = scorer.score(source: analysis, regionImpacts: [
            PhotographyRegionImpact(
                region: .subject,
                maskCoverage: 0.25,
                luminanceDelta: 0.04,
                colorDelta: 0.022,
                contrastDelta: 0.014,
                changedPixelRatio: 0.62
            ),
            PhotographyRegionImpact(
                region: .vegetation,
                maskCoverage: 0.5,
                luminanceDelta: 0.012,
                colorDelta: 0.01,
                contrastDelta: 0.004,
                changedPixelRatio: 0.35
            )
        ])

        XCTAssertGreaterThan(improved.subjectPriority, weak.subjectPriority)
        XCTAssertTrue(improved.hasMeaningfulProgress)
    }

    func testV9SameSceneDifferentExposureProducesDifferentMeasuredTargets() throws {
        let dark = fixture(
            luminance: 0.2,
            contrast: 0.42,
            saturation: 0.2,
            labels: ["outdoor", "landscape"],
            shadowRatio: 0.55
        )
        let bright = fixture(
            luminance: 0.79,
            contrast: 0.42,
            saturation: 0.2,
            labels: ["outdoor", "landscape"],
            highlightRatio: 0.24
        )

        let darkDecision = decision(for: dark)
        let brightDecision = decision(for: bright)
        let darkExposure = try XCTUnwrap(darkDecision.parameterEvidence.first { $0.key == .exposure })
        let brightExposure = try XCTUnwrap(brightDecision.parameterEvidence.first { $0.key == .exposure })

        XCTAssertGreaterThan(darkDecision.recipe.exposureEV, 0)
        XCTAssertLessThan(brightDecision.recipe.exposureEV, 0)
        XCTAssertNotEqual(darkExposure.inputEvidence, brightExposure.inputEvidence)
        XCTAssertNotEqual(darkExposure.actualValue, brightExposure.actualValue)
    }

    func testAdaptiveSolverProducesSameTechnicalRecipeForDifferentLabelsWithIdenticalPixels() {
        let landscape = decision(for: fixture(
            luminance: 0.39,
            contrast: 0.43,
            saturation: 0.21,
            red: 0.43,
            green: 0.45,
            blue: 0.46,
            labels: ["landscape", "mountain"]
        ))
        let architecture = decision(for: fixture(
            luminance: 0.39,
            contrast: 0.43,
            saturation: 0.21,
            red: 0.43,
            green: 0.45,
            blue: 0.46,
            labels: ["building", "architecture"]
        ))

        XCTAssertNotEqual(landscape.sceneStrategy, architecture.sceneStrategy)
        XCTAssertEqual(landscape.adaptiveTarget, architecture.adaptiveTarget)
        XCTAssertEqual(landscape.recipe, architecture.recipe)
    }

    func testAdaptiveSolverLimitsShadowLiftWhenNoiseIsHigh() {
        let clean = decision(for: fixture(
            luminance: 0.24,
            contrast: 0.36,
            saturation: 0.18,
            labels: ["outdoor"],
            shadowRatio: 0.52,
            noiseEstimate: 0.04
        ))
        let noisy = decision(for: fixture(
            luminance: 0.24,
            contrast: 0.36,
            saturation: 0.18,
            labels: ["outdoor"],
            shadowRatio: 0.52,
            noiseEstimate: 0.24
        ))

        XCTAssertGreaterThan(clean.recipe.shadowAmount, noisy.recipe.shadowAmount)
        XCTAssertGreaterThan(clean.recipe.shadowZoneExposureEV, noisy.recipe.shadowZoneExposureEV)
        XCTAssertGreaterThan(noisy.recipe.noiseReductionAmount, clean.recipe.noiseReductionAmount)
    }

    func testAdaptiveSolverMovesContrastInMeasuredDirection() {
        let flat = decision(for: fixture(
            luminance: 0.46,
            contrast: 0.24,
            saturation: 0.22,
            labels: ["outdoor"]
        ))
        let harsh = decision(for: fixture(
            luminance: 0.46,
            contrast: 0.82,
            saturation: 0.22,
            labels: ["outdoor"],
            shadowRatio: 0.3,
            highlightRatio: 0.2
        ))

        XCTAssertGreaterThan(flat.recipe.contrast, 1)
        XCTAssertGreaterThan(flat.recipe.localContrastAmount, 0)
        XCTAssertLessThan(harsh.recipe.contrast, 1)
        XCTAssertEqual(harsh.recipe.localContrastAmount, 0, accuracy: 0.0001)
    }

    func testBalancedImageDoesNotReceiveThreeFixedCandidates() {
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.57,
            saturation: 0.28,
            red: 0.46,
            green: 0.47,
            blue: 0.47,
            labels: ["outdoor"],
            shadowRatio: 0.1,
            highlightRatio: 0.06,
            blackRatio: 0.01,
            whiteRatio: 0.01,
            detailScore: 0.22,
            noiseEstimate: 0.04
        )
        let problems = detector.detect(in: analysis)
        let plans = PhotographyCandidatePlanner().makePlans(
            decision: engine.makeDecision(for: analysis, problems: problems),
            analysis: analysis,
            problems: problems
        )

        XCTAssertEqual(plans.first?.intent, .natural)
        XCTAssertLessThan(plans.count, PhotographyCandidateIntent.allCases.count)
    }

    func testParameterEvidenceIncludesRegionAndDecisionState() {
        let result = decision(for: fixture(
            luminance: 0.25,
            contrast: 0.3,
            saturation: 0.18,
            labels: ["outdoor"],
            shadowRatio: 0.46
        ))

        XCTAssertTrue(result.parameterEvidence.contains {
            $0.key == .exposure && $0.affectedRegion == .global && $0.decisionStatus == .planned
        })
        XCTAssertTrue(result.parameterEvidence.contains { $0.key == .localExposure })
    }

    func testV9SameIndoorSceneDifferentCastProducesOppositeWhiteBalance() {
        let cool = fixture(
            red: 0.34,
            green: 0.46,
            blue: 0.58,
            labels: ["indoor", "room"],
            neutralColorStatistics: neutralStatistics(red: 0.43, green: 0.47, blue: 0.51)
        )
        let warm = fixture(
            red: 0.58,
            green: 0.46,
            blue: 0.34,
            labels: ["indoor", "room"],
            neutralColorStatistics: neutralStatistics(red: 0.51, green: 0.47, blue: 0.43)
        )

        let coolDecision = decision(for: cool)
        let warmDecision = decision(for: warm)

        XCTAssertGreaterThan(coolDecision.recipe.temperatureShift, 0)
        XCTAssertLessThan(warmDecision.recipe.temperatureShift, 0)
        XCTAssertNotEqual(coolDecision.recipe.temperatureShift, warmDecision.recipe.temperatureShift)
    }

    func testWhiteBalanceIgnoresGlobalSubjectColorWithoutReliableNeutralEvidence() {
        let orangeDominant = fixture(
            red: 0.62,
            green: 0.42,
            blue: 0.28,
            labels: ["indoor", "still life"]
        )

        let report = detector.detect(in: orangeDominant)
        let result = engine.makeDecision(for: orangeDominant, problems: report)

        XCTAssertFalse(report.contains(.warmCast))
        XCTAssertEqual(result.recipe.temperatureShift, 0, accuracy: 0.0001)
        XCTAssertTrue(result.parameterEvidence.first { $0.key == .temperature }?
            .inputEvidence.contains("无中性色样本") == true)
    }

    func testMixedLightReducesNeutralEvidenceWhiteBalanceMagnitude() {
        let neutral = neutralStatistics(red: 0.43, green: 0.47, blue: 0.51)
        let uniform = fixture(
            red: 0.4,
            green: 0.48,
            blue: 0.56,
            labels: ["indoor", "room"],
            mixedLightScore: 0,
            neutralColorStatistics: neutral
        )
        let mixed = fixture(
            red: 0.4,
            green: 0.48,
            blue: 0.56,
            labels: ["indoor", "room"],
            mixedLightScore: 0.38,
            neutralColorStatistics: neutral
        )

        XCTAssertGreaterThan(
            abs(decision(for: uniform).recipe.temperatureShift),
            abs(decision(for: mixed).recipe.temperatureShift)
        )
    }

    func testWhiteBalanceEvidenceLinksPersistentKnowledgeRules() throws {
        let analysis = fixture(
            red: 0.4,
            green: 0.47,
            blue: 0.55,
            labels: ["indoor"],
            neutralColorStatistics: neutralStatistics(red: 0.43, green: 0.47, blue: 0.51)
        )
        let evidence = try XCTUnwrap(
            decision(for: analysis).parameterEvidence.first { $0.key == .temperature }
        )

        XCTAssertTrue(evidence.knowledgeRuleIDs.contains(.neutralEvidenceWhiteBalance))
        XCTAssertTrue(evidence.knowledgeRuleIDs.contains(.mixedLightPreservation))
        XCTAssertTrue(evidence.knowledgeRuleIDs.contains(.skinIsNotNeutralReference))
    }

    func testV9CandidatesDoNotUniformlyScaleWhiteBalanceOrHSL() {
        let skyMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let analysis = fixture(
            luminance: 0.4,
            contrast: 0.26,
            saturation: 0.18,
            red: 0.34,
            green: 0.44,
            blue: 0.57,
            labels: ["outdoor", "sky", "landscape"],
            skyMask: skyMask,
            skyStatistics: regionStatistics(
                luminance: 0.62,
                contrast: 0.3,
                saturation: 0.16,
                red: 0.42,
                green: 0.53,
                blue: 0.66
            )
        )
        let problems = detector.detect(in: analysis)
        let plans = PhotographyCandidatePlanner().makePlans(
            decision: engine.makeDecision(for: analysis, problems: problems),
            analysis: analysis,
            problems: problems
        )

        XCTAssertEqual(Set(plans.map { $0.recipe.temperatureShift }).count, 1)
        XCTAssertEqual(Set(plans.map { $0.recipe.tintShift }).count, 1)
        XCTAssertTrue(plans.dropFirst().allSatisfy { $0.recipe.hsl == plans[0].recipe.hsl })
        XCTAssertGreaterThanOrEqual(Set(plans.map { $0.recipe.traceSummary }).count, 2)
        XCTAssertTrue(plans.allSatisfy { !$0.parameterEvidence.isEmpty })
    }

    func testV9RegionalTargetFollowsGlobalRelationshipInsteadOfFixedPreset() throws {
        let groundMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255, 255, 0, 0]))
        let groundStats = regionStatistics(
            luminance: 0.32,
            contrast: 0.28,
            saturation: 0.16,
            red: 0.33,
            green: 0.32,
            blue: 0.3,
            shadowRatio: 0.44
        )
        let darkerEnvironment = fixture(
            luminance: 0.36,
            contrast: 0.5,
            saturation: 0.2,
            labels: ["outdoor", "road"],
            groundMask: groundMask,
            groundStatistics: groundStats
        )
        let brighterEnvironment = fixture(
            luminance: 0.58,
            contrast: 0.5,
            saturation: 0.2,
            labels: ["outdoor", "road"],
            groundMask: groundMask,
            groundStatistics: groundStats
        )

        let darkAdjustment = try XCTUnwrap(RegionalPixelAdjustment.make(
            region: .ground,
            analysis: darkerEnvironment,
            recipe: decision(for: darkerEnvironment).recipe
        ))
        let brightAdjustment = try XCTUnwrap(RegionalPixelAdjustment.make(
            region: .ground,
            analysis: brighterEnvironment,
            recipe: decision(for: brighterEnvironment).recipe
        ))

        XCTAssertGreaterThan(brightAdjustment.exposureEV, darkAdjustment.exposureEV)
        XCTAssertTrue(brightAdjustment.reason.contains("相对关系"))
    }

    func testV9MissingSubjectAndInvalidMaskUseAuditableSafeFallback() {
        let invalidMask = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255]))
        let analysis = fixture(
            luminance: 0.26,
            contrast: 0.3,
            saturation: 0.18,
            labels: ["outdoor"],
            salientSubjectMask: invalidMask,
            salientSubjectStatistics: regionStatistics(
                luminance: 0.12,
                contrast: 0.15,
                saturation: 0.2,
                red: 0.2,
                green: 0.15,
                blue: 0.12
            ),
            recognition: SceneRecognitionDiagnostics(
                status: .failed,
                topConfidence: 0,
                acceptedLabelCount: 0,
                reason: "fixture failure"
            ),
            segmentation: SceneSegmentationDiagnostics(
                status: .failed,
                reason: "fixture failure",
                skyCoverage: 0,
                groundCoverage: 0,
                vegetationCoverage: 0,
                waterCoverage: 0,
                architectureCoverage: 0
            )
        )
        let result = decision(for: analysis)

        XCTAssertEqual(analysis.subjectPriorityProfile.mode, .globalHarmony)
        XCTAssertNil(RegionalPixelAdjustment.make(region: .subject, analysis: analysis, recipe: result.recipe))
        XCTAssertFalse(result.parameterEvidence.isEmpty)
        XCTAssertGreaterThan(result.recipe.luminanceMaskStrength, 0)
        XCTAssertTrue(result.actions.contains { $0.title.contains("场景识别失败") })
        XCTAssertTrue(result.actions.contains { $0.title.contains("局部分割降级") })
    }

    func testV9ParameterEvidenceMatchesExecutableRecipe() throws {
        let result = decision(for: fixture(
            luminance: 0.24,
            contrast: 0.27,
            saturation: 0.17,
            labels: ["indoor", "room"],
            shadowRatio: 0.48,
            detailScore: 0.1,
            noiseEstimate: 0.16
        ))

        func value(_ key: PhotographyParameterKey) throws -> Float {
            try XCTUnwrap(result.parameterEvidence.first { $0.key == key }).actualValue
        }

        XCTAssertEqual(try value(.exposure), result.recipe.exposureEV, accuracy: 0.0001)
        XCTAssertEqual(try value(.highlights), result.recipe.highlightAmount, accuracy: 0.0001)
        XCTAssertEqual(try value(.shadows), result.recipe.shadowAmount, accuracy: 0.0001)
        XCTAssertEqual(try value(.whitePoint), result.recipe.whitePoint, accuracy: 0.0001)
        XCTAssertEqual(try value(.blackPoint), result.recipe.blackPoint, accuracy: 0.0001)
        XCTAssertEqual(try value(.noiseReduction), result.recipe.noiseReductionAmount, accuracy: 0.0001)
        XCTAssertEqual(try value(.sharpening), result.recipe.sharpeningAmount, accuracy: 0.0001)
    }

    func testV9MaskQualityReportsInvalidBroadAndFragmentedMasks() {
        let invalid = NormalizedPhotoMask(width: 2, height: 2, pixels: Data([255]))
        let broad = NormalizedPhotoMask(width: 2, height: 2, pixels: Data(repeating: 255, count: 4))
        let checkerboardPixels = (0..<64).map { index -> UInt8 in
            let x = index % 8
            let y = index / 8
            return (x + y).isMultiple(of: 2) ? 255 : 0
        }
        let fragmented = NormalizedPhotoMask(width: 8, height: 8, pixels: Data(checkerboardPixels))

        XCTAssertFalse(invalid.qualityAssessment.isUsable)
        XCTAssertFalse(broad.qualityAssessment.isUsable)
        XCTAssertLessThan(fragmented.qualityAssessment.reliability, 0.72)
        XCTAssertTrue(fragmented.qualityAssessment.reason.contains("边界密度"))
    }

    func testReferenceMatcherUsesMetricsAndKeepsProductionGateClosed() {
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.56,
            saturation: 0.22,
            red: 0.47,
            green: 0.48,
            blue: 0.49,
            labels: ["outdoor", "landscape", "sky"]
        )
        let index = referenceIndex(records: [
            referenceRecord(
                id: "close",
                luminance: 0.47,
                contrast: 0.55,
                saturation: 0.23,
                categories: ["landscape", "outdoor"]
            ),
            referenceRecord(
                id: "far",
                luminance: 0.14,
                contrast: 0.22,
                saturation: 0.62,
                categories: ["night", "abstract"]
            )
        ])

        let validation = PhotographyReferenceMatcher(
            index: index,
            usageMode: .diagnosticValidation
        ).match(analysis: analysis)
        XCTAssertEqual(validation.status, .matchedForValidation)
        XCTAssertEqual(validation.matches.first?.record.id, "close")
        XCTAssertGreaterThan(validation.matches.first?.metricSimilarity ?? 0, 0.8)
        XCTAssertTrue(validation.matches.first?.nonTransferableFeatures.contains("absolute HSL values") == true)

        let production = PhotographyReferenceMatcher(
            index: index,
            usageMode: .production
        ).match(analysis: analysis)
        XCTAssertEqual(production.status, .prohibitedByUsagePolicy)
        XCTAssertTrue(production.matches.isEmpty)
    }

    func testReferenceTargetIsBoundedAndActuallyFeedsTheExistingSolver() {
        let analysis = fixture(
            luminance: 0.39,
            contrast: 0.43,
            saturation: 0.18,
            labels: ["outdoor", "landscape", "cloudy"]
        )
        let problems = detector.detect(in: analysis)
        let matcher = PhotographyReferenceMatcher(
            index: referenceIndex(records: [
                referenceRecord(
                    id: "reference-a",
                    luminance: 0.46,
                    contrast: 0.54,
                    saturation: 0.24,
                    categories: ["landscape", "outdoor"]
                )
            ]),
            usageMode: .diagnosticValidation
        )
        let match = matcher.match(analysis: analysis)
        let profile = PhotographyReferenceTargetGenerator().makeProfile(
            analysis: analysis,
            problems: problems,
            matchResult: match
        )
        let baseline = engine.makeDecision(for: analysis, problems: problems)
        let referenceDecision = engine.makeDecision(
            for: analysis,
            problems: problems,
            targetProfile: profile
        )

        XCTAssertTrue(profile.referenceApplied)
        XCTAssertLessThanOrEqual(abs(profile.resolvedTarget.luminance - profile.baselineTarget.luminance), 0.0141)
        XCTAssertLessThanOrEqual(abs(profile.resolvedTarget.contrast - profile.baselineTarget.contrast), 0.0141)
        XCTAssertNotEqual(referenceDecision.adaptiveTarget, baseline.adaptiveTarget)
        XCTAssertTrue(referenceDecision.actions.contains { $0.title.contains("摄影参考目标校准") })
        XCTAssertTrue(referenceDecision.parameterEvidence.contains {
            $0.knowledgeRuleIDs.contains(.referenceTargetCalibration)
        })
        XCTAssertEqual(referenceDecision.recipe.temperatureShift, baseline.recipe.temperatureShift)
        XCTAssertEqual(referenceDecision.recipe.tintShift, baseline.recipe.tintShift)
    }

    func testReferenceCompositionProxyOnlyCalibratesFromCurrentSubjectRelationship() throws {
        let subjectMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                0, 0, 0, 0,
                0, 255, 255, 0,
                0, 255, 255, 0,
                0, 0, 0, 0
            ])
        )
        let analysis = fixture(
            luminance: 0.46,
            contrast: 0.55,
            saturation: 0.21,
            labels: ["outdoor", "nature"],
            salientSubjectMask: subjectMask,
            salientSubjectStatistics: regionStatistics(
                luminance: 0.24,
                contrast: 0.32,
                saturation: 0.31,
                red: 0.42,
                green: 0.30,
                blue: 0.18
            )
        )
        let currentDelta = Float(0.24 - 0.46)
        let match = PhotographyReferenceMatcher(
            index: referenceIndex(records: [
                referenceRecord(
                    id: "composition-proxy",
                    luminance: 0.47,
                    contrast: 0.54,
                    saturation: 0.22,
                    categories: ["nature", "outdoor"]
                )
            ]),
            usageMode: .diagnosticValidation
        ).match(analysis: analysis)
        let profile = PhotographyReferenceTargetGenerator().makeProfile(
            analysis: analysis,
            problems: detector.detect(in: analysis),
            matchResult: match
        )
        let targetDelta = try XCTUnwrap(profile.subjectBackgroundDeltaTarget)

        XCTAssertTrue(profile.referenceApplied)
        XCTAssertLessThanOrEqual(abs(targetDelta - currentDelta), 0.0351)
        XCTAssertLessThan(targetDelta, -0.15)
    }

    private func decision(for analysis: PhotoAnalysis) -> PhotographyDecision {
        engine.makeDecision(for: analysis, problems: detector.detect(in: analysis))
    }

    private func referenceIndex(
        records: [PhotographyReferenceFeatureRecord]
    ) -> PhotographyReferenceIndexDocument {
        PhotographyReferenceIndexDocument(
            schemaVersion: 1,
            usageScope: "diagnostic_reference_matching_only",
            productionUseAllowed: false,
            modelTrainingAllowed: false,
            referencePixelsBundled: false,
            records: records
        )
    }

    private func referenceRecord(
        id: String,
        luminance: Float,
        contrast: Float,
        saturation: Float,
        categories: [String]
    ) -> PhotographyReferenceFeatureRecord {
        PhotographyReferenceFeatureRecord(
            id: id,
            usage: PhotographyReferenceUsage(
                validationModeAllowed: true,
                productionUseAllowed: false,
                modelTrainingAllowed: false,
                reason: "test fixture"
            ),
            license: PhotographyReferenceLicenseSummary(
                name: "CC0",
                url: "https://creativecommons.org/publicdomain/zero/1.0/",
                attributionRequired: false,
                shareAlike: false
            ),
            source: PhotographyReferenceSourceSummary(
                pageUrl: "https://example.invalid/\(id)",
                creator: "fixture",
                title: id
            ),
            semantics: PhotographyReferenceSemantics(
                categories: categories,
                subjects: [],
                lighting: [],
                annotationStatus: "test"
            ),
            vector: PhotographyReferenceFeatureVector(
                averageLuminance: luminance,
                contrastRange: contrast,
                shadowRatio: 0.12,
                highlightRatio: 0.08,
                averageSaturation: saturation,
                redAverage: 0.47,
                greenAverage: 0.48,
                blueAverage: 0.49,
                neutralCoverage: 0.18,
                warmPixelRatio: 0.18,
                coolPixelRatio: 0.2,
                localContrast: 0.12,
                gradientEnergy: 0.04,
                centerLuminanceDelta: 0.03,
                centerSaturationDelta: 0.01
            ),
            nonTransferable: ["absolute HSL values", "tone curve"]
        )
    }

    private func fixture(
        luminance: Float = 0.5,
        contrast: Float = 0.58,
        saturation: Float = 0.2,
        red: Float = 0.46,
        green: Float = 0.48,
        blue: Float = 0.49,
        labels: [String],
        skyMask: NormalizedPhotoMask? = nil,
        skyCoverage: Float? = nil,
        faceCount: Int = 0,
        faceLuminance: Float? = nil,
        backgroundLuminance: Float? = nil,
        personMask: NormalizedPhotoMask? = nil,
        salientSubjectMask: NormalizedPhotoMask? = nil,
        salientSubjectStatistics: PhotoRegionStatistics? = nil,
        groundMask: NormalizedPhotoMask? = nil,
        vegetationMask: NormalizedPhotoMask? = nil,
        waterMask: NormalizedPhotoMask? = nil,
        architectureMask: NormalizedPhotoMask? = nil,
        skyStatistics: PhotoRegionStatistics? = nil,
        groundStatistics: PhotoRegionStatistics? = nil,
        vegetationStatistics: PhotoRegionStatistics? = nil,
        waterStatistics: PhotoRegionStatistics? = nil,
        architectureStatistics: PhotoRegionStatistics? = nil,
        shadowRatio: Float = 0.12,
        highlightRatio: Float = 0.08,
        blackRatio: Float = 0.01,
        whiteRatio: Float = 0.01,
        detailScore: Float = 0.22,
        noiseEstimate: Float = 0.05,
        midtoneRatio: Float = 0.7,
        mixedLightScore: Float = 0.05,
        spatialLuminanceVariance: Float = 0.08,
        neutralColorStatistics: NeutralColorStatistics? = nil,
        recognition: SceneRecognitionDiagnostics = SceneRecognitionDiagnostics(
            status: .recognized,
            topConfidence: 0.8,
            acceptedLabelCount: 1,
            reason: nil
        ),
        segmentation: SceneSegmentationDiagnostics = .notEvaluated
    ) -> PhotoAnalysis {
        PhotoAnalysis(
            averageLuminance: luminance,
            contrastRange: contrast,
            redAverage: red,
            greenAverage: green,
            blueAverage: blue,
            shadowRatio: shadowRatio,
            highlightRatio: highlightRatio,
            averageSaturation: saturation,
            detailScore: detailScore,
            noiseEstimate: noiseEstimate,
            blackRatio: blackRatio,
            whiteRatio: whiteRatio,
            midtoneRatio: midtoneRatio,
            mixedLightScore: mixedLightScore,
            highlightConcentration: 0.05,
            highlightSourceCount: 0,
            highlightCentroidX: 0.5,
            highlightCentroidY: 0.5,
            spatialLuminanceVariance: spatialLuminanceVariance,
            faceCount: faceCount,
            faceRegions: faceCount > 0
                ? [NormalizedPhotoRegion(x: 0.3, y: 0.35, width: 0.25, height: 0.25)]
                : [],
            faceAverageLuminance: faceLuminance,
            backgroundAverageLuminance: backgroundLuminance,
            personMask: personMask,
            salientSubjectMask: salientSubjectMask,
            salientSubjectStatistics: salientSubjectStatistics,
            skinMask: nil,
            skyMask: skyMask,
            skyCoverage: skyCoverage ?? (skyMask == nil ? 0 : 0.38),
            groundMask: groundMask,
            vegetationMask: vegetationMask,
            waterMask: waterMask,
            architectureMask: architectureMask,
            skyStatistics: skyStatistics,
            groundStatistics: groundStatistics,
            vegetationStatistics: vegetationStatistics,
            waterStatistics: waterStatistics,
            architectureStatistics: architectureStatistics,
            semanticLabels: labels.map { SceneLabel(identifier: $0, confidence: 0.8) },
            sceneRecognitionDiagnostics: recognition,
            segmentationDiagnostics: segmentation,
            neutralColorStatistics: neutralColorStatistics
        )
    }

    private func neutralStatistics(
        red: Float,
        green: Float,
        blue: Float,
        coverage: Float = 0.08,
        spatialZoneCoverage: Float = 0.66,
        confidence: Float = 0.82
    ) -> NeutralColorStatistics {
        NeutralColorStatistics(
            sampleCount: 320,
            coverage: coverage,
            spatialZoneCoverage: spatialZoneCoverage,
            redAverage: red,
            greenAverage: green,
            blueAverage: blue,
            averageLuminance: (red + green + blue) / 3,
            averageChroma: max(red, green, blue) - min(red, green, blue),
            confidence: confidence
        )
    }

    private func regionStatistics(
        luminance: Float,
        contrast: Float,
        saturation: Float,
        red: Float,
        green: Float,
        blue: Float,
        shadowRatio: Float = 0.02,
        highlightRatio: Float = 0.06
    ) -> PhotoRegionStatistics {
        PhotoRegionStatistics(
            averageLuminance: luminance,
            contrastRange: contrast,
            redAverage: red,
            greenAverage: green,
            blueAverage: blue,
            averageSaturation: saturation,
            shadowRatio: shadowRatio,
            highlightRatio: highlightRatio
        )
    }
}
