import CoreGraphics
import CoreImage
import XCTest
@testable import MasterCameraDecisionCore

/// Apple Core Image pixel-contract tests. These execute through `swift test` on
/// the macOS runner; they are not iPhone or photographic-aesthetic acceptance.
final class CinematicRenderingPixelTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func testExistingProductionRecipeLeavesTask2AControlsNeutral() {
        XCTAssertTrue(AutomaticEditingRecipe.naturalEnhancement.rgbCurves.isIdentity)
        XCTAssertTrue(AutomaticEditingRecipe.naturalEnhancement.tonalColorGrade.isNeutral)
        XCTAssertTrue(AutomaticEditingRecipe.safeFallback.rgbCurves.isIdentity)
        XCTAssertTrue(AutomaticEditingRecipe.safeFallback.tonalColorGrade.isNeutral)
    }

    func testNeutralProfessionalOperatorsPreservePixels() throws {
        let source = colorPatch(red: 0.42, green: 0.36, blue: 0.29)
        let rgb = ProfessionalRGBCurveProcessor().apply(to: source, curves: .identity)
        let hsl = ProfessionalHSLProcessor().apply(to: rgb, adjustment: .neutral)
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.tonalColorGrade = .neutral
        let graded = CinematicColorGradingEngine().apply(to: hsl, recipe: recipe)
        assertPixel(try pixel(source), equals: try pixel(graded), tolerance: 1.0 / 255.0)
    }

    func testPerceptualHSLNeutralControlsProtectWhiteGrayAndSkin() throws {
        var adjustment = ProfessionalHSLAdjustment.neutral
        adjustment.mathMode = .perceptualHSL
        let processor = ProfessionalHSLProcessor()
        let samples: [(CGFloat, CGFloat, CGFloat)] = [
            (0.96, 0.96, 0.96),
            (0.48, 0.48, 0.48),
            (0.70, 0.44, 0.34)
        ]
        for sample in samples {
            let source = colorPatch(red: sample.0, green: sample.1, blue: sample.2)
            assertPixel(
                try pixel(processor.apply(to: source, adjustment: adjustment)),
                equals: try pixel(source),
                tolerance: 2.0 / 255.0
            )
        }
    }

    func testRedCurveMovesRedChannelWithoutReversingGradient() throws {
        let source = horizontalGrayGradient(width: 64)
        let curves = ProfessionalRGBCurves(
            red: SevenPointChannelCurve(
                black: 0, shadow: 0.075, lowerMidtone: 0.205,
                midtone: 0.56, upperMidtone: 0.75,
                highlight: 0.91, white: 1
            ),
            intensity: 1
        )
        let output = ProfessionalRGBCurveProcessor().apply(to: source, curves: curves)
        let inputSamples = try pixels(source, width: 64)
        let samples = try pixels(output, width: 64)
        for index in 1..<samples.count {
            XCTAssertGreaterThanOrEqual(samples[index].0 + 1, samples[index - 1].0)
            XCTAssertLessThanOrEqual(abs(samples[index].1 - inputSamples[index].1), 2)
            XCTAssertLessThanOrEqual(abs(samples[index].2 - inputSamples[index].2), 2)
        }
        for index in [5, 13, 24, 40, 55, 61] {
            let input = Float(inputSamples[index].0) / 255
            let expected = piecewiseLinear(
                input,
                inputs: [0, 0.08, 0.22, 0.50, 0.72, 0.90, 1],
                outputs: curves.red.anchors
            )
            XCTAssertLessThanOrEqual(abs(samples[index].0 - Int(round(expected * 255))), 3)
        }
        let middle = samples[32]
        XCTAssertGreaterThan(middle.0, middle.1 + 3)
        XCTAssertLessThanOrEqual(abs(middle.1 - middle.2), 2)
    }

    func testEightHueHSLTargetsRedAndMagentaWhileProtectingNeutral() throws {
        var red = ProfessionalHSLAdjustment.neutral
        red.mathMode = .perceptualHSL
        red.redSaturation = -0.16
        var magenta = ProfessionalHSLAdjustment.neutral
        magenta.mathMode = .perceptualHSL
        magenta.magentaLuminance = 0.07
        let processor = ProfessionalHSLProcessor()
        let redBefore = try pixel(colorPatch(red: 0.80, green: 0.12, blue: 0.10))
        let redAfter = try pixel(processor.apply(
            to: colorPatch(red: 0.80, green: 0.12, blue: 0.10), adjustment: red
        ))
        XCTAssertLessThan(channelSpread(redAfter), channelSpread(redBefore))
        let magentaBefore = try pixel(colorPatch(red: 0.68, green: 0.10, blue: 0.52))
        let magentaAfter = try pixel(processor.apply(
            to: colorPatch(red: 0.68, green: 0.10, blue: 0.52), adjustment: magenta
        ))
        XCTAssertGreaterThan(luminance(magentaAfter), luminance(magentaBefore))
        let neutral = colorPatch(red: 0.48, green: 0.48, blue: 0.48)
        assertPixel(
            try pixel(neutral),
            equals: try pixel(processor.apply(to: neutral, adjustment: red)),
            tolerance: 2.0 / 255.0
        )
    }

    func testEightHueLightnessUsesHSLWithoutUnexpectedHueOrSaturationShift() throws {
        let colors: [(WritableKeyPath<ProfessionalHSLAdjustment, Float>, (CGFloat, CGFloat, CGFloat))] = [
            (\.redLuminance, (0.78, 0.18, 0.16)),
            (\.orangeLuminance, (0.78, 0.38, 0.12)),
            (\.yellowLuminance, (0.72, 0.66, 0.12)),
            (\.greenLuminance, (0.18, 0.66, 0.20)),
            (\.cyanLuminance, (0.12, 0.62, 0.66)),
            (\.blueLuminance, (0.14, 0.28, 0.72)),
            (\.purpleLuminance, (0.48, 0.18, 0.68)),
            (\.magentaLuminance, (0.70, 0.16, 0.58))
        ]
        let processor = ProfessionalHSLProcessor()
        for (keyPath, color) in colors {
            var adjustment = ProfessionalHSLAdjustment.neutral
            adjustment.mathMode = .perceptualHSL
            adjustment[keyPath: keyPath] = 0.05
            let before = try pixel(colorPatch(red: color.0, green: color.1, blue: color.2))
            let after = try pixel(processor.apply(
                to: colorPatch(red: color.0, green: color.1, blue: color.2),
                adjustment: adjustment
            ))
            let beforeHSL = rgb8ToHSL(before)
            let afterHSL = rgb8ToHSL(after)
            XCTAssertGreaterThan(afterHSL.z, beforeHSL.z)
            XCTAssertLessThan(circularHueDistance(afterHSL.x, beforeHSL.x), 0.03)
            XCTAssertLessThan(abs(afterHSL.y - beforeHSL.y), 0.07)
        }

        var skinLightness = ProfessionalHSLAdjustment.neutral
        skinLightness.mathMode = .perceptualHSL
        skinLightness.orangeLuminance = 0.04
        let skinBefore = try pixel(colorPatch(red: 0.70, green: 0.44, blue: 0.34))
        let skinAfter = try pixel(ProfessionalHSLProcessor().apply(
            to: colorPatch(red: 0.70, green: 0.44, blue: 0.34),
            adjustment: skinLightness
        ))
        XCTAssertLessThan(circularHueDistance(rgb8ToHSL(skinAfter).x, rgb8ToHSL(skinBefore).x), 0.025)
        XCTAssertLessThan(abs(rgb8ToHSL(skinAfter).y - rgb8ToHSL(skinBefore).y), 0.06)
    }

    func testTask2AColorCubesPreserveExtendedLinearHighlights() throws {
        let source = extendedLinearPatch(red: 1.30, green: 0.42, blue: 0.20)
        let curves = ProfessionalRGBCurves(
            red: SevenPointChannelCurve(midtone: 0.54),
            intensity: 1
        )
        var hsl = ProfessionalHSLAdjustment.neutral
        hsl.mathMode = .perceptualHSL
        hsl.orangeSaturation = 0.05
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.tonalColorGrade = ProfessionalTonalColorGrade(
            shadows: TonalColorVector(red: -0.02, blue: 0.03, amount: 0.4)
        )
        let curved = ProfessionalRGBCurveProcessor().apply(to: source, curves: curves)
        let adjusted = ProfessionalHSLProcessor().apply(to: curved, adjustment: hsl)
        let graded = CinematicColorGradingEngine().apply(to: adjusted, recipe: recipe)
        let result = try linearPixel(graded)
        XCTAssertGreaterThan(result.x, 1.20, "super-white residual must survive all Task 2-A cubes")
        XCTAssertTrue(result.x.isFinite && result.y.isFinite && result.z.isFinite)
    }

    func testRGBColorCubeGradientHasNoUnexpectedSteps() throws {
        let source = horizontalGrayGradient(width: 1024)
        let curves = ProfessionalRGBCurves(
            red: SevenPointChannelCurve(
                black: 0, shadow: 0.075, lowerMidtone: 0.21,
                midtone: 0.54, upperMidtone: 0.75, highlight: 0.91, white: 1
            ),
            intensity: 0.8
        )
        let values = try pixels(
            ProfessionalRGBCurveProcessor().apply(to: source, curves: curves),
            width: 1024
        )
        for index in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[index].0 + 1, values[index - 1].0)
            XCTAssertLessThanOrEqual(values[index].0 - values[index - 1].0, 3)
        }
    }

    func testCoolShadowsAndWarmHighlightsCoexist() throws {
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.tonalColorGrade = ProfessionalTonalColorGrade(
            shadows: TonalColorVector(red: -0.04, green: 0, blue: 0.05, amount: 0.8),
            highlights: TonalColorVector(red: 0.04, green: 0.01, blue: -0.03, amount: 0.5),
            neutralChromaProtection: 0.25,
            highlightNeutralProtection: 0.40
        )
        let engine = CinematicColorGradingEngine()
        let dark = try pixel(engine.apply(
            to: colorPatch(red: 0.12, green: 0.10, blue: 0.09), recipe: recipe
        ))
        let bright = try pixel(engine.apply(
            to: colorPatch(red: 0.84, green: 0.76, blue: 0.66), recipe: recipe
        ))
        XCTAssertGreaterThan(dark.2, dark.0)
        XCTAssertGreaterThan(bright.0, bright.2)
    }

    func testToneMapChangesBlackAndHighlightZonesInExpectedDirection() throws {
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        recipe.cinematicIntensity = .dramatic
        recipe.shadowRollOff = 0.35
        recipe.highlightRollOff = 0.50
        recipe.whitePoint = 0.94
        let engine = CinematicToneMappingEngine()
        let shadowSource = extendedLinearPatch(red: 0.08, green: 0.08, blue: 0.08)
        let shadowBefore = try linearPixel(shadowSource)
        let shadowAfter = try linearPixel(engine.apply(
            to: shadowSource, recipe: recipe
        ))
        let highlightSource = extendedLinearPatch(red: 0.92, green: 0.92, blue: 0.92)
        let highlightBefore = try linearPixel(highlightSource)
        let highlightAfter = try linearPixel(engine.apply(
            to: highlightSource, recipe: recipe
        ))
        XCTAssertGreaterThan(shadowAfter.x, shadowBefore.x + 0.0005)
        XCTAssertLessThan(highlightAfter.x, highlightBefore.x - 0.005)
    }

    func testRegionalMaskPrimarilyAffectsSelectedHalf() throws {
        let source = colorPatch(red: 0.40, green: 0.36, blue: 0.30, width: 32, height: 8)
        let mask = halfMask(width: 32, height: 8)
        let adjustment = ManualRegionalToneAdjustment(
            region: .ground,
            exposureEV: -0.35,
            luminanceLowerBound: 0,
            luminanceUpperBound: 1,
            luminanceFeather: 0.08
        )
        let output = DiagnosticRegionalToneProcessor().apply(
            to: source, semanticMask: mask, adjustment: adjustment
        )
        let before = try pixels(source, width: 32, height: 8)
        let after = try pixels(output, width: 32, height: 8)
        let selectedDelta = meanDifference(before, after, xRange: 0..<14, width: 32)
        let protectedDelta = meanDifference(before, after, xRange: 18..<32, width: 32)
        XCTAssertGreaterThan(selectedDelta, 8)
        XCTAssertLessThan(protectedDelta, 2)
    }

    private func colorPatch(
        red: CGFloat, green: CGFloat, blue: CGFloat,
        width: Int = 1, height: Int = 1
    ) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue, alpha: 1))
            .cropped(to: CGRect(
                x: 0, y: 0,
                width: CGFloat(width), height: CGFloat(height)
            ))
    }

    private func extendedLinearPatch(red: Float, green: Float, blue: Float) -> CIImage {
        let values: [Float] = [red, green, blue, 1]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: MemoryLayout<Float>.size * 4,
            size: CGSize(width: 1, height: 1),
            format: .RGBAf,
            colorSpace: linear
        )
    }

    private func horizontalGrayGradient(width: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let value = UInt8(round(Float(x) / Float(width - 1) * 255))
            bytes[x * 4] = value
            bytes[x * 4 + 1] = value
            bytes[x * 4 + 2] = value
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: width * 4,
            size: CGSize(width: CGFloat(width), height: 1), format: .RGBA8,
            colorSpace: sRGB
        )
    }

    private func halfMask(width: Int, height: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = x < width / 2 ? 255 : 0
                let offset = (y * width + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
            }
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: width * 4,
            size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBA8,
            colorSpace: sRGB
        )
    }

    private func pixel(_ image: CIImage) throws -> (Int, Int, Int, Int) {
        try pixels(image, width: 1, height: 1)[0]
    }

    private func linearPixel(_ image: CIImage) throws -> SIMD4<Float> {
        let context = CIContext(options: [
            .workingColorSpace: linear,
            .workingFormat: CIFormat.RGBAh
        ])
        var values = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &values,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: linear
        )
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    private func piecewiseLinear(_ value: Float, inputs: [Float], outputs: [Float]) -> Float {
        guard value > inputs[0] else { return outputs[0] }
        for index in 1..<inputs.count where value <= inputs[index] {
            let fraction = (value - inputs[index - 1]) / (inputs[index] - inputs[index - 1])
            return outputs[index - 1] + (outputs[index] - outputs[index - 1]) * fraction
        }
        return outputs.last ?? value
    }

    private func rgb8ToHSL(_ value: (Int, Int, Int, Int)) -> SIMD3<Double> {
        let red = Double(value.0) / 255
        let green = Double(value.1) / 255
        let blue = Double(value.2) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        var hue = 0.0
        if delta > 0.000_001 {
            if maximum == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == green { hue = ((blue - red) / delta) + 2 }
            else { hue = ((red - green) / delta) + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = delta > 0.000_001
            ? delta / max(0.000_001, 1 - abs(2 * lightness - 1))
            : 0
        return SIMD3(hue, saturation, lightness)
    }

    private func circularHueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let direct = abs(lhs - rhs)
        return min(direct, 1 - direct)
    }

    private func pixels(
        _ image: CIImage, width: Int, height: Int = 1
    ) throws -> [(Int, Int, Int, Int)] {
        let context = CIContext(options: [
            .workingColorSpace: linear,
            .workingFormat: CIFormat.RGBAh
        ])
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: width * 4,
            bounds: CGRect(
                x: 0, y: 0,
                width: CGFloat(width), height: CGFloat(height)
            ),
            format: .RGBA8, colorSpace: sRGB
        )
        var result: [(Int, Int, Int, Int)] = []
        result.reserveCapacity(width * height)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            let alpha = Int(bytes[offset + 3])
            result.append((red, green, blue, alpha))
        }
        return result
    }

    private func assertPixel(
        _ actual: (Int, Int, Int, Int),
        equals expected: (Int, Int, Int, Int),
        tolerance: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let limit = Int(ceil(tolerance * 255))
        XCTAssertLessThanOrEqual(abs(actual.0 - expected.0), limit, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.1 - expected.1), limit, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.2 - expected.2), limit, file: file, line: line)
    }

    private func luminance(_ value: (Int, Int, Int, Int)) -> Double {
        Double(value.0) * 0.2126 + Double(value.1) * 0.7152 + Double(value.2) * 0.0722
    }

    private func channelSpread(_ value: (Int, Int, Int, Int)) -> Int {
        max(value.0, value.1, value.2) - min(value.0, value.1, value.2)
    }

    private func meanDifference(
        _ lhs: [(Int, Int, Int, Int)],
        _ rhs: [(Int, Int, Int, Int)],
        xRange: Range<Int>,
        width: Int
    ) -> Double {
        var sum = 0.0
        var count = 0
        for index in lhs.indices where xRange.contains(index % width) {
            sum += Double(abs(lhs[index].0 - rhs[index].0))
            sum += Double(abs(lhs[index].1 - rhs[index].1))
            sum += Double(abs(lhs[index].2 - rhs[index].2))
            count += 3
        }
        return count > 0 ? sum / Double(count) : 0
    }
}
