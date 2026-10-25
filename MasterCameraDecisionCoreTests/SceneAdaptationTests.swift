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

    func testDifferentSceneEvidenceProducesDifferentExecutedRecipes() {
        let coast = decision(for: fixture(labels: ["outdoor", "seashore", "ocean", "sky"]))
        let plaza = decision(for: fixture(labels: ["outdoor", "building", "architecture", "sky"]))

        XCTAssertNotEqual(coast.sceneStrategy, plaza.sceneStrategy)
        XCTAssertNotEqual(coast.recipe.hsl, plaza.recipe.hsl)
        XCTAssertNotEqual(coast.recipe.colorGradeIntensity, plaza.recipe.colorGradeIntensity)
        XCTAssertNotEqual(coast.recipe.shadowCoolAmount, plaza.recipe.shadowCoolAmount)
        XCTAssertNotEqual(coast.recipe.traceSummary, plaza.recipe.traceSummary)
    }

    func testOvercastAndClearSkyDoNotReceiveOneFixedSkyPreset() {
        let mask = NormalizedPhotoMask(width: 1, height: 1, pixels: Data([255]))
        let overcast = decision(for: fixture(
            luminance: 0.48,
            contrast: 0.40,
            saturation: 0.15,
            labels: ["outdoor", "seashore", "ocean", "sky"],
            skyMask: mask
        ))
        let clear = decision(for: fixture(
            luminance: 0.56,
            contrast: 0.68,
            saturation: 0.18,
            labels: ["outdoor", "landscape", "sky"],
            skyMask: mask
        ))

        XCTAssertTrue(overcast.context.lightingConditions.contains(.overcast))
        XCTAssertLessThanOrEqual(overcast.recipe.skySaturation, 0.995)
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
        XCTAssertNotEqual(autumnNightPath.aestheticTarget, warmBedroom.aestheticTarget)
        XCTAssertNotEqual(autumnNightPath.treatmentPlan.finalLook, warmBedroom.treatmentPlan.finalLook)
        XCTAssertNotEqual(autumnNightPath.recipe.toneCurveStyle, warmBedroom.recipe.toneCurveStyle)
        XCTAssertNotEqual(autumnNightPath.recipe.temperatureShift, warmBedroom.recipe.temperatureShift)
        XCTAssertNotEqual(autumnNightPath.recipe.hsl, warmBedroom.recipe.hsl)
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
            vegetationMask: regionMask
        ))

        XCTAssertEqual(autumnNightPath.sceneStrategy, .night)
        XCTAssertEqual(autumnNightPath.context.style, .professionalLandscape)
        XCTAssertTrue(autumnNightPath.context.sceneFacets.contains(.countryRoad))
        XCTAssertTrue(autumnNightPath.context.sceneFacets.contains(.forest))
        XCTAssertGreaterThan(autumnNightPath.recipe.hsl.yellowSaturation, -0.015)
        XCTAssertGreaterThan(autumnNightPath.recipe.hsl.orangeSaturation, 0)
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
        XCTAssertGreaterThan(result.recipe.skySaturation, 1)
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

    private func decision(for analysis: PhotoAnalysis) -> PhotographyDecision {
        engine.makeDecision(for: analysis, problems: detector.detect(in: analysis))
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
            detailScore: 0.22,
            noiseEstimate: 0.05,
            blackRatio: blackRatio,
            whiteRatio: whiteRatio,
            midtoneRatio: 0.7,
            mixedLightScore: 0.05,
            highlightConcentration: 0.05,
            highlightSourceCount: 0,
            highlightCentroidX: 0.5,
            highlightCentroidY: 0.5,
            spatialLuminanceVariance: 0.08,
            faceCount: faceCount,
            faceRegions: faceCount > 0
                ? [NormalizedPhotoRegion(x: 0.3, y: 0.35, width: 0.25, height: 0.25)]
                : [],
            faceAverageLuminance: faceLuminance,
            backgroundAverageLuminance: backgroundLuminance,
            personMask: personMask,
            salientSubjectMask: nil,
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
            segmentationDiagnostics: segmentation
        )
    }

    private func regionStatistics(
        luminance: Float,
        contrast: Float,
        saturation: Float,
        red: Float,
        green: Float,
        blue: Float
    ) -> PhotoRegionStatistics {
        PhotoRegionStatistics(
            averageLuminance: luminance,
            contrastRange: contrast,
            redAverage: red,
            greenAverage: green,
            blueAverage: blue,
            averageSaturation: saturation,
            shadowRatio: 0.02,
            highlightRatio: 0.06
        )
    }
}
