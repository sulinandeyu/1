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
