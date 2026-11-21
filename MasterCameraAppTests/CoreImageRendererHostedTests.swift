import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import MasterCamera

/// App-hosted tests cover the real renderer/encoder boundary that the Swift
/// package cannot import because it depends on UIKit and the application model.
/// They are Apple-Simulator evidence only, not iPhone or aesthetic acceptance.
final class CoreImageRendererHostedTests: XCTestCase {
    func testNeutralManualRenderKeepsGeometryOrientationAndRGBContract() throws {
        let source = try sourceJPEG(width: 96, height: 64)
        let output = try CoreImageRenderer().renderManualEdit(
            from: source,
            parameters: ManualPhotographyParameters(identifier: "hosted-neutral"),
            analysis: nil
        )
        let properties = try imageProperties(output)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 96)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 64)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, "RGB")
        XCTAssertLessThan(meanAbsoluteDifference(source, output), 0.018)
    }

    func testTask2ACandidateUsesFullResolutionProductionRenderer() throws {
        let source = try sourceJPEG(width: 128, height: 80)
        let output = try CoreImageRenderer().renderManualEdit(
            from: source,
            parameters: .task2ACinematicExpression,
            analysis: nil
        )
        let properties = try imageProperties(output)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 128)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 80)
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, "RGB")
        XCTAssertGreaterThan(meanAbsoluteDifference(source, output), 0.01)
        let modules = CoreImageRenderer().executedModuleNames(
            for: ManualPhotographyParameters.task2ACinematicExpression.makeRecipe(),
            analysis: nil,
            manualRegionalAdjustments: []
        )
        XCTAssertTrue(modules.contains("独立 RGB 七段曲线"))
        XCTAssertTrue(modules.contains("分区 HSL"))
        XCTAssertTrue(modules.contains("显式阴影/中间调/高光色彩分级"))
    }

    func testOriginalICCIsNotCopiedOntoRenderedSRGBPixels() throws {
        let source = try sourceJPEG(width: 48, height: 32, displayP3: true)
        let output = try CoreImageRenderer().renderManualEdit(
            from: source,
            parameters: ManualPhotographyParameters(identifier: "hosted-color-contract"),
            analysis: nil
        )
        let properties = try imageProperties(output)
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, "RGB")
        let profileName = (properties[kCGImagePropertyProfileName] as? String)?.lowercased() ?? ""
        XCTAssertFalse(profileName.contains("display p3"))
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let colorSpace = exif?[kCGImagePropertyExifColorSpace] as? NSNumber {
            XCTAssertEqual(colorSpace.intValue, 1)
        }
        XCTAssertLessThan(meanAbsoluteDifference(source, output), 0.025)
    }

    func testDiagnosticEvidenceUsesActualSourceAndTargetFileTypes() throws {
        let jpeg = try sourceJPEG(width: 20, height: 12)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 12))
        let png = renderer.image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        }.pngData()!
        XCTAssertTrue(["jpeg", "jpg"].contains(DiagnosticBundleExporter.imageFileExtension(jpeg)))
        XCTAssertEqual(DiagnosticBundleExporter.imageFileExtension(png), "png")
    }

    func testTask2ARegionsWithoutReliableMasksAreReportedSkipped() {
        let parameters = ManualPhotographyParameters.task2ACinematicExpression
        let details = CoreImageRenderer().manualRegionalExecutionDetails(
            analysis: nil,
            adjustments: parameters.regionalToneAdjustments
        )
        XCTAssertFalse(details.isEmpty)
        XCTAssertTrue(details.allSatisfy { $0.contains("跳过") })
        XCTAssertFalse(details.contains { $0.contains("已执行") })
    }

    func testFormalBPipelineRendersTheRecordedFinalRecipe() throws {
        let source = try productionJPEG(width: 160, height: 112, variant: .balanced)
        let input = CapturedPhoto(
            originalImageData: source,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let result = try PhotoProcessingPipeline(referenceMatcher: nil).process(input)
        let decision = try XCTUnwrap(result.decision)
        let diagnostics = try XCTUnwrap(result.processingDiagnostics)
        let quality = try XCTUnwrap(result.qualityCheck)

        XCTAssertFalse(result.editedImageData.isEmpty)
        XCTAssertNotEqual(quality.status, .failed)
        XCTAssertTrue(decision.parameterEvidence.contains { evidence in
            evidence.knowledgeRuleIDs.contains(.productionMeasuredAutomaticEdit)
        })
        XCTAssertEqual(
            diagnostics.candidateEvaluations.filter(\.selected).count,
            1,
            "Formal B must preserve the exact selected candidate in its execution record."
        )

        let rerendered = try CoreImageRenderer().renderAutomaticEdit(
            from: source,
            recipe: decision.recipe,
            analysis: result.analysis,
            adaptiveRegionalTonePlan: decision.adaptiveRegionalTonePlan
        )
        XCTAssertLessThan(
            meanAbsoluteDifference(result.editedImageData, rerendered),
            0.002,
            "The delivered B pixels must match the recorded final recipe and regional plan."
        )
        XCTAssertGreaterThan(
            meanAbsoluteDifference(source, result.editedImageData),
            0.001,
            "A measured correction must not be silently cleared after candidate selection."
        )
    }

    func testFormalBMeasuredRegionalPlanChangesRenderedPixels() throws {
        let source = try productionJPEG(width: 160, height: 112, variant: .warmAccent)
        let analysis = productionRegionalAnalysis()
        let detector = PhotoProblemDetector()
        let report = detector.detect(in: analysis)
        let target = PhotographyTargetProfile.measuredProduction(
            analysis: analysis,
            problems: report
        )
        let decision = PhotographyDirector().direct(
            analysis: analysis,
            problems: report,
            targetProfile: target,
            structuredDiagnosis: detector.structuredDiagnosis(in: analysis, report: report),
            enableMeasuredAestheticPlanning: true
        )
        let plan = try XCTUnwrap(decision.adaptiveRegionalTonePlan)
        XCTAssertFalse(plan.adjustments.isEmpty)
        XCTAssertEqual(target.hypothesisIdentifier, "B-production-measured-color-separation")

        let renderer = CoreImageRenderer()
        let globalOnly = try renderer.renderAutomaticEdit(
            from: source,
            recipe: decision.recipe,
            analysis: analysis,
            adaptiveRegionalTonePlan: nil
        )
        let regional = try renderer.renderAutomaticEdit(
            from: source,
            recipe: decision.recipe,
            analysis: analysis,
            adaptiveRegionalTonePlan: plan
        )
        XCTAssertGreaterThan(
            meanAbsoluteDifference(globalOnly, regional),
            0.002,
            "A planned formal-B regional correction must have measurable pixel impact."
        )
        let details = renderer.adaptiveRegionalExecutionDetails(
            analysis: analysis,
            plan: plan
        )
        XCTAssertTrue(details.contains { $0.contains("已执行") })
        XCTAssertFalse(details.contains { $0.contains("planned") && !$0.contains("executed") })
    }

    private func sourceJPEG(
        width: Int,
        height: Int,
        displayP3: Bool = false
    ) throws -> Data {
        if displayP3 {
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            let context = CIContext(options: [.workingColorSpace: p3])
            let image = CIImage(
                color: CIColor(red: 0.72, green: 0.26, blue: 0.16, alpha: 1)
            ).cropped(to: CGRect(
                x: 0, y: 0,
                width: CGFloat(width), height: CGFloat(height)
            ))
            guard let data = context.jpegRepresentation(of: image, colorSpace: p3, options: [:]) else {
                throw TestError.encoding
            }
            return data
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format
        ).image { context in
            UIColor(red: 0.14, green: 0.18, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            UIColor(red: 0.86, green: 0.64, blue: 0.20, alpha: 1).setFill()
            context.fill(CGRect(
                x: CGFloat(width) / 2, y: 0,
                width: CGFloat(width) / 2, height: CGFloat(height)
            ))
        }
        guard let data = image.jpegData(compressionQuality: 0.96) else {
            throw TestError.encoding
        }
        return data
    }

    private enum ProductionFixtureVariant { case balanced, warmAccent }

    private func productionJPEG(
        width: Int,
        height: Int,
        variant: ProductionFixtureVariant
    ) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            format: format
        ).image { context in
            let cg = context.cgContext
            let colors: [CGColor]
            switch variant {
            case .balanced:
                colors = [
                    UIColor(red: 0.20, green: 0.24, blue: 0.29, alpha: 1).cgColor,
                    UIColor(red: 0.58, green: 0.55, blue: 0.49, alpha: 1).cgColor
                ]
            case .warmAccent:
                colors = [
                    UIColor(red: 0.24, green: 0.27, blue: 0.29, alpha: 1).cgColor,
                    UIColor(red: 0.82, green: 0.57, blue: 0.16, alpha: 1).cgColor
                ]
            }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let gradient = CGGradient(
                colorsSpace: space,
                colors: colors as CFArray,
                locations: [0, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: CGPoint(x: CGFloat(width), y: 0),
                options: []
            )
            UIColor(white: 0.88, alpha: 1).setFill()
            context.fill(CGRect(
                x: CGFloat(width) * 0.68,
                y: CGFloat(height) * 0.55,
                width: CGFloat(width) * 0.12,
                height: CGFloat(height) * 0.12
            ))
        }
        guard let data = image.jpegData(compressionQuality: 0.97) else {
            throw TestError.encoding
        }
        return data
    }

    private func productionRegionalAnalysis() -> PhotoAnalysis {
        let width = 8
        let height = 8
        var ground = [UInt8](repeating: 0, count: width * height)
        var vegetation = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if y >= height / 2 { ground[index] = 255 }
                if y < height / 2 { vegetation[index] = 255 }
            }
        }
        let groundMask = NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(ground)
        )
        let vegetationMask = NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(vegetation)
        )
        return PhotoAnalysis(
            averageLuminance: 0.48,
            contrastRange: 0.62,
            redAverage: 0.48,
            greenAverage: 0.43,
            blueAverage: 0.34,
            shadowRatio: 0.12,
            highlightRatio: 0.08,
            averageSaturation: 0.24,
            detailScore: 0.34,
            noiseEstimate: 0.04,
            blackRatio: 0.012,
            whiteRatio: 0.008,
            midtoneRatio: 0.72,
            mixedLightScore: 0.11,
            highlightConcentration: 0.05,
            highlightSourceCount: 0,
            highlightCentroidX: 0.5,
            highlightCentroidY: 0.5,
            spatialLuminanceVariance: 0.10,
            faceCount: 0,
            faceRegions: [],
            faceAverageLuminance: nil,
            backgroundAverageLuminance: 0.48,
            personMask: nil,
            salientSubjectMask: nil,
            salientSubjectStatistics: nil,
            skinMask: nil,
            skyMask: nil,
            skyCoverage: 0,
            groundMask: groundMask,
            vegetationMask: vegetationMask,
            waterMask: nil,
            architectureMask: nil,
            skyStatistics: nil,
            groundStatistics: PhotoRegionStatistics(
                averageLuminance: 0.59,
                contrastRange: 0.50,
                redAverage: 0.55,
                greenAverage: 0.54,
                blueAverage: 0.51,
                averageSaturation: 0.08,
                yellowColorRatio: 0.04,
                greenColorRatio: 0.02,
                shadowRatio: 0.04,
                highlightRatio: 0.10
            ),
            vegetationStatistics: PhotoRegionStatistics(
                averageLuminance: 0.38,
                contrastRange: 0.57,
                redAverage: 0.46,
                greenAverage: 0.42,
                blueAverage: 0.22,
                averageSaturation: 0.35,
                yellowColorRatio: 0.48,
                greenColorRatio: 0.22,
                shadowRatio: 0.09,
                highlightRatio: 0.05
            ),
            waterStatistics: nil,
            architectureStatistics: nil,
            semanticLabels: [],
            sceneRecognitionDiagnostics: SceneRecognitionDiagnostics(
                status: .uncertain,
                topConfidence: 0,
                acceptedLabelCount: 0,
                reason: "hosted test deliberately omits scene labels"
            ),
            segmentationDiagnostics: SceneSegmentationDiagnostics(
                status: .available,
                reason: nil,
                skyCoverage: 0,
                groundCoverage: 0.5,
                vegetationCoverage: 0.5,
                waterCoverage: 0,
                architectureCoverage: 0
            ),
            neutralColorStatistics: NeutralColorStatistics(
                sampleCount: 1024,
                coverage: 0.26,
                spatialZoneCoverage: 0.78,
                redAverage: 0.55,
                greenAverage: 0.54,
                blueAverage: 0.51,
                averageLuminance: 0.54,
                averageChroma: 0.04,
                confidence: 0.88
            ),
            semanticObjectRegions: []
        )
    }

    private func imageProperties(_ data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw TestError.decoding }
        return properties
    }

    private func meanAbsoluteDifference(_ lhs: Data, _ rhs: Data) -> Double {
        guard let left = UIImage(data: lhs)?.cgImage,
              let right = UIImage(data: rhs)?.cgImage,
              left.width == right.width, left.height == right.height
        else { return 0 }
        let width = left.width
        let height = left.height
        var leftBytes = [UInt8](repeating: 0, count: width * height * 4)
        var rightBytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let leftContext = CGContext(
            data: &leftBytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let rightContext = CGContext(
            data: &rightBytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        leftContext.draw(left, in: bounds)
        rightContext.draw(right, in: bounds)
        let sum = zip(leftBytes, rightBytes).enumerated().reduce(0.0) { total, item in
            item.offset % 4 == 3
                ? total
                : total + Double(abs(Int(item.element.0) - Int(item.element.1))) / 255
        }
        return sum / Double(width * height * 3)
    }

    private enum TestError: Error { case encoding, decoding }
}
