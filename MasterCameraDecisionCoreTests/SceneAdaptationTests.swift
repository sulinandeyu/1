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
        let autumnNightPath = decision(for: fixture(
            luminance: 0.139,
            contrast: 0.424,
            saturation: 0.534,
            red: 0.159,
            green: 0.138,
            blue: 0.091,
            labels: ["night", "trail", "tree", "outdoor"]
        ))

        XCTAssertEqual(autumnNightPath.sceneStrategy, .night)
        XCTAssertEqual(autumnNightPath.context.style, .professionalLandscape)
        XCTAssertTrue(autumnNightPath.context.sceneFacets.contains(.countryRoad))
        XCTAssertTrue(autumnNightPath.context.sceneFacets.contains(.forest))
        XCTAssertGreaterThan(autumnNightPath.recipe.hsl.yellowSaturation, -0.015)
        XCTAssertGreaterThan(autumnNightPath.recipe.hsl.orangeSaturation, 0)
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
        personMask: NormalizedPhotoMask? = nil
    ) -> PhotoAnalysis {
        PhotoAnalysis(
            averageLuminance: luminance,
            contrastRange: contrast,
            redAverage: red,
            greenAverage: green,
            blueAverage: blue,
            shadowRatio: 0.12,
            highlightRatio: 0.08,
            averageSaturation: saturation,
            detailScore: 0.22,
            noiseEstimate: 0.05,
            blackRatio: 0.01,
            whiteRatio: 0.01,
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
            semanticLabels: labels.map { SceneLabel(identifier: $0, confidence: 0.8) }
        )
    }
}
