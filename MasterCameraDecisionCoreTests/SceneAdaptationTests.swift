import XCTest
import CoreGraphics
import CoreImage
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
        XCTAssertEqual(selected.selectionBasis, .engineeringProxyOnly)
        XCTAssertEqual(selected.preferenceEvidenceStatus, .notEvaluated)
    }

    func testCandidateSelectionCannotImplicitlyClaimHumanPreference() throws {
        let evaluation = PhotographyCandidateEvaluation(
            planID: "proxy-winner",
            title: "工程代理候选",
            status: .passed,
            score: 98,
            problemImprovement: 0.8,
            preservationScore: 0.8,
            issues: [],
            reason: "自动指标较高",
            durationMilliseconds: 8,
            selected: false
        ).markingSelected()

        XCTAssertTrue(evaluation.selected)
        XCTAssertEqual(evaluation.selectionBasis, .engineeringProxyOnly)
        XCTAssertEqual(evaluation.preferenceEvidenceStatus, .notEvaluated)
    }

    func testCandidateSetDoesNotCallTechnicalPassAestheticSuccess() {
        let evidence = ["D", "E1", "E2"].map {
            PhotographyCandidateReviewEvidence(
                identifier: $0,
                rendered: true,
                technicalStatus: .passed,
                preferenceStatus: .notEvaluated,
                automaticallySelected: false
            )
        }

        let result = PhotographyCandidateSetAssessor().assess(
            expectedCandidateIdentifiers: ["D", "E1", "E2"],
            evidence: evidence
        )

        XCTAssertEqual(result.generationOutcome, .preferencePending)
        XCTAssertEqual(result.selectionOutcome, .selectionNotRun)
        XCTAssertEqual(result.technicallyEligibleCandidateIdentifiers.count, 3)
        XCTAssertTrue(result.humanSupportedCandidateIdentifiers.isEmpty)
    }

    func testCandidateSetSeparatesGenerationFailureFromSelectionFailure() {
        let generationFailure = PhotographyCandidateSetAssessor().assess(
            expectedCandidateIdentifiers: ["D", "E1", "E2"],
            evidence: ["D", "E1", "E2"].map {
                PhotographyCandidateReviewEvidence(
                    identifier: $0,
                    rendered: true,
                    technicalStatus: .passed,
                    preferenceStatus: .humanRejected,
                    automaticallySelected: $0 == "D"
                )
            }
        )
        XCTAssertEqual(generationFailure.generationOutcome, .candidateGenerationFailedHumanReview)
        XCTAssertEqual(generationFailure.selectionOutcome, .selectionNotRun)

        let selectionFailure = PhotographyCandidateSetAssessor().assess(
            expectedCandidateIdentifiers: ["D", "E1", "E2"],
            evidence: [
                PhotographyCandidateReviewEvidence(
                    identifier: "D",
                    rendered: true,
                    technicalStatus: .passed,
                    preferenceStatus: .humanRejected,
                    automaticallySelected: true
                ),
                PhotographyCandidateReviewEvidence(
                    identifier: "E1",
                    rendered: true,
                    technicalStatus: .passed,
                    preferenceStatus: .humanSupported,
                    automaticallySelected: false
                ),
                PhotographyCandidateReviewEvidence(
                    identifier: "E2",
                    rendered: true,
                    technicalStatus: .passed,
                    preferenceStatus: .inconclusive,
                    automaticallySelected: false
                )
            ]
        )
        XCTAssertEqual(selectionFailure.generationOutcome, .humanSupportedCandidateAvailable)
        XCTAssertEqual(selectionFailure.selectionOutcome, .candidateSelectionFailed)
    }

    func testCandidateSetRefusesAssessmentWhenRealRenderIsMissing() {
        let result = PhotographyCandidateSetAssessor().assess(
            expectedCandidateIdentifiers: ["D", "E1", "E2"],
            evidence: [
                PhotographyCandidateReviewEvidence(
                    identifier: "D",
                    rendered: true,
                    technicalStatus: .passed,
                    preferenceStatus: .notEvaluated,
                    automaticallySelected: false
                )
            ]
        )
        XCTAssertEqual(result.generationOutcome, .incompleteRenderEvidence)
        XCTAssertEqual(result.selectionOutcome, .selectionNotRun)
        XCTAssertTrue(result.reason.contains("E1"))
        XCTAssertTrue(result.reason.contains("E2"))
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

    func testVisualUnderstandingKeepsSemanticRegionAndUnknownBoundariesExplicit() throws {
        let mask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([
                0, 0, 0, 0,
                0, 255, 255, 0,
                0, 255, 255, 0,
                0, 0, 0, 0
            ])
        )
        let region = SemanticObjectRegion(
            role: .foodOrFruit,
            mask: mask,
            confidence: 0.82,
            statistics: regionStatistics(
                luminance: 0.36,
                contrast: 0.42,
                saturation: 0.38,
                red: 0.58,
                green: 0.34,
                blue: 0.18
            )
        )
        let analysis = fixture(
            luminance: 0.45,
            contrast: 0.5,
            saturation: 0.22,
            labels: ["outdoor"],
            neutralColorStatistics: nil,
            semanticObjectRegions: [region]
        )
        let understanding = analysis.visualSceneUnderstanding

        XCTAssertEqual(understanding.status, .reliable)
        XCTAssertTrue(understanding.primarySubjectDescription.contains("foodOrFruit"))
        XCTAssertTrue(understanding.unknowns.contains("光源绝对白平衡不确定"))
        XCTAssertTrue(understanding.traceSummary.contains("类级蒙版"))
        XCTAssertEqual(understanding.semanticRegions.first?.role, .foodOrFruit)
    }

    func testPersonMaskWithoutFaceStillActivatesStrictIdentityProtection() {
        let personMask = NormalizedPhotoMask(
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
            luminance: 0.42,
            contrast: 0.46,
            saturation: 0.2,
            labels: ["outdoor", "person"],
            personMask: personMask
        )
        let result = decision(for: analysis)

        XCTAssertTrue(analysis.containsPersonEvidence)
        XCTAssertTrue(result.treatmentPlan.portraitProtection.isActive)
        XCTAssertEqual(result.recipe.faceExposureEV, 0)
        XCTAssertEqual(result.recipe.hsl.orangeHue, 0)
        XCTAssertEqual(result.recipe.hsl.orangeSaturation, 0)
        XCTAssertFalse(result.treatmentPlan.portraitProtection.allowsGeometryChanges)
        XCTAssertFalse(result.treatmentPlan.portraitProtection.allowsGenerativeChanges)
    }

    func testAestheticPlannerControlsOnlyReferenceValidationDecision() throws {
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
            luminance: 0.44,
            contrast: 0.42,
            saturation: 0.2,
            labels: ["outdoor", "food"],
            salientSubjectMask: subjectMask,
            salientSubjectStatistics: regionStatistics(
                luminance: 0.3,
                contrast: 0.34,
                saturation: 0.34,
                red: 0.55,
                green: 0.31,
                blue: 0.17
            )
        )
        let problems = detector.detect(in: analysis)
        let match = PhotographyReferenceMatcher(
            index: referenceIndex(records: [
                referenceRecord(
                    id: "aesthetic-plan",
                    luminance: 0.46,
                    contrast: 0.53,
                    saturation: 0.23,
                    categories: ["outdoor", "food"]
                )
            ]),
            usageMode: .diagnosticValidation
        ).match(analysis: analysis)
        let profile = PhotographyReferenceTargetGenerator().makeProfile(
            analysis: analysis,
            problems: problems,
            matchResult: match
        )
        let baseline = engine.makeDecision(for: analysis, problems: problems)
        let diagnostic = engine.makeDecision(
            for: analysis,
            problems: problems,
            targetProfile: profile
        )

        XCTAssertNil(baseline.aestheticPlan)
        XCTAssertEqual(baseline.aestheticTarget, .neutral)
        XCTAssertNotNil(diagnostic.aestheticPlan)
        XCTAssertEqual(diagnostic.aestheticTarget, .measuredHarmony)
        XCTAssertTrue(diagnostic.parameterEvidence.contains {
            $0.knowledgeRuleIDs.contains(.measuredVisualHierarchy)
        })
        XCTAssertTrue(diagnostic.actions.contains { $0.title.contains("摄影审美规划") })
    }

    func testAestheticPlannerUsesMeasurementsNotSceneNameForTargets() throws {
        let dark = fixture(
            luminance: 0.25,
            contrast: 0.31,
            saturation: 0.17,
            labels: ["outdoor", "landscape"],
            shadowRatio: 0.48,
            noiseEstimate: 0.09
        )
        let bright = fixture(
            luminance: 0.61,
            contrast: 0.64,
            saturation: 0.25,
            labels: ["outdoor", "landscape"],
            shadowRatio: 0.08,
            highlightRatio: 0.18,
            noiseEstimate: 0.03
        )
        func plan(_ analysis: PhotoAnalysis) throws -> AestheticPhotographyPlan {
            let problems = detector.detect(in: analysis)
            let match = PhotographyReferenceMatcher(
                index: referenceIndex(records: [
                    referenceRecord(
                        id: "same-label-reference",
                        luminance: analysis.averageLuminance,
                        contrast: analysis.contrastRange,
                        saturation: analysis.averageSaturation,
                        categories: ["outdoor", "landscape"]
                    )
                ]),
                usageMode: .diagnosticValidation
            ).match(analysis: analysis)
            let profile = PhotographyReferenceTargetGenerator().makeProfile(
                analysis: analysis,
                problems: problems,
                matchResult: match
            )
            return AestheticPhotographyPlanner().makePlan(
                analysis: analysis,
                problems: problems,
                targetProfile: profile
            )
        }

        let darkPlan = try plan(dark)
        let brightPlan = try plan(bright)
        XCTAssertNotEqual(darkPlan.localContrastTarget, brightPlan.localContrastTarget)
        XCTAssertEqual(darkPlan.shadowCoolTarget, 0)
        XCTAssertEqual(brightPlan.shadowCoolTarget, 0)
        XCTAssertTrue(darkPlan.rationale.joined().contains("0.250"))
        XCTAssertTrue(brightPlan.rationale.joined().contains("0.610"))
    }

    func testManualRendererParametersMapOnlyDeclaredControls() {
        let parameters = ManualPhotographyParameters(
            identifier: "unit-test",
            exposureEV: 0.22,
            highlightAmount: 0.61,
            shadowAmount: 0.27,
            blackPoint: 0.014,
            temperatureShift: 240,
            tintShift: -4,
            toneCurveAmount: 0.3,
            toneCurveStyle: .softHighlights,
            shadowZoneExposureEV: 0.1,
            highlightZoneExposureEV: -0.12,
            luminanceMaskStrength: 0.7
        )
        let recipe = parameters.makeRecipe()
        XCTAssertEqual(recipe.exposureEV, 0.22, accuracy: 0.0001)
        XCTAssertEqual(recipe.highlightAmount, 0.61, accuracy: 0.0001)
        XCTAssertEqual(recipe.shadowAmount, 0.27, accuracy: 0.0001)
        XCTAssertEqual(recipe.blackPoint, 0.014, accuracy: 0.0001)
        XCTAssertEqual(recipe.temperatureShift, 240, accuracy: 0.0001)
        XCTAssertEqual(recipe.tintShift, -4, accuracy: 0.0001)
        XCTAssertEqual(recipe.toneCurveAmount, 0.3, accuracy: 0.0001)
        XCTAssertEqual(recipe.toneCurveStyle, .softHighlights)
        XCTAssertEqual(recipe.shadowZoneExposureEV, 0.1, accuracy: 0.0001)
        XCTAssertEqual(recipe.highlightZoneExposureEV, -0.12, accuracy: 0.0001)
        XCTAssertEqual(recipe.luminanceMaskStrength, 0.7, accuracy: 0.0001)
        XCTAssertEqual(recipe.saturation, 1, accuracy: 0.0001)
        XCTAssertEqual(recipe.hsl, .neutral)
        XCTAssertEqual(recipe.skyExposureEV, 0, accuracy: 0.0001)
        XCTAssertEqual(recipe.skyHighlightAmount, 1, accuracy: 0.0001)
        XCTAssertEqual(recipe.skySaturation, 1, accuracy: 0.0001)
        XCTAssertEqual(recipe.grainAmount, 0, accuracy: 0.0001)
    }

    func testMeasuredAestheticDiagnosticPathDoesNotChangeFormalDecisionContract() {
        let analysis = fixture(
            luminance: 0.31,
            contrast: 0.34,
            saturation: 0.18,
            labels: ["outdoor", "plant"],
            shadowRatio: 0.38,
            noiseEstimate: 0.07
        )
        let problems = detector.detect(in: analysis)
        let formal = engine.makeDecision(for: analysis, problems: problems)
        let diagnostic = engine.makeDecision(
            for: analysis,
            problems: problems,
            enableMeasuredAestheticPlanning: true
        )

        XCTAssertNil(formal.aestheticPlan)
        XCTAssertNil(formal.adaptiveRegionalTonePlan)
        XCTAssertEqual(formal.aestheticTarget, .neutral)
        XCTAssertNotNil(diagnostic.aestheticPlan)
        XCTAssertEqual(diagnostic.aestheticTarget, .measuredHarmony)
        XCTAssertTrue(diagnostic.intent.contains("真实氛围") || diagnostic.intent.contains("整图协调"))
        XCTAssertTrue(diagnostic.parameterEvidence.contains { evidence in
            evidence.knowledgeRuleIDs.contains(.measuredVisualHierarchy)
        })
        XCTAssertFalse(diagnostic.parameterEvidence.contains { evidence in
            evidence.knowledgeRuleIDs.contains(.referenceTargetCalibration)
        })
    }

    func testManualNeutralRecipeDoesNotAlterPixels() throws {
        let source = syntheticImage(width: 4, height: 2, pixels: [
            (32, 32, 32), (96, 96, 96), (180, 180, 180), (230, 230, 230),
            (210, 105, 35), (30, 100, 220), (80, 150, 70), (150, 80, 130)
        ])
        let recipe = ManualPhotographyParameters(identifier: "neutral").makeRecipe()
        var output = CoreImageParameterKernel.exposure(source, ev: recipe.exposureEV)
        output = CoreImageParameterKernel.highlightShadow(
            output,
            highlights: recipe.highlightAmount,
            shadows: recipe.shadowAmount
        )
        output = CoreImageParameterKernel.blackPoint(output, amount: recipe.blackPoint)
        output = CinematicToneMappingEngine().apply(to: output, recipe: recipe)
        output = CoreImageParameterKernel.whiteBalance(
            output,
            temperatureShift: recipe.temperatureShift,
            tintShift: recipe.tintShift
        )
        output = CoreImageParameterKernel.colorControls(
            output,
            brightness: recipe.brightness,
            contrast: recipe.contrast,
            saturation: recipe.saturation
        )
        output = CoreImageParameterKernel.vibrance(output, amount: recipe.vibrance)
        output = ProfessionalHSLProcessor().apply(to: output, adjustment: recipe.hsl)

        XCTAssertEqual(try rgba8(output), try rgba8(source))
        XCTAssertEqual(recipe.colorGradeIntensity, 0, accuracy: 0.0001)
        XCTAssertEqual(recipe.backgroundSeparation, 0, accuracy: 0.0001)
        XCTAssertEqual(recipe.subjectExposureEV, 0, accuracy: 0.0001)
        XCTAssertEqual(recipe.skySaturation, 1, accuracy: 0.0001)
    }

    func testInverseResearchBoundaryDoesNotBroadenProductionRecipe() {
        let production = ManualPhotographyParameters(
            identifier: "product-boundary",
            exposureEV: -0.53,
            contrast: 1.20,
            lowerMidtoneLift: -0.17,
            midtoneBias: -0.25
        ).makeRecipe()
        let research = ManualPhotographyParameters.inverseR3Verification.makeRecipe()

        XCTAssertEqual(production.exposureEV, -0.35, accuracy: 0.0001)
        XCTAssertEqual(production.contrast, 1.14, accuracy: 0.0001)
        XCTAssertEqual(production.lowerMidtoneLift, -0.08, accuracy: 0.0001)
        XCTAssertEqual(production.midtoneBias, -0.08, accuracy: 0.0001)
        XCTAssertEqual(research.exposureEV, -0.5606130, accuracy: 0.0001)
        XCTAssertEqual(research.contrast, 1.2665886, accuracy: 0.0001)
        XCTAssertEqual(research.lowerMidtoneLift, -0.1260555, accuracy: 0.0001)
        XCTAssertEqual(research.midtoneBias, -0.25, accuracy: 0.0001)
        XCTAssertEqual(ManualPhotographyParameters.inverseR3Verification.renderingBoundary, .inverseResearch)
        XCTAssertEqual(
            ManualPhotographyParameters.inverseR3Verification.identifier,
            "inverse-r3-core-image-expression-v3-ci-cube-faithful"
        )
    }

    func testDiagnosticRegionalToneNeutralDoesNotAlterPixels() throws {
        let source = syntheticImage(width: 4, height: 1, pixels: [
            (20, 20, 20), (90, 90, 90), (170, 110, 35), (230, 230, 230)
        ])
        let mask = constantImage(width: 4, height: 1, value: 1)
        let output = DiagnosticRegionalToneProcessor().apply(
            to: source,
            semanticMask: mask,
            adjustment: ManualRegionalToneAdjustment(region: .ground)
        )
        XCTAssertEqual(try rgba8(output), try rgba8(source))
    }

    func testDiagnosticRegionalToneRespectsMaskAndLuminanceProtection() throws {
        let source = splitGrayImage(width: 64, height: 16, dark: 0.05, bright: 0.50)
        let mask = constantImage(width: 64, height: 16, value: 1)
        let output = DiagnosticRegionalToneProcessor().apply(
            to: source,
            semanticMask: mask,
            adjustment: ManualRegionalToneAdjustment(
                region: .ground,
                exposureEV: -0.85,
                midtoneBias: -0.18,
                luminanceLowerBound: 0.2,
                luminanceUpperBound: 0.8,
                luminanceFeather: 0.04
            )
        )
        let original = try samplePair(source, width: 64, height: 16)
        let edited = try samplePair(output, width: 64, height: 16)

        XCTAssertEqual(edited.left, original.left, accuracy: 2.0 / 255.0)
        XCTAssertLessThan(edited.right, original.right - 0.08)
    }

    func testWindowsR3AndCoreImageSharedStagesStayWithinDeclaredTolerance() throws {
        let source = syntheticImage(width: 6, height: 1, pixels: [
            (32, 64, 128), (96, 128, 160), (210, 105, 35),
            (180, 170, 40), (40, 140, 65), (200, 200, 200)
        ])
        let recipe = ManualPhotographyParameters.inverseR3Verification.makeRecipe()
        let exposed = CoreImageParameterKernel.exposure(source, ev: recipe.exposureEV)
        assertRGB8(
            try rgba8(exposed),
            expected: [[25, 52, 107], [80, 107, 134], [177, 87, 28], [151, 142, 32], [32, 117, 53], [168, 168, 168]],
            tolerance: 2,
            stage: "linear-sRGB exposure"
        )
        let blackAdjusted = CoreImageParameterKernel.blackPoint(exposed, amount: recipe.blackPoint)
        assertRGB8(
            try rgba8(blackAdjusted),
            expected: [[25, 52, 107], [80, 107, 134], [177, 87, 28], [151, 142, 32], [32, 117, 53], [168, 168, 168]],
            tolerance: 3,
            stage: "black point"
        )
        let curved = CinematicToneMappingEngine().apply(to: blackAdjusted, recipe: recipe)
        assertRGB8(
            try rgba8(curved),
            expected: [[23, 50, 83], [78, 83, 88], [132, 80, 26], [102, 93, 30], [30, 85, 51], [123, 123, 123]],
            tolerance: 4,
            stage: "seven-anchor curve"
        )
        let hslOnly = ProfessionalHSLProcessor().apply(to: curved, adjustment: recipe.hsl)
        assertRGB8(
            try rgba8(hslOnly),
            expected: [[23, 50, 83], [78, 83, 88], [148, 121, 26], [159, 132, 47], [11, 66, 39], [122, 122, 122]],
            tolerance: 4,
            stage: "linear-working-space HSL"
        )
        let controlled = CoreImageParameterKernel.colorControls(
            curved,
            brightness: recipe.brightness,
            contrast: recipe.contrast,
            saturation: recipe.saturation
        )
        let hsl = ProfessionalHSLProcessor().apply(to: controlled, adjustment: recipe.hsl)
        // CIColorControls is Apple-private and differs materially from the
        // Windows approximation in clipped low/mid tones. Keep the exact Apple
        // baseline as a regression contract instead of calling the two
        // implementations pixel-identical. HSL itself is independently checked
        // against Windows immediately above.
        assertRGB8(
            try rgba8(hsl),
            expected: [[0, 0, 51], [21, 41, 55], [132, 57, 0], [128, 103, 0], [0, 2, 0], [112, 112, 112]],
            tolerance: 3,
            stage: "Apple-private color controls plus HSL baseline"
        )
    }

    func testExposurePixelDirectionIsCorrect() throws {
        let source = constantImage(width: 8, height: 8, value: 0.32)
        let original = try meanRGB(source)
        let darker = try meanRGB(CoreImageParameterKernel.exposure(source, ev: -0.25))
        let brighter = try meanRGB(CoreImageParameterKernel.exposure(source, ev: 0.25))

        XCTAssertLessThan(darker.luminance, original.luminance)
        XCTAssertGreaterThan(brighter.luminance, original.luminance)
    }

    func testHighlightAndShadowControlsAffectExpectedLuminanceZones() throws {
        let source = splitGrayImage(width: 64, height: 24, dark: 0.12, bright: 0.88)
        let original = try samplePair(source, width: 64, height: 24)
        let shadowLift = try samplePair(
            CoreImageParameterKernel.highlightShadow(source, highlights: 1, shadows: 0.55),
            width: 64,
            height: 24
        )
        let highlightRecovery = try samplePair(
            CoreImageParameterKernel.highlightShadow(source, highlights: 0.5, shadows: 0),
            width: 64,
            height: 24
        )

        XCTAssertGreaterThan(shadowLift.left - original.left, shadowLift.right - original.right)
        XCTAssertGreaterThan(original.right - highlightRecovery.right, original.left - highlightRecovery.left)
    }

    func testBlackPointPreservesNeutralHueAndControlsDarkPixels() throws {
        let source = splitGrayImage(width: 32, height: 16, dark: 0.10, bright: 0.72)
        let output = CoreImageParameterKernel.blackPoint(source, amount: 0.025)
        let originalPair = try samplePair(source, width: 32, height: 16)
        let outputPair = try samplePair(output, width: 32, height: 16)
        let sample = try rgbSample(output, x: 4, y: 8)

        XCTAssertLessThan(outputPair.left, originalPair.left)
        XCTAssertLessThan(outputPair.right, originalPair.right)
        XCTAssertEqual(sample.r, sample.g, accuracy: 1.0 / 255.0)
        XCTAssertEqual(sample.g, sample.b, accuracy: 1.0 / 255.0)
    }

    func testWhiteBalanceTemperatureDirectionsMatchSolverSemanticsWithoutGreenCast() throws {
        let neutral = constantImage(width: 16, height: 16, value: 0.55)
        let positiveAdjustment = try meanRGB(CoreImageParameterKernel.whiteBalance(
            neutral,
            temperatureShift: 350,
            tintShift: 0
        ))
        let negativeAdjustment = try meanRGB(CoreImageParameterKernel.whiteBalance(
            neutral,
            temperatureShift: -350,
            tintShift: 0
        ))

        // The solver emits positive values to warm a measured cool cast and
        // negative values to cool a measured warm cast.
        XCTAssertGreaterThan(
            positiveAdjustment.r - positiveAdjustment.b,
            negativeAdjustment.r - negativeAdjustment.b
        )
        XCTAssertLessThan(abs(positiveAdjustment.g - ((positiveAdjustment.r + positiveAdjustment.b) / 2)), 0.12)
        XCTAssertLessThan(abs(negativeAdjustment.g - ((negativeAdjustment.r + negativeAdjustment.b) / 2)), 0.12)
    }

    func testWhiteBalancePositiveTintCorrectsMeasuredGreenBias() throws {
        let neutral = constantImage(width: 16, height: 16, value: 0.55)
        let positiveAdjustment = try meanRGB(CoreImageParameterKernel.whiteBalance(
            neutral,
            temperatureShift: 0,
            tintShift: 8
        ))
        let negativeAdjustment = try meanRGB(CoreImageParameterKernel.whiteBalance(
            neutral,
            temperatureShift: 0,
            tintShift: -8
        ))
        let positiveGreenBias = positiveAdjustment.g
            - ((positiveAdjustment.r + positiveAdjustment.b) / 2)
        let negativeGreenBias = negativeAdjustment.g
            - ((negativeAdjustment.r + negativeAdjustment.b) / 2)

        XCTAssertLessThan(positiveGreenBias, negativeGreenBias)
    }

    func testOrangeHSLDoesNotActLikeGlobalSaturation() throws {
        let source = syntheticImage(width: 2, height: 1, pixels: [
            (225, 118, 35),
            (35, 95, 225)
        ])
        var adjustment = ProfessionalHSLAdjustment.neutral
        adjustment.orangeSaturation = 0.16
        let output = ProfessionalHSLProcessor().apply(to: source, adjustment: adjustment)
        let sourceBytes = try rgba8(source)
        let outputBytes = try rgba8(output)
        let orangeDelta = rgbDelta(sourceBytes, outputBytes, pixel: 0)
        let blueDelta = rgbDelta(sourceBytes, outputBytes, pixel: 1)

        XCTAssertGreaterThan(orangeDelta, 2)
        XCTAssertGreaterThan(orangeDelta, blueDelta * 2)
    }

    func testNormalizedMaskCoordinatesPreserveSubjectSide() throws {
        let width = 64
        let height = 32
        let source = constantImage(width: width, height: height, red: 0.55, green: 0.32, blue: 0.20)
        var maskPixels = Data(count: width * height)
        maskPixels.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    bytes[(y * width) + x] = x < width / 2 ? 255 : 0
                }
            }
        }
        let mask = NormalizedPhotoMask(width: width, height: height, pixels: maskPixels)
        let analysis = fixture(
            luminance: 0.4,
            contrast: 0.4,
            saturation: 0.2,
            labels: ["person"],
            personMask: mask
        )
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.backgroundSeparation = 0.18
        let output = CinematicSpatialDepthProcessor().apply(
            to: source,
            analysis: analysis,
            recipe: recipe
        )
        let sourceLeft = try rgbSample(source, x: 8, y: 16)
        let sourceRight = try rgbSample(source, x: 56, y: 16)
        let outputLeft = try rgbSample(output, x: 8, y: 16)
        let outputRight = try rgbSample(output, x: 56, y: 16)

        XCTAssertLessThan(rgbDistance(sourceLeft, outputLeft), 0.02)
        XCTAssertGreaterThan(rgbDistance(sourceRight, outputRight), 0.01)
    }

    func testMeasuredDUsesDifferentParametersForDifferentMeasurementsInSameScene() {
        let dark = fixture(
            luminance: 0.24,
            contrast: 0.30,
            saturation: 0.15,
            labels: ["outdoor", "landscape"],
            shadowRatio: 0.5,
            noiseEstimate: 0.08
        )
        let bright = fixture(
            luminance: 0.68,
            contrast: 0.62,
            saturation: 0.27,
            labels: ["outdoor", "landscape"],
            shadowRatio: 0.06,
            highlightRatio: 0.24,
            noiseEstimate: 0.02
        )
        let darkDecision = engine.makeDecision(
            for: dark,
            problems: detector.detect(in: dark),
            enableMeasuredAestheticPlanning: true
        )
        let brightDecision = engine.makeDecision(
            for: bright,
            problems: detector.detect(in: bright),
            enableMeasuredAestheticPlanning: true
        )

        XCTAssertNotEqual(darkDecision.recipe.exposureEV, brightDecision.recipe.exposureEV)
        XCTAssertNotEqual(darkDecision.recipe.highlightAmount, brightDecision.recipe.highlightAmount)
        XCTAssertNotEqual(
            darkDecision.parameterEvidence.map(\.actualValue),
            brightDecision.parameterEvidence.map(\.actualValue)
        )
    }

    func testBroadEnvironmentDoesNotLetSmallVehicleClassMaskBecomePhotographicSubject() {
        func mask(active: Int) -> NormalizedPhotoMask {
            NormalizedPhotoMask(
                width: 8,
                height: 8,
                pixels: Data((0..<64).map { $0 < active ? UInt8(255) : UInt8(0) })
            )
        }
        let vehicleMask = mask(active: 8)
        let vehicle = SemanticObjectRegion(
            role: .vehicle,
            mask: vehicleMask,
            confidence: 0.89,
            statistics: regionStatistics(
                luminance: 0.52,
                contrast: 0.5,
                saturation: 0.18,
                red: 0.5,
                green: 0.5,
                blue: 0.49
            )
        )
        let analysis = fixture(
            luminance: 0.58,
            contrast: 0.55,
            saturation: 0.2,
            labels: ["outdoor", "road", "plant"],
            skyMask: mask(active: 7),
            groundMask: mask(active: 21),
            vegetationMask: mask(active: 27),
            semanticObjectRegions: [vehicle],
            segmentation: SceneSegmentationDiagnostics(
                status: .available,
                reason: nil,
                skyCoverage: 7.0 / 64.0,
                groundCoverage: 21.0 / 64.0,
                vegetationCoverage: 27.0 / 64.0,
                waterCoverage: 0,
                architectureCoverage: 0
            )
        )

        XCTAssertEqual(analysis.subjectPriorityProfile.mode, .globalHarmony)
        XCTAssertFalse(analysis.visualSceneUnderstanding.primarySubjectDescription.contains("vehicle"))
        XCTAssertTrue(analysis.visualSceneUnderstanding.unknowns.contains {
            $0.contains("类级小物体")
        })
    }

    func testMeasuredYellowEvidenceChangesDYellowHSLWithoutScenePreset() {
        let vegetationMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([0, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 0])
        )
        let groundMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255])
        )
        func analysis(yellowRatio: Float) -> PhotoAnalysis {
            fixture(
                luminance: 0.52,
                contrast: 0.48,
                saturation: 0.21,
                labels: ["outdoor"],
                vegetationMask: vegetationMask,
                vegetationStatistics: regionStatistics(
                    luminance: 0.39,
                    contrast: 0.46,
                    saturation: 0.2,
                    red: 0.42,
                    green: 0.4,
                    blue: 0.25,
                    yellowColorRatio: yellowRatio,
                    greenColorRatio: 0.34
                ),
                segmentation: SceneSegmentationDiagnostics(
                    status: .available,
                    reason: nil,
                    skyCoverage: 0,
                    groundCoverage: 0,
                    vegetationCoverage: vegetationMask.activeCoverage,
                    waterCoverage: 0,
                    architectureCoverage: 0
                )
            )
        }
        let noYellow = analysis(yellowRatio: 0)
        let measuredYellow = analysis(yellowRatio: 0.18)
        let noYellowDecision = engine.makeDecision(
            for: noYellow,
            problems: detector.detect(in: noYellow),
            enableMeasuredAestheticPlanning: true
        )
        let measuredDecision = engine.makeDecision(
            for: measuredYellow,
            problems: detector.detect(in: measuredYellow),
            enableMeasuredAestheticPlanning: true
        )

        XCTAssertEqual(noYellowDecision.recipe.hsl.yellowSaturation, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(measuredDecision.recipe.hsl.yellowSaturation, 0.02)
        let evidenceValue = measuredDecision.parameterEvidence.first { $0.key == .yellowHSL }?.actualValue
        XCTAssertEqual(evidenceValue ?? -1, measuredDecision.recipe.hsl.yellowSaturation, accuracy: 0.0001)
    }

    func testMeasuredDTargetUsesSourceRelativeLuminanceWithSameAnalyzerDefinition() {
        let bright = fixture(
            luminance: 0.637,
            contrast: 0.831,
            saturation: 0.168,
            labels: ["outdoor"],
            shadowRatio: 0.055,
            highlightRatio: 0.253,
            blackRatio: 0.01,
            whiteRatio: 0.04,
            noiseEstimate: 0.04
        )
        let profile = PhotographyTargetProfile.measuredBaseline(
            analysis: bright,
            problems: detector.detect(in: bright)
        )

        XCTAssertGreaterThan(profile.resolvedTarget.luminance, 0.55)
        XCTAssertLessThan(profile.resolvedTarget.luminance, bright.averageLuminance)
        XCTAssertGreaterThan(profile.resolvedTarget.contrast, 0.79)
        XCTAssertLessThanOrEqual(profile.resolvedTarget.contrast, bright.contrastRange)
        XCTAssertTrue(profile.rationale.joined().contains("同一测量定义"))
    }

    func testMeasuredDGeneratesProtectedEnhancedRegionalToneFromCurrentPixels() throws {
        let groundMask = NormalizedPhotoMask(
            width: 8,
            height: 8,
            pixels: Data((0..<64).map { $0 < 22 ? UInt8(255) : UInt8(0) })
        )
        let vegetationMask = NormalizedPhotoMask(
            width: 8,
            height: 8,
            pixels: Data((0..<64).map { $0 >= 22 && $0 < 50 ? UInt8(255) : UInt8(0) })
        )
        let analysis = fixture(
            luminance: 0.637,
            contrast: 0.831,
            saturation: 0.168,
            labels: ["outdoor"],
            groundMask: groundMask,
            vegetationMask: vegetationMask,
            groundStatistics: regionStatistics(
                luminance: 0.692,
                contrast: 0.587,
                saturation: 0.073,
                red: 0.55,
                green: 0.53,
                blue: 0.47
            ),
            vegetationStatistics: regionStatistics(
                luminance: 0.557,
                contrast: 0.802,
                saturation: 0.270,
                red: 0.46,
                green: 0.44,
                blue: 0.31,
                yellowColorRatio: 0.509,
                greenColorRatio: 0.192
            ),
            shadowRatio: 0.055,
            highlightRatio: 0.253,
            blackRatio: 0.01,
            whiteRatio: 0.04,
            noiseEstimate: 0.04,
            segmentation: SceneSegmentationDiagnostics(
                status: .available,
                reason: nil,
                skyCoverage: 0,
                groundCoverage: 0.328,
                vegetationCoverage: 0.423,
                waterCoverage: 0,
                architectureCoverage: 0
            )
        )
        let decision = engine.makeDecision(
            for: analysis,
            problems: detector.detect(in: analysis),
            enableMeasuredAestheticPlanning: true
        )
        let plan: AdaptiveRegionalTonePlan = try XCTUnwrap(decision.adaptiveRegionalTonePlan)
        let ground: ManualRegionalToneAdjustment = try XCTUnwrap(
            plan.adjustments.first { $0.region == TreatmentRegion.ground }
        )
        let vegetation: ManualRegionalToneAdjustment = try XCTUnwrap(
            plan.adjustments.first { $0.region == TreatmentRegion.vegetation }
        )

        XCTAssertLessThan(ground.exposureEV, -0.12)
        XCTAssertLessThan(ground.midtoneBias, -0.04)
        XCTAssertGreaterThanOrEqual(ground.luminanceLowerBound, 0.1)
        XCTAssertLessThanOrEqual(ground.luminanceUpperBound, 0.86)
        XCTAssertGreaterThanOrEqual(ground.luminanceFeather, 0.14)
        XCTAssertGreaterThan(vegetation.hsl.yellowSaturation, 0.05)
        XCTAssertNotEqual(ground.exposureEV, vegetation.exposureEV)
        XCTAssertTrue(plan.evidence.contains { $0.contains("demand=") })
    }

    func testAdaptiveRegionalFeedbackStrengthensMeasuredUnderResponseWithoutChangingIntent() throws {
        let requested = ManualRegionalToneAdjustment(
            region: .ground,
            exposureEV: -0.34,
            lowerMidtoneLift: -0.06,
            midtoneBias: -0.07,
            contrast: 1.05,
            luminanceLowerBound: 0.12,
            luminanceUpperBound: 0.82,
            luminanceFeather: 0.16
        )
        let plan = AdaptiveRegionalTonePlan(adjustments: [requested], evidence: ["measured plan"])
        let impact = PhotographyRegionImpact(
            region: .ground,
            maskCoverage: 0.32,
            luminanceDelta: -0.004,
            colorDelta: 0.002,
            contrastDelta: 0.001,
            changedPixelRatio: 0.48,
            sourceShadowRatio: 0.05,
            editedShadowRatio: 0.055,
            detailEnergyRatio: 0.96
        )

        let feedback = try XCTUnwrap(AdaptiveRegionalToneFeedbackSolver().makeFeedback(
            plan: plan,
            impacts: [impact]
        ))
        let adjusted = try XCTUnwrap(feedback.adjustments.first)
        XCTAssertLessThan(adjusted.exposureEV, requested.exposureEV)
        XCTAssertLessThan(adjusted.midtoneBias, requested.midtoneBias)
        XCTAssertTrue(feedback.evidence.contains { $0.contains("under-response") })
    }

    func testAdaptiveRegionalFeedbackProducesMeasuredCoreImagePixelResponse() throws {
        let width = 64
        let height = 32
        let source = constantImage(width: width, height: height, value: 0.55)
        let mask = constantImage(width: width, height: height, value: 1)
        let requested = ManualRegionalToneAdjustment(
            region: .ground,
            exposureEV: -0.34,
            lowerMidtoneLift: -0.06,
            midtoneBias: -0.07,
            contrast: 1.05,
            luminanceLowerBound: 0.12,
            luminanceUpperBound: 0.82,
            luminanceFeather: 0.16
        )
        let processor = DiagnosticRegionalToneProcessor()
        let firstRender = processor.apply(
            to: source,
            semanticMask: mask,
            adjustment: requested
        )
        let sourceLuminance = try meanRGB(source).luminance
        let firstLuminance = try meanRGB(firstRender).luminance
        let impact = PhotographyRegionImpact(
            region: .ground,
            maskCoverage: 1,
            // This is the measured regional response supplied by the quality
            // service. Keep it deliberately below the solved intent so this
            // test exercises the feedback-to-renderer connection rather than
            // re-testing the impact measurement implementation.
            luminanceDelta: -0.004,
            colorDelta: 0,
            contrastDelta: 0,
            changedPixelRatio: 1,
            sourceShadowRatio: 0,
            editedShadowRatio: 0,
            detailEnergyRatio: 1
        )
        let feedbackPlan = try XCTUnwrap(AdaptiveRegionalToneFeedbackSolver().makeFeedback(
            plan: AdaptiveRegionalTonePlan(adjustments: [requested], evidence: ["measured plan"]),
            impacts: [impact]
        ))
        let corrected = try XCTUnwrap(feedbackPlan.adjustments.first)
        let secondRender = processor.apply(
            to: source,
            semanticMask: mask,
            adjustment: corrected
        )
        let secondLuminance = try meanRGB(secondRender).luminance

        XCTAssertLessThan(firstLuminance, sourceLuminance)
        XCTAssertLessThan(secondLuminance, firstLuminance - (0.5 / 255.0))
        XCTAssertTrue(feedbackPlan.evidence.contains { $0.contains("under-response") })
    }

    func testAdaptiveRegionalFeedbackProtectsOnlyMeasuredRiskInsteadOfRelaxingQualityGate() throws {
        let requested = ManualRegionalToneAdjustment(
            region: .architecture,
            exposureEV: -0.42,
            blackPoint: 0.04,
            lowerMidtoneLift: -0.08,
            midtoneBias: -0.1,
            contrast: 1.1,
            luminanceLowerBound: 0.08,
            luminanceUpperBound: 0.88,
            luminanceFeather: 0.12
        )
        let plan = AdaptiveRegionalTonePlan(adjustments: [requested], evidence: ["measured plan"])
        let impact = PhotographyRegionImpact(
            region: .architecture,
            maskCoverage: 0.1,
            luminanceDelta: -0.12,
            colorDelta: 0.006,
            contrastDelta: 0.02,
            changedPixelRatio: 0.8,
            sourceShadowRatio: 0.06,
            editedShadowRatio: 0.18,
            detailEnergyRatio: 0.64
        )

        let feedback = try XCTUnwrap(AdaptiveRegionalToneFeedbackSolver().makeFeedback(
            plan: plan,
            impacts: [impact],
            risks: AdaptiveRegionalToneFeedbackRisks(
                maskBoundaryArtifact: true,
                neutralIntegrityLoss: true,
                shadowDetailLoss: false
            )
        ))
        let adjusted = try XCTUnwrap(feedback.adjustments.first)
        XCTAssertLessThan(adjusted.exposureEV.magnitude, requested.exposureEV.magnitude)
        XCTAssertLessThan(adjusted.blackPoint, requested.blackPoint)
        XCTAssertGreaterThanOrEqual(adjusted.luminanceLowerBound, 0.14)
        XCTAssertGreaterThanOrEqual(adjusted.luminanceFeather, 0.21)
    }

    func testDecisionRecordsSolverToRendererParameterLifecycle() {
        let analysis = fixture(
            luminance: 0.63,
            contrast: 0.82,
            saturation: 0.18,
            labels: ["outdoor"],
            highlightRatio: 0.24
        )
        let decision = engine.makeDecision(
            for: analysis,
            problems: detector.detect(in: analysis),
            enableMeasuredAestheticPlanning: true
        )

        XCTAssertEqual(decision.recipeLifecycle.first?.stage, "solverOutput")
        XCTAssertEqual(decision.recipeLifecycle.last?.stage, "finalProductBounds")
        XCTAssertTrue(decision.recipeLifecycle.contains { $0.stage == "problemSafetyLimits" })
        XCTAssertFalse(decision.recipeLifecycle.last?.recipeSummary.isEmpty ?? true)
    }

    func testR3MeasuredSafetyCorrectionPreservesExpressionButProtectsEndpoints() throws {
        let source = ManualPhotographyParameters.inverseR3Verification
        let corrected = source.safetyAdjustedForMeasuredRisks(
            tooHarsh: true,
            crushedShadows: false,
            abnormalBlackCoverage: false,
            neutralLuminanceShift: -0.16,
            neutralColorDrift: false,
            localMaskBoundaryArtifact: true
        )
        let sourceGround: ManualRegionalToneAdjustment = try XCTUnwrap(
            source.regionalToneAdjustments.first { $0.region == TreatmentRegion.ground }
        )
        let correctedGround: ManualRegionalToneAdjustment = try XCTUnwrap(
            corrected.regionalToneAdjustments.first { $0.region == TreatmentRegion.ground }
        )

        XCTAssertGreaterThan(corrected.exposureEV, source.exposureEV)
        XCTAssertLessThan(corrected.contrast, source.contrast)
        XCTAssertLessThan(correctedGround.exposureEV.magnitude, sourceGround.exposureEV.magnitude)
        XCTAssertGreaterThanOrEqual(correctedGround.luminanceLowerBound, 0.12)
        XCTAssertLessThanOrEqual(correctedGround.luminanceUpperBound, 0.86)
        XCTAssertGreaterThanOrEqual(correctedGround.luminanceFeather, 0.16)
        XCTAssertNotEqual(corrected.exposureEV, 0)
        XCTAssertNotEqual(correctedGround.exposureEV, 0)
    }

    func testRegionalYellowAndGreenRelationshipCreatesMeasuredColorSeparation() {
        let vegetationMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([0, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 0])
        )
        let analysis = fixture(
            luminance: 0.57,
            contrast: 0.66,
            saturation: 0.19,
            labels: ["outdoor"],
            groundMask: groundMask,
            vegetationMask: vegetationMask,
            groundStatistics: regionStatistics(
                luminance: 0.692,
                contrast: 0.61,
                saturation: 0.073,
                red: 0.55,
                green: 0.54,
                blue: 0.48
            ),
            vegetationStatistics: regionStatistics(
                luminance: 0.43,
                contrast: 0.57,
                saturation: 0.24,
                red: 0.43,
                green: 0.42,
                blue: 0.25,
                yellowColorRatio: 0.509,
                greenColorRatio: 0.192
            ),
            segmentation: SceneSegmentationDiagnostics(
                status: .available,
                reason: nil,
                skyCoverage: 0,
                groundCoverage: 0,
                vegetationCoverage: vegetationMask.activeCoverage,
                waterCoverage: 0,
                architectureCoverage: 0
            )
        )
        let problems = detector.detect(in: analysis)
        let profile = PhotographyTargetProfile.measuredBaseline(
            analysis: analysis,
            problems: problems
        )
        let plan = AestheticPhotographyPlanner().makePlan(
            analysis: analysis,
            problems: problems,
            targetProfile: profile
        )

        XCTAssertGreaterThan(plan.colorSeparationStrength, 0.01)
        XCTAssertTrue(plan.emphasizedRegions.contains { $0.contains("暖黄色关系") })
    }

    func testMeasuredIntentUsesPixelRelationshipsInsteadOfSharedSceneLabel() throws {
        let groundMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0])
        )
        let vegetationMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255])
        )
        func makeAnalysis(groundLuma: Float, groundSaturation: Float, vegetationLuma: Float, vegetationSaturation: Float) -> PhotoAnalysis {
            fixture(
                luminance: 0.637,
                contrast: 0.831,
                saturation: 0.168,
                labels: ["outdoor"],
                groundMask: groundMask,
                vegetationMask: vegetationMask,
                groundStatistics: regionStatistics(
                    luminance: groundLuma,
                    contrast: 0.587,
                    saturation: groundSaturation,
                    red: groundLuma,
                    green: groundLuma,
                    blue: groundLuma,
                    yellowColorRatio: 0.05,
                    greenColorRatio: 0
                ),
                vegetationStatistics: regionStatistics(
                    luminance: vegetationLuma,
                    contrast: 0.80,
                    saturation: vegetationSaturation,
                    red: 0.48,
                    green: 0.43,
                    blue: 0.22,
                    yellowColorRatio: 0.509,
                    greenColorRatio: 0.192
                ),
                shadowRatio: 0.055,
                highlightRatio: 0.253,
                noiseEstimate: 0.04,
                segmentation: SceneSegmentationDiagnostics(
                    status: .available,
                    reason: nil,
                    skyCoverage: 0,
                    groundCoverage: groundMask.activeCoverage,
                    vegetationCoverage: vegetationMask.activeCoverage,
                    waterCoverage: 0,
                    architectureCoverage: 0
                )
            )
        }
        func result(_ analysis: PhotoAnalysis) throws -> (AestheticPhotographyPlan, AdaptiveRegionalTonePlan) {
            let problems = detector.detect(in: analysis)
            let profile = PhotographyTargetProfile.measuredBaseline(analysis: analysis, problems: problems)
            let plan = AestheticPhotographyPlanner().makePlan(
                analysis: analysis,
                problems: problems,
                targetProfile: profile
            )
            let regional = try XCTUnwrap(
                AdaptiveRegionalTonePlanner().makePlan(
                    analysis: analysis,
                    target: profile.resolvedTarget,
                    aestheticPlan: plan
                )
            )
            return (plan, regional)
        }

        let hierarchy = try result(makeAnalysis(
            groundLuma: 0.692,
            groundSaturation: 0.073,
            vegetationLuma: 0.557,
            vegetationSaturation: 0.270
        ))
        let balanced = try result(makeAnalysis(
            groundLuma: 0.56,
            groundSaturation: 0.22,
            vegetationLuma: 0.557,
            vegetationSaturation: 0.24
        ))
        let hierarchyGround = try XCTUnwrap(
            hierarchy.1.adjustments.first { $0.region == .ground }
        )
        let balancedGround = try XCTUnwrap(
            balanced.1.adjustments.first { $0.region == .ground }
        )

        XCTAssertNotNil(hierarchy.0.groundVegetationLuminanceDeltaTarget)
        XCTAssertNil(balanced.0.groundVegetationLuminanceDeltaTarget)
        XCTAssertGreaterThan(hierarchy.0.measuredIntentStrength, balanced.0.measuredIntentStrength)
        XCTAssertLessThan(hierarchyGround.exposureEV, balancedGround.exposureEV)
        XCTAssertTrue(hierarchy.1.intentionalNeutralToneRegions.contains(.ground))
        XCTAssertEqual(hierarchy.0.intentSelectionStatus, "measured-hierarchy-hypothesis-human-review-required")
    }

    func testNeutralLuminanceAttributionKeepsThresholdAndProtectsNonToneRegions() {
        XCTAssertEqual(
            NeutralToneSafetyAttribution.bucket(
                isHardProtected: false,
                isIntentionalTone: true
            ),
            .intentionalTone
        )
        XCTAssertEqual(
            NeutralToneSafetyAttribution.bucket(
                isHardProtected: true,
                isIntentionalTone: true
            ),
            .protected,
            "Architecture, people and salient subjects stay protected when masks overlap"
        )
        XCTAssertTrue(NeutralToneSafetyAttribution.hasProtectedLuminanceLoss(
            coverage: 0.22,
            luminanceShift: -0.108
        ))
        XCTAssertFalse(NeutralToneSafetyAttribution.hasProtectedLuminanceLoss(
            coverage: 0.22,
            luminanceShift: -0.024
        ))
        XCTAssertEqual(
            NeutralToneSafetyAttribution.protectedLuminanceLossThreshold,
            -0.065,
            accuracy: 0.0001,
            "PT-QA-005 keeps the existing safety threshold"
        )
    }

    func testMeasuredAestheticHypothesesAreIndependentlySolvedFromCurrentPhoto() throws {
        let vegetationMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([0, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 0])
        )
        let source = fixture(
            luminance: 0.637,
            contrast: 0.831,
            saturation: 0.168,
            labels: ["outdoor"],
            vegetationMask: vegetationMask,
            vegetationStatistics: regionStatistics(
                luminance: 0.43,
                contrast: 0.57,
                saturation: 0.24,
                red: 0.43,
                green: 0.42,
                blue: 0.25,
                yellowColorRatio: 0.509,
                greenColorRatio: 0.192
            ),
            shadowRatio: 0.055,
            highlightRatio: 0.253,
            blackRatio: 0.01,
            whiteRatio: 0.04,
            noiseEstimate: 0.04,
            segmentation: SceneSegmentationDiagnostics(
                status: .available,
                reason: nil,
                skyCoverage: 0.104,
                groundCoverage: 0.328,
                vegetationCoverage: vegetationMask.activeCoverage,
                waterCoverage: 0,
                architectureCoverage: 0.015
            )
        )
        let hypotheses = AestheticTargetHypothesisGenerator().makeHypotheses(
            analysis: source,
            problems: detector.detect(in: source)
        )

        XCTAssertEqual(
            hypotheses.map { $0.kind.rawValue },
            [
                AestheticTargetHypothesisKind.spatialEmphasis.rawValue,
                AestheticTargetHypothesisKind.restrainedDepth.rawValue
            ]
        )
        XCTAssertGreaterThan(
            abs(
                hypotheses[0].profile.resolvedTarget.luminance
                    - hypotheses[1].profile.resolvedTarget.luminance
            ),
            0.0001
        )
        XCTAssertGreaterThan(hypotheses[0].profile.regionalColorSeparationTarget, 0.01)
        XCTAssertGreaterThan(
            hypotheses[0].profile.resolvedTarget.saturation,
            PhotographyTargetProfile.measuredBaseline(
                analysis: source,
                problems: detector.detect(in: source)
            ).resolvedTarget.saturation
        )
        XCTAssertEqual(hypotheses[0].targetQualityStatus, "uncertain_pending_render_and_human_review")
        XCTAssertTrue(hypotheses.allSatisfy { $0.profile.referenceInfluence == 0 })
        XCTAssertEqual(hypotheses[0].profile.regionalIntent?.tonalStructure, .spatialHierarchy)
        XCTAssertEqual(hypotheses[1].profile.regionalIntent?.tonalStructure, .restrainedDepth)
        let e1Ground = try XCTUnwrap(hypotheses[0].profile.regionalIntent?.groundLuminanceTarget)
        let e2Ground = try XCTUnwrap(hypotheses[1].profile.regionalIntent?.groundLuminanceTarget)
        let e1Vegetation = try XCTUnwrap(hypotheses[0].profile.regionalIntent?.vegetationLuminanceTarget)
        XCTAssertLessThan(e1Ground, e1Vegetation - 0.05)
        XCTAssertGreaterThan(abs(e1Ground - e2Ground), 0.025)
    }

    func testRenderedTargetExplorationRejectsBuild34LikeSimilarCandidates() {
        let assessment = PhotographyTargetExplorationValidator().assess(
            expectedIdentifiers: ["D", "E1", "E2"],
            pairDifferences: [
                PhotographyCandidatePairDifference(
                    firstIdentifier: "D", secondIdentifier: "E1",
                    rgbMeanAbsoluteDifference: 0.0115, changedPixelRatio: 0.72,
                    maximumRegionalLuminanceDifference: 0.021,
                    maximumRegionalColorDifference: 0.012
                ),
                PhotographyCandidatePairDifference(
                    firstIdentifier: "D", secondIdentifier: "E2",
                    rgbMeanAbsoluteDifference: 0.0083, changedPixelRatio: 0.69,
                    maximumRegionalLuminanceDifference: 0.018,
                    maximumRegionalColorDifference: 0.010
                ),
                PhotographyCandidatePairDifference(
                    firstIdentifier: "E1", secondIdentifier: "E2",
                    rgbMeanAbsoluteDifference: 0.0044, changedPixelRatio: 0.55,
                    maximumRegionalLuminanceDifference: 0.009,
                    maximumRegionalColorDifference: 0.006
                )
            ]
        )

        XCTAssertEqual(assessment.status, .invalidInsufficientRenderedDifference)
        XCTAssertTrue(assessment.reason.contains("candidate_generation_failed"))
    }

    func testRenderedTargetExplorationRequiresDistinctExperimentalIntents() {
        let assessment = PhotographyTargetExplorationValidator().assess(
            expectedIdentifiers: ["D", "E1", "E2"],
            pairDifferences: [
                PhotographyCandidatePairDifference(
                    firstIdentifier: "D", secondIdentifier: "E1",
                    rgbMeanAbsoluteDifference: 0.031, changedPixelRatio: 0.86,
                    maximumRegionalLuminanceDifference: 0.061,
                    maximumRegionalColorDifference: 0.030
                ),
                PhotographyCandidatePairDifference(
                    firstIdentifier: "D", secondIdentifier: "E2",
                    rgbMeanAbsoluteDifference: 0.027, changedPixelRatio: 0.84,
                    maximumRegionalLuminanceDifference: 0.052,
                    maximumRegionalColorDifference: 0.018
                ),
                PhotographyCandidatePairDifference(
                    firstIdentifier: "E1", secondIdentifier: "E2",
                    rgbMeanAbsoluteDifference: 0.022, changedPixelRatio: 0.79,
                    maximumRegionalLuminanceDifference: 0.041,
                    maximumRegionalColorDifference: 0.014
                )
            ]
        )

        XCTAssertEqual(assessment.status, .effectivePendingHumanReview)
        XCTAssertTrue(assessment.reason.contains("人工盲测"))
    }

    func testMeasuredAestheticHypothesesChangeWithExposureNotSceneName() {
        let bright = fixture(
            luminance: 0.66,
            contrast: 0.72,
            saturation: 0.18,
            labels: ["outdoor"],
            shadowRatio: 0.04,
            highlightRatio: 0.28,
            blackRatio: 0.008,
            whiteRatio: 0.05,
            noiseEstimate: 0.03
        )
        let dark = fixture(
            luminance: 0.31,
            contrast: 0.72,
            saturation: 0.18,
            labels: ["outdoor"],
            shadowRatio: 0.24,
            highlightRatio: 0.03,
            blackRatio: 0.07,
            whiteRatio: 0.005,
            noiseEstimate: 0.13
        )
        let generator = AestheticTargetHypothesisGenerator()
        let brightE1 = generator.makeHypotheses(
            analysis: bright,
            problems: detector.detect(in: bright)
        )[0]
        let darkE1 = generator.makeHypotheses(
            analysis: dark,
            problems: detector.detect(in: dark)
        )[0]

        XCTAssertGreaterThan(brightE1.profile.resolvedTarget.luminance, darkE1.profile.resolvedTarget.luminance)
        XCTAssertGreaterThan(
            abs(
                brightE1.profile.resolvedTarget.highlightRatio
                    - darkE1.profile.resolvedTarget.highlightRatio
            ),
            0.0001
        )
        XCTAssertTrue(brightE1.rationale.joined().contains("源亮度"))
    }

    func testManualV4ExpressionAvoidsBlackPointAndHarshLocalContrastDefaults() {
        let recipe = ManualPhotographyParameters.rendererVerification.makeRecipe()

        XCTAssertEqual(recipe.blackPoint, 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(recipe.toneCurveAmount, 0.09)
        XCTAssertLessThanOrEqual(recipe.localContrastAmount, 0.02)
        XCTAssertGreaterThanOrEqual(recipe.shadowAmount, 0.12)
        XCTAssertTrue(ManualPhotographyParameters.rendererVerification.identifier.contains("v4"))
    }

    func testMeasuredAestheticHypothesisReducesColorLiftWhenPersonEvidenceExists() {
        let vegetationMask = NormalizedPhotoMask(
            width: 4,
            height: 4,
            pixels: Data([0, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 0])
        )
        func source(faceCount: Int) -> PhotoAnalysis {
            fixture(
                luminance: 0.58,
                contrast: 0.72,
                saturation: 0.17,
                labels: ["outdoor"],
                faceCount: faceCount,
                vegetationMask: vegetationMask,
                vegetationStatistics: regionStatistics(
                    luminance: 0.44,
                    contrast: 0.58,
                    saturation: 0.21,
                    red: 0.44,
                    green: 0.41,
                    blue: 0.24,
                    yellowColorRatio: 0.46,
                    greenColorRatio: 0.23
                )
            )
        }
        let landscape = source(faceCount: 0)
        let portrait = source(faceCount: 1)
        let generator = AestheticTargetHypothesisGenerator()
        let landscapeTarget = generator.makeHypotheses(
            analysis: landscape,
            problems: detector.detect(in: landscape)
        )[0].profile.resolvedTarget.saturation
        let portraitTarget = generator.makeHypotheses(
            analysis: portrait,
            problems: detector.detect(in: portrait)
        )[0].profile.resolvedTarget.saturation
        let landscapeBaseline = PhotographyTargetProfile.measuredBaseline(
            analysis: landscape,
            problems: detector.detect(in: landscape)
        ).resolvedTarget.saturation
        let portraitBaseline = PhotographyTargetProfile.measuredBaseline(
            analysis: portrait,
            problems: detector.detect(in: portrait)
        ).resolvedTarget.saturation

        XCTAssertGreaterThan(
            landscapeTarget - landscapeBaseline,
            portraitTarget - portraitBaseline
        )
    }

    func testDiagnosticExportPolicyRejectsUnavailableCandidateEvenWithStaleStage() {
        XCTAssertNil(DiagnosticCandidateExportPolicy.resolvedStageName(
            stateNames: ["planned", "unavailable"],
            unavailableReasons: ["indexUnavailable"],
            imageStageName: "C 摄影参考验证候选"
        ))
    }

    func testDiagnosticExportPolicyRequiresExactExecutedStageName() {
        XCTAssertEqual(
            DiagnosticCandidateExportPolicy.resolvedStageName(
                stateNames: ["planned", "executed"],
                unavailableReasons: [],
                imageStageName: "D 新版逐图自动后期（passed）"
            ),
            "D 新版逐图自动后期（passed）"
        )
        XCTAssertNil(DiagnosticCandidateExportPolicy.resolvedStageName(
            stateNames: ["planned"],
            unavailableReasons: [],
            imageStageName: "D 旧预览"
        ))
    }

    private func syntheticImage(
        width: Int,
        height: Int,
        pixels: [(UInt8, UInt8, UInt8)]
    ) -> CIImage {
        precondition(pixels.count == width * height)
        var bytes = Data(capacity: width * height * 4)
        for pixel in pixels {
            bytes.append(pixel.0)
            bytes.append(pixel.1)
            bytes.append(pixel.2)
            bytes.append(255)
        }
        return CIImage(
            bitmapData: bytes,
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    private func constantImage(
        width: Int,
        height: Int,
        value: Float
    ) -> CIImage {
        constantImage(width: width, height: height, red: value, green: value, blue: value)
    }

    private func constantImage(
        width: Int,
        height: Int,
        red: Float,
        green: Float,
        blue: Float
    ) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func splitGrayImage(width: Int, height: Int, dark: Float, bright: Float) -> CIImage {
        let left = constantImage(width: width / 2, height: height, value: dark)
        let right = constantImage(width: width / 2, height: height, value: bright)
            .transformed(by: CGAffineTransform(translationX: CGFloat(width / 2), y: 0))
        return right.composited(over: left).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func rgba8(_ image: CIImage) throws -> [UInt8] {
        let bounds = image.extent.integral
        var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                image,
                toBitmap: baseAddress,
                rowBytes: Int(bounds.width) * 4,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }
        return bytes
    }

    private func assertRGB8(
        _ rgba: [UInt8],
        expected: [[Int]],
        tolerance: Int,
        stage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            rgba.count / 4,
            expected.count,
            "\(stage): unexpected pixel count",
            file: file,
            line: line
        )
        guard rgba.count / 4 == expected.count else { return }

        var actual: [[Int]] = []
        var maximumDelta = 0
        for pixelIndex in expected.indices {
            let offset = pixelIndex * 4
            let rgb = [Int(rgba[offset]), Int(rgba[offset + 1]), Int(rgba[offset + 2])]
            actual.append(rgb)
            for channel in 0..<3 {
                maximumDelta = max(maximumDelta, abs(rgb[channel] - expected[pixelIndex][channel]))
            }
        }
        XCTAssertLessThanOrEqual(
            maximumDelta,
            tolerance,
            "\(stage): max RGB8 delta \(maximumDelta), actual=\(actual), expected=\(expected)",
            file: file,
            line: line
        )
    }

    private func rgbSample(_ image: CIImage, x: Int, y: Int) throws -> (r: Float, g: Float, b: Float) {
        let bytes = try rgba8(image)
        let width = Int(image.extent.width)
        let offset = ((y * width) + x) * 4
        return (
            Float(bytes[offset]) / 255,
            Float(bytes[offset + 1]) / 255,
            Float(bytes[offset + 2]) / 255
        )
    }

    private func meanRGB(_ image: CIImage) throws -> (r: Float, g: Float, b: Float, luminance: Float) {
        let bytes = try rgba8(image)
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
        let count = Float(bytes.count / 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            red += Float(bytes[offset]) / 255
            green += Float(bytes[offset + 1]) / 255
            blue += Float(bytes[offset + 2]) / 255
        }
        red /= count
        green /= count
        blue /= count
        return (red, green, blue, (red * 0.2126) + (green * 0.7152) + (blue * 0.0722))
    }

    private func samplePair(_ image: CIImage, width: Int, height: Int) throws -> (left: Float, right: Float) {
        let left = try rgbSample(image, x: width / 4, y: height / 2)
        let right = try rgbSample(image, x: (width * 3) / 4, y: height / 2)
        return (
            (left.r + left.g + left.b) / 3,
            (right.r + right.g + right.b) / 3
        )
    }

    private func rgbDelta(_ lhs: [UInt8], _ rhs: [UInt8], pixel: Int) -> Int {
        let offset = pixel * 4
        return abs(Int(lhs[offset]) - Int(rhs[offset]))
            + abs(Int(lhs[offset + 1]) - Int(rhs[offset + 1]))
            + abs(Int(lhs[offset + 2]) - Int(rhs[offset + 2]))
    }

    private func rgbDistance(
        _ lhs: (r: Float, g: Float, b: Float),
        _ rhs: (r: Float, g: Float, b: Float)
    ) -> Float {
        abs(lhs.r - rhs.r) + abs(lhs.g - rhs.g) + abs(lhs.b - rhs.b)
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
        semanticObjectRegions: [SemanticObjectRegion] = [],
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
            neutralColorStatistics: neutralColorStatistics,
            semanticObjectRegions: semanticObjectRegions
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
        yellowColorRatio: Float = 0,
        greenColorRatio: Float = 0,
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
            yellowColorRatio: yellowColorRatio,
            greenColorRatio: greenColorRatio,
            shadowRatio: shadowRatio,
            highlightRatio: highlightRatio
        )
    }
}
