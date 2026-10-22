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

    private func decision(for analysis: PhotoAnalysis) -> PhotographyDecision {
        engine.makeDecision(for: analysis, problems: detector.detect(in: analysis))
    }

    private func fixture(
        luminance: Float = 0.5,
        contrast: Float = 0.58,
        saturation: Float = 0.2,
        labels: [String],
        skyMask: NormalizedPhotoMask? = nil
    ) -> PhotoAnalysis {
        PhotoAnalysis(
            averageLuminance: luminance,
            contrastRange: contrast,
            redAverage: 0.46,
            greenAverage: 0.48,
            blueAverage: 0.49,
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
            faceCount: 0,
            faceRegions: [],
            faceAverageLuminance: nil,
            backgroundAverageLuminance: nil,
            personMask: nil,
            salientSubjectMask: nil,
            skinMask: nil,
            skyMask: skyMask,
            skyCoverage: skyMask == nil ? 0 : 0.38,
            semanticLabels: labels.map { SceneLabel(identifier: $0, confidence: 0.8) }
        )
    }
}
