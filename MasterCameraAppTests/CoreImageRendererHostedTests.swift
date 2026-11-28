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

    func testNormalReleaseDoesNotAuthorizeProductionCaptureEvidence() {
        XCTAssertFalse(
            InternalCaptureEvidenceBuildPolicy.isEnabled,
            "The ordinary CI/Release configuration must not expose the internal normal-capture exporter."
        )
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

        let deliveredB = result.editedImageData
        let exporter = DiagnosticBundleExporter(allowsProductionCaptureEvidence: true)
        let identity = try exporter.productionCaptureEvidenceIdentity(for: result)
        XCTAssertEqual(identity.captureID, result.id)
        XCTAssertEqual(identity.sourceSHA256, DiagnosticBundleExporter.sourceSHA256(source))
        XCTAssertEqual(identity.formalBSHA256, DiagnosticBundleExporter.sourceSHA256(deliveredB))

        let archive = try exporter.makeProductionCaptureArchive(for: result)
        defer { try? FileManager.default.removeItem(at: archive) }
        let archiveBytes = try Data(contentsOf: archive)
        XCTAssertNotNil(
            archiveBytes.range(of: source),
            "The stored ZIP must contain the exact original bytes, not a re-encoded A."
        )
        XCTAssertNotNil(
            archiveBytes.range(of: deliveredB),
            "The stored ZIP must contain the exact delivered B bytes, not a rerender."
        )
        for value in [
            result.id.uuidString,
            identity.sourceSHA256,
            identity.formalBSHA256,
            "formal_b_execution.json",
            "read_existing_bytes_only_no_rerender"
        ] {
            XCTAssertNotNil(
                archiveBytes.range(of: Data(value.utf8)),
                "Missing normal-capture evidence marker: \(value)"
            )
        }
        XCTAssertEqual(result.editedImageData, deliveredB)
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

    func testFormalBPipelineOutputsBForRoadVehicleAndIndoorNeutralFixtures() throws {
        for variant in [ProductionFixtureVariant.roadVehicle, .indoorNeutral] {
            let source = try productionJPEG(width: 176, height: 128, variant: variant)
            let input = CapturedPhoto(
                originalImageData: source,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
            let result = try PhotoProcessingPipeline(referenceMatcher: nil).process(input)
            XCTAssertFalse(result.editedImageData.isEmpty, "\(variant) must deliver a real formal B")
            XCTAssertNotEqual(result.qualityCheck?.status, .failed)
            XCTAssertNotNil(result.decision)
        }
    }

    func testIntentionalGroundToneRequiresExecutedReceiptAndKeepsProtectedWhiteSubject() throws {
        let source = try productionJPEG(width: 176, height: 128, variant: .roadVehicle)
        let analysis = productionRegionalAnalysis(includeProtectedSubject: true)
        let adjustment = ManualRegionalToneAdjustment(
            region: .ground,
            exposureEV: -1.0,
            blackPoint: 0.05,
            lowerMidtoneLift: -0.24,
            midtoneBias: -0.24,
            highlightRollOff: 0.12,
            luminanceLowerBound: 0.08,
            luminanceUpperBound: 0.82,
            luminanceFeather: 0.10
        )
        let plan = AdaptiveRegionalTonePlan(
            adjustments: [adjustment],
            evidence: ["hosted PT-QA-005 ground tone"]
        )
        let renderer = CoreImageRenderer()
        let edited = try renderer.renderAutomaticEdit(
            from: source,
            recipe: .naturalEnhancement,
            analysis: analysis,
            adaptiveRegionalTonePlan: plan
        )
        let executed = renderer.adaptiveRegionalExecutionDetails(analysis: analysis, plan: plan)
        XCTAssertTrue(executed.contains { $0.hasPrefix("地面/道路：已执行") })

        let service = QualityCheckService()
        let withoutAttribution = try service.check(
            originalData: source,
            editedData: edited,
            sourceAnalysis: analysis,
            expectedRegions: [.ground],
            regionalExecutionDetails: executed
        )
        XCTAssertTrue(withoutAttribution.issues.contains(.neutralLuminanceLoss))

        let attributed = try service.check(
            originalData: source,
            editedData: edited,
            sourceAnalysis: analysis,
            expectedRegions: [.ground],
            regionalExecutionDetails: executed,
            intentionalNeutralToneRegions: plan.intentionalNeutralToneRegions
        )
        XCTAssertFalse(attributed.issues.contains(.neutralLuminanceLoss))
        XCTAssertGreaterThan(attributed.colorIntegrity.intentionalToneNeutralCoverage, 0.05)
        XCTAssertGreaterThan(attributed.colorIntegrity.protectedNeutralCoverage, 0.015)

        let skipped = try service.check(
            originalData: source,
            editedData: edited,
            sourceAnalysis: analysis,
            expectedRegions: [],
            regionalExecutionDetails: ["地面/道路：跳过（故障注入）"],
            intentionalNeutralToneRegions: plan.intentionalNeutralToneRegions
        )
        XCTAssertTrue(
            skipped.issues.contains(.neutralLuminanceLoss),
            "A merely planned or skipped region must never receive an intentional-tone exemption."
        )
    }

    func testSevereProtectedNeutralDamageRemainsRejectedWithIntentionalGroundTone() throws {
        let source = try productionJPEG(width: 176, height: 128, variant: .roadVehicle)
        let damaged = try exposureAdjustedJPEG(source, ev: -1.0)
        let analysis = productionRegionalAnalysis(includeProtectedSubject: true)
        let result = try QualityCheckService().check(
            originalData: source,
            editedData: damaged,
            sourceAnalysis: analysis,
            expectedRegions: [],
            regionalExecutionDetails: ["地面/道路：已执行（故障注入）"],
            intentionalNeutralToneRegions: [.ground]
        )
        XCTAssertTrue(result.issues.contains(.neutralLuminanceLoss))
        XCTAssertEqual(result.status, .failed)
        XCTAssertLessThan(
            result.colorIntegrity.protectedNeutralLuminanceShift,
            NeutralToneSafetyAttribution.protectedLuminanceLossThreshold
        )
    }

    func testRejectedFormalBCandidateExportsExactPixelsWithoutBecomingDeliverableB() throws {
        let source = try productionJPEG(width: 176, height: 128, variant: .roadVehicle)
        let rejected = try exposureAdjustedJPEG(source, ev: -1.0)
        let analysis = productionRegionalAnalysis(includeProtectedSubject: true)
        let quality = try QualityCheckService().check(
            originalData: source,
            editedData: rejected,
            sourceAnalysis: analysis
        )
        XCTAssertEqual(quality.status, .failed)
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.exposureEV = -0.35
        let evidence = RejectedFormalBEvidence(
            candidateImageData: rejected,
            recipe: recipe.clamped(),
            initialQualityCheck: quality,
            finalQualityCheck: quality,
            analysis: analysis,
            regionalExecutionDetails: [],
            rejectionReason: quality.issues.map(\.rawValue).joined(separator: ",")
        )
        let photo = CapturedPhoto(
            originalImageData: source,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_200),
            rejectedFormalBEvidence: evidence
        )
        XCTAssertTrue(photo.editedImageData.isEmpty)
        XCTAssertFalse(photo.hasCompletedProcessing)

        let archive = try DiagnosticBundleExporter(allowsProductionCaptureEvidence: true)
            .makeRejectedProductionCaptureArchive(for: photo)
        defer { try? FileManager.default.removeItem(at: archive) }
        let bytes = try Data(contentsOf: archive)
        XCTAssertNotNil(bytes.range(of: source))
        XCTAssertNotNil(bytes.range(of: rejected))
        for marker in ["state", "rejected", "REJECTED_NOT_A_FORMAL_B.txt"] {
            XCTAssertNotNil(bytes.range(of: Data(marker.utf8)))
        }
    }

    func testNeutralLuminanceCorrectionTargetsCurveAndRecoversDeliverable() throws {
        let source = try productionJPEG(width: 176, height: 128, variant: .indoorNeutral)
        let analysis = productionRegionalAnalysis(includeProtectedSubject: true)
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.exposureEV = -0.35
        recipe.blackPoint = 0.028
        recipe.lowerMidtoneLift = -0.08
        recipe.midtoneBias = -0.08
        recipe.toneCurveAmount = 0.78
        recipe.rgbCurves = ProfessionalRGBCurves(
            red: SevenPointChannelCurve(shadow: 0.04, lowerMidtone: 0.15, midtone: 0.40, upperMidtone: 0.63, highlight: 0.84),
            green: SevenPointChannelCurve(shadow: 0.04, lowerMidtone: 0.15, midtone: 0.40, upperMidtone: 0.63, highlight: 0.84),
            blue: SevenPointChannelCurve(shadow: 0.04, lowerMidtone: 0.15, midtone: 0.40, upperMidtone: 0.63, highlight: 0.84),
            intensity: 0.82
        )
        recipe = recipe.clamped()
        let renderer = CoreImageRenderer()
        let initial = try renderer.renderAutomaticEdit(
            from: source,
            recipe: recipe,
            analysis: analysis,
            adaptiveRegionalTonePlan: nil
        )
        let initialQuality = try QualityCheckService().check(
            originalData: source,
            editedData: initial,
            sourceAnalysis: analysis
        )
        XCTAssertTrue(initialQuality.issues.contains(.neutralLuminanceLoss))

        let target = AdaptivePhotographyTarget(
            luminance: analysis.averageLuminance,
            luminanceMinimum: analysis.averageLuminance - 0.08,
            luminanceMaximum: analysis.averageLuminance + 0.08,
            contrast: analysis.contrastRange,
            shadowRatio: analysis.shadowRatio,
            highlightRatio: analysis.highlightRatio,
            saturation: analysis.averageSaturation,
            atmosphereProtection: 0.8,
            rationale: "hosted correction recovery"
        )
        let final = try PhotoProcessingPipeline(referenceMatcher: nil).chooseFinalEdit(
            originalData: source,
            initialEditedData: initial,
            initialQualityCheck: initialQuality,
            initialRecipe: recipe,
            target: target,
            analysis: analysis,
            expectedRegions: [],
            adaptiveRegionalTonePlan: nil
        )
        XCTAssertNotEqual(final.qualityCheck.status, .failed)
        XCTAssertFalse(final.qualityCheck.issues.contains(.neutralLuminanceLoss))
        XCTAssertTrue(final.qualityCheck.fallbackApplied)
        XCTAssertFalse(final.data.isEmpty)
        XCTAssertLessThan(final.recipe.rgbCurves.intensity, recipe.rgbCurves.intensity)
        XCTAssertLessThan(final.recipe.blackPoint, recipe.blackPoint)
        XCTAssertLessThan(abs(final.recipe.midtoneBias), abs(recipe.midtoneBias))
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

    private enum ProductionFixtureVariant: Equatable, CustomStringConvertible {
        case balanced, warmAccent, roadVehicle, indoorNeutral

        var description: String {
            switch self {
            case .balanced: return "balanced"
            case .warmAccent: return "warmAccent"
            case .roadVehicle: return "roadVehicle"
            case .indoorNeutral: return "indoorNeutral"
            }
        }
    }

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
            case .roadVehicle:
                colors = [
                    UIColor(red: 0.34, green: 0.36, blue: 0.35, alpha: 1).cgColor,
                    UIColor(red: 0.74, green: 0.58, blue: 0.20, alpha: 1).cgColor
                ]
            case .indoorNeutral:
                colors = [
                    UIColor(red: 0.40, green: 0.39, blue: 0.37, alpha: 1).cgColor,
                    UIColor(red: 0.68, green: 0.65, blue: 0.60, alpha: 1).cgColor
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
            if variant == .roadVehicle || variant == .indoorNeutral {
                UIColor(white: 0.84, alpha: 1).setFill()
                context.fill(CGRect(
                    x: CGFloat(width) * 0.64,
                    y: CGFloat(height) * 0.56,
                    width: CGFloat(width) * 0.18,
                    height: CGFloat(height) * 0.18
                ))
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.97) else {
            throw TestError.encoding
        }
        return data
    }

    private func productionRegionalAnalysis(includeProtectedSubject: Bool = false) -> PhotoAnalysis {
        let width = 8
        let height = 8
        var ground = [UInt8](repeating: 0, count: width * height)
        var vegetation = [UInt8](repeating: 0, count: width * height)
        var subject = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if y >= height / 2 { ground[index] = 255 }
                if y < height / 2 { vegetation[index] = 255 }
                if includeProtectedSubject, x >= 5, x <= 6, y >= 4, y <= 5 {
                    subject[index] = 255
                }
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
        let subjectMask = includeProtectedSubject ? NormalizedPhotoMask(
            width: width,
            height: height,
            pixels: Data(subject)
        ) : nil
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
            salientSubjectMask: subjectMask,
            salientSubjectStatistics: includeProtectedSubject ? PhotoRegionStatistics(
                averageLuminance: 0.84,
                contrastRange: 0.18,
                redAverage: 0.84,
                greenAverage: 0.84,
                blueAverage: 0.84,
                averageSaturation: 0.01,
                yellowColorRatio: 0,
                greenColorRatio: 0,
                shadowRatio: 0,
                highlightRatio: 0.04
            ) : nil,
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

    private func exposureAdjustedJPEG(_ data: Data, ev: Float) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw TestError.decoding
        }
        let filter = CIFilter(name: "CIExposureAdjust")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(ev, forKey: kCIInputEVKey)
        let output = filter.outputImage!.cropped(to: image.extent)
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
        guard let encoded = context.jpegRepresentation(
            of: output,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [:]
        ) else { throw TestError.encoding }
        return encoded
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

    /// PT-LEARN-007 compares the real Apple colour operators with a Windows
    /// reference generated entirely from programmatic pixels.  It deliberately
    /// does not read the private autumn A/T pair and is not an aesthetic test.
    func testCrossPlatformOracleContractOnProgrammaticPixels() throws {
        let fixture = try crossPlatformFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.colorContract.working, "extended-linear-sRGB")
        XCTAssertEqual(fixture.operatorOrder, [
            "linear_exposure", "encoded_master_curve", "encoded_rgb_curves",
            "perceptual_hsl", "three_way_grade", "regional_linear_adjustments"
        ])
        let source = try fixtureImage(fixture)
        var output = CoreImageParameterKernel.exposure(source, ev: fixture.parameters.exposureEV)
        let curveProcessor = ProfessionalRGBCurveProcessor()
        let master = try channelCurve(fixture.parameters.masterCurve)
        output = curveProcessor.apply(
            to: output,
            curves: ProfessionalRGBCurves(red: master, green: master, blue: master, intensity: 1)
        )
        output = curveProcessor.apply(
            to: output,
            curves: ProfessionalRGBCurves(
                red: try channelCurve(fixture.parameters.rgbCurves[0]),
                green: try channelCurve(fixture.parameters.rgbCurves[1]),
                blue: try channelCurve(fixture.parameters.rgbCurves[2]),
                intensity: fixture.parameters.rgbIntensity
            )
        )
        output = ProfessionalHSLProcessor().apply(
            to: output,
            adjustment: try hslAdjustment(fixture.parameters.hsl)
        )
        var gradeRecipe = AutomaticEditingRecipe.naturalEnhancement
        gradeRecipe.tonalColorGrade = try tonalGrade(fixture.parameters.tonalGrade)
        output = CinematicColorGradingEngine().apply(to: output, recipe: gradeRecipe)

        let globalBytes = try renderedRGB(output, width: fixture.width, height: fixture.height)
        let globalExpected = try decodedRGB(fixture.windowsGlobalRGBBase64, count: fixture.width * fixture.height * 3)
        let globalError = pixelError(globalBytes, globalExpected)
        print(String(format: "PT-LEARN-007 Apple/Windows global MAE=%.6f max=%.6f", globalError.mae, globalError.maximum))
        XCTAssertLessThan(globalError.mae, 0.018)
        XCTAssertLessThan(globalError.maximum, 0.10)

        let regional = DiagnosticRegionalToneProcessor()
        for item in fixture.parameters.regional {
            guard let encodedMask = fixture.masksFloat32Base64[item.region] else {
                XCTFail("missing mask \(item.region)"); continue
            }
            output = regional.apply(
                to: output,
                semanticMask: try fixtureMask(encodedMask, width: fixture.width, height: fixture.height),
                adjustment: ManualRegionalToneAdjustment(
                    region: try treatmentRegion(item.region),
                    exposureEV: item.exposureEV,
                    contrast: item.contrast,
                    saturation: item.saturation
                )
            )
        }
        let finalBytes = try renderedRGB(output, width: fixture.width, height: fixture.height)
        let finalExpected = try decodedRGB(fixture.windowsFinalRGBBase64, count: fixture.width * fixture.height * 3)
        let finalError = pixelError(finalBytes, finalExpected)
        print(String(format: "PT-LEARN-007 Apple/Windows regional MAE=%.6f max=%.6f", finalError.mae, finalError.maximum))
        // Regional contrast/saturation uses Apple's CIColorControls; the Windows
        // expression is intentionally only a reference approximation.  Keep the
        // actual residual visible and fail on a material platform divergence.
        XCTAssertLessThan(finalError.mae, 0.055)
        XCTAssertLessThan(finalError.maximum, 0.30)
    }

    private struct CrossPlatformFixture: Decodable {
        struct ColorContract: Decodable { let input: String; let working: String; let output: String }
        struct Regional: Decodable {
            let region: String; let exposureEV: Float; let contrast: Float; let saturation: Float
            enum CodingKeys: String, CodingKey { case region, contrast, saturation; case exposureEV = "exposure_ev" }
        }
        struct Parameters: Decodable {
            let exposureEV: Float; let masterCurve: [Float]; let rgbCurves: [[Float]]
            let rgbIntensity: Float; let hsl: [[Float]]; let tonalGrade: [[Float]]; let regional: [Regional]
            enum CodingKeys: String, CodingKey {
                case hsl, regional
                case exposureEV = "exposure_ev"; case masterCurve = "master_curve"
                case rgbCurves = "rgb_curves"; case rgbIntensity = "rgb_intensity"
                case tonalGrade = "tonal_grade"
            }
        }
        let schemaVersion: Int; let colorContract: ColorContract; let operatorOrder: [String]
        let width: Int; let height: Int; let parameters: Parameters
        let inputRGBBase64: String; let windowsGlobalRGBBase64: String; let windowsFinalRGBBase64: String
        let masksFloat32Base64: [String: String]
        enum CodingKeys: String, CodingKey {
            case width, height, parameters
            case schemaVersion = "schema_version"; case colorContract = "color_contract"
            case operatorOrder = "operator_order"; case inputRGBBase64 = "input_rgb_base64"
            case windowsGlobalRGBBase64 = "windows_global_rgb_base64"
            case windowsFinalRGBBase64 = "windows_final_rgb_base64"
            case masksFloat32Base64 = "masks_float32_base64"
        }
    }

    private func crossPlatformFixture() throws -> CrossPlatformFixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("PhotographyInverseSolver/fixtures/cross_platform_oracle_v1.json")
        return try JSONDecoder().decode(CrossPlatformFixture.self, from: Data(contentsOf: url))
    }

    private func decodedRGB(_ encoded: String, count: Int) throws -> [UInt8] {
        guard let data = Data(base64Encoded: encoded), data.count == count else { throw TestError.decoding }
        return [UInt8](data)
    }

    private func fixtureImage(_ fixture: CrossPlatformFixture) throws -> CIImage {
        let rgb = try decodedRGB(fixture.inputRGBBase64, count: fixture.width * fixture.height * 3)
        var rgba = [UInt8](); rgba.reserveCapacity(fixture.width * fixture.height * 4)
        for index in stride(from: 0, to: rgb.count, by: 3) {
            rgba.append(rgb[index]); rgba.append(rgb[index + 1]); rgba.append(rgb[index + 2]); rgba.append(255)
        }
        return CIImage(
            bitmapData: Data(rgba), bytesPerRow: fixture.width * 4,
            size: CGSize(width: fixture.width, height: fixture.height),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    private func fixtureMask(_ encoded: String, width: Int, height: Int) throws -> CIImage {
        guard let data = Data(base64Encoded: encoded), data.count == width * height * 4 else { throw TestError.decoding }
        var pixels = [UInt8](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            for index in 0..<pixels.count {
                let offset = index * 4
                let byte0 = UInt32(raw[offset])
                let byte1 = UInt32(raw[offset + 1]) << 8
                let byte2 = UInt32(raw[offset + 2]) << 16
                let byte3 = UInt32(raw[offset + 3]) << 24
                let bits = byte0 | byte1 | byte2 | byte3
                pixels[index] = UInt8((min(max(Float(bitPattern: bits), 0), 1) * 255).rounded())
            }
        }
        return CIImage(bitmapData: Data(pixels), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
    }

    private func channelCurve(_ values: [Float]) throws -> SevenPointChannelCurve {
        guard values.count == 7 else { throw TestError.decoding }
        return SevenPointChannelCurve(black: values[0], shadow: values[1], lowerMidtone: values[2], midtone: values[3], upperMidtone: values[4], highlight: values[5], white: values[6])
    }

    private func hslAdjustment(_ rows: [[Float]]) throws -> ProfessionalHSLAdjustment {
        guard rows.count == 8, rows.allSatisfy({ $0.count == 3 }) else { throw TestError.decoding }
        var result = ProfessionalHSLAdjustment.neutral; result.mathMode = .perceptualHSL
        result.redHue = rows[0][0]; result.redSaturation = rows[0][1]; result.redLuminance = rows[0][2]
        result.orangeHue = rows[1][0]; result.orangeSaturation = rows[1][1]; result.orangeLuminance = rows[1][2]
        result.yellowHue = rows[2][0]; result.yellowSaturation = rows[2][1]; result.yellowLuminance = rows[2][2]
        result.greenHue = rows[3][0]; result.greenSaturation = rows[3][1]; result.greenLuminance = rows[3][2]
        result.cyanHue = rows[4][0]; result.cyanSaturation = rows[4][1]; result.cyanLuminance = rows[4][2]
        result.blueHue = rows[5][0]; result.blueSaturation = rows[5][1]; result.blueLuminance = rows[5][2]
        result.purpleHue = rows[6][0]; result.purpleSaturation = rows[6][1]; result.purpleLuminance = rows[6][2]
        result.magentaHue = rows[7][0]; result.magentaSaturation = rows[7][1]; result.magentaLuminance = rows[7][2]
        return result.diagnosticRendererClamped()
    }

    private func tonalGrade(_ rows: [[Float]]) throws -> ProfessionalTonalColorGrade {
        guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else { throw TestError.decoding }
        func vector(_ row: [Float]) -> TonalColorVector { TonalColorVector(red: row[0], green: row[1], blue: row[2], amount: 1) }
        return ProfessionalTonalColorGrade(shadows: vector(rows[0]), midtones: vector(rows[1]), highlights: vector(rows[2]), neutralChromaProtection: 0.82, highlightNeutralProtection: 0.90)
    }

    private func treatmentRegion(_ value: String) throws -> TreatmentRegion {
        switch value { case "ground": return .ground; case "vegetation": return .vegetation; case "sky": return .sky; case "architecture": return .architecture; default: throw TestError.decoding }
    }

    private func renderedRGB(_ image: CIImage, width: Int, height: Int) throws -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh])
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var rgb = [UInt8](); rgb.reserveCapacity(width * height * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) { rgb.append(rgba[index]); rgb.append(rgba[index + 1]); rgb.append(rgba[index + 2]) }
        return rgb
    }

    private func pixelError(_ lhs: [UInt8], _ rhs: [UInt8]) -> (mae: Double, maximum: Double) {
        let errors = zip(lhs, rhs).map { Double(abs(Int($0.0) - Int($0.1))) / 255 }
        return (errors.reduce(0, +) / Double(errors.count), errors.max() ?? 0)
    }

    private enum TestError: Error { case encoding, decoding }
}
