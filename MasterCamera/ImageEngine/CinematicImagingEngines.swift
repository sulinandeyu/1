import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Seven-anchor, scene-selected filmic transfer curve. The lookup cube is applied to the
/// full-resolution CIImage; it is not a preview-only display effect.
final class CinematicToneMappingEngine {
    private let cubeDimension = 32

    func apply(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let strength = intensityScale(recipe.cinematicIntensity)
        guard strength > 0 else { return image }

        let inputAnchors: [Float] = [0, 0.08, 0.22, 0.5, 0.72, 0.9, 1]
        var outputAnchors = baseAnchors(for: recipe.cinematicToneStyle)
        outputAnchors[1] += recipe.shadowRollOff * 0.018
        outputAnchors[2] += recipe.lowerMidtoneLift
        outputAnchors[3] += recipe.midtoneBias
        outputAnchors[4] += recipe.upperMidtoneSeparation
        outputAnchors[5] -= recipe.highlightRollOff * 0.035
        outputAnchors[6] = min(outputAnchors[6], recipe.whitePoint)

        outputAnchors = outputAnchors.enumerated().map { index, target in
            let identity = inputAnchors[index]
            return clamp(identity + ((target - identity) * strength))
        }
        outputAnchors = enforceMonotonicCurve(outputAnchors)

        var cube = [Float]()
        cube.reserveCapacity(cubeDimension * cubeDimension * cubeDimension * 4)
        for blueIndex in 0..<cubeDimension {
            for greenIndex in 0..<cubeDimension {
                for redIndex in 0..<cubeDimension {
                    let denominator = Float(cubeDimension - 1)
                    cube.append(map(Float(redIndex) / denominator, inputs: inputAnchors, outputs: outputAnchors))
                    cube.append(map(Float(greenIndex) / denominator, inputs: inputAnchors, outputs: outputAnchors))
                    cube.append(map(Float(blueIndex) / denominator, inputs: inputAnchors, outputs: outputAnchors))
                    cube.append(1)
                }
            }
        }

        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": data
        ]).cropped(to: image.extent)
    }

    private func baseAnchors(for style: CinematicToneStyle) -> [Float] {
        switch style {
        case .natural:
            return [0.006, 0.07, 0.225, 0.51, 0.745, 0.91, 0.985]
        case .bright:
            return [0.012, 0.09, 0.25, 0.535, 0.765, 0.925, 0.992]
        case .lowKey:
            return [0.003, 0.05, 0.19, 0.475, 0.715, 0.895, 0.972]
        }
    }

    private func intensityScale(_ intensity: CinematicIntensity) -> Float {
        switch intensity {
        case .natural: return 0.62
        case .standard: return 0.84
        case .dramatic: return 1
        }
    }

    private func enforceMonotonicCurve(_ values: [Float]) -> [Float] {
        var result = values
        for index in 1..<result.count {
            result[index] = max(result[index], result[index - 1] + 0.008)
        }
        return result.map(clamp)
    }

    private func map(_ value: Float, inputs: [Float], outputs: [Float]) -> Float {
        guard value > inputs[0] else { return outputs[0] }
        for index in 1..<inputs.count where value <= inputs[index] {
            let range = inputs[index] - inputs[index - 1]
            let fraction = range > 0 ? (value - inputs[index - 1]) / range : 0
            let smoothFraction = fraction * fraction * (3 - (2 * fraction))
            return outputs[index - 1] + ((outputs[index] - outputs[index - 1]) * smoothFraction)
        }
        return outputs.last ?? value
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

/// Independently grades shadows, midtones and highlights with soft luminance masks.
final class CinematicColorGradingEngine {
    func apply(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let intensity = recipe.colorGradeIntensity
        guard intensity > 0.001 else { return image }

        let luminance = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        let shadowMask = luminance
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
        let highlightMask = luminance
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.35])
        let midtoneMask = luminance.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": CIVector(x: 0, y: 4, z: -4, w: 0),
            "inputGreenCoefficients": CIVector(x: 0, y: 4, z: -4, w: 0),
            "inputBlueCoefficients": CIVector(x: 0, y: 4, z: -4, w: 0)
        ])

        var output = image
        if recipe.shadowCoolAmount > 0.001 {
            let amount = CGFloat(intensity * recipe.shadowCoolAmount)
            let cool = output.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: -0.014 * amount, y: 0.004 * amount, z: 0.025 * amount, w: 0)
            ])
            output = blend(cool, over: output, mask: shadowMask)
        }
        if recipe.midtoneWarmAmount > 0.001 {
            let amount = CGFloat(intensity * recipe.midtoneWarmAmount)
            let warm = output.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: 0.018 * amount, y: 0.004 * amount, z: -0.013 * amount, w: 0)
            ])
            output = blend(warm, over: output, mask: midtoneMask)
        }
        if recipe.highlightWarmAmount > 0.001 {
            let amount = CGFloat(intensity * recipe.highlightWarmAmount)
            let warm = output.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: 0.022 * amount, y: 0.007 * amount, z: -0.015 * amount, w: 0)
            ])
            output = blend(warm, over: output, mask: highlightMask)
        }

        if recipe.colorContrast > 0.001 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + (recipe.colorContrast * 0.08),
                kCIInputContrastKey: 1 + (recipe.colorContrast * 0.035)
            ])
        }
        return output.cropped(to: image.extent)
    }

    private func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: background.extent)
    }
}

/// Uses an existing verified Vision mask only. Without one it leaves spatial separation off.
final class CinematicSpatialDepthProcessor {
    func apply(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard
            recipe.backgroundSeparation > 0.001,
            let maskData = analysis?.personMask ?? analysis?.salientSubjectMask,
            maskData.isValid,
            let mask = makeMask(maskData, extent: image.extent)
        else {
            return image
        }

        let amount = recipe.backgroundSeparation
        let background = image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1 - (amount * 0.18),
            kCIInputSaturationKey: 1 - (amount * 0.12),
            kCIInputBrightnessKey: -(amount * 0.025)
        ])
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }

    private func makeMask(_ mask: NormalizedPhotoMask, extent: CGRect) -> CIImage? {
        let raw = CIImage(
            bitmapData: mask.pixels,
            bytesPerRow: mask.width,
            size: CGSize(width: mask.width, height: mask.height),
            format: .L8,
            colorSpace: nil
        )
        let scaled = raw
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / CGFloat(mask.width),
                y: extent.height / CGFloat(mask.height)
            ))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: min(max(extent.width, extent.height) * 0.0045, 16)
            ])
        return scaled.cropped(to: extent)
    }
}

/// Selective lens character: highlight-only bloom, restrained warm halation, optional
/// vignette and luminance-aware monochrome grain.
final class CinematicLensCharacterProcessor {
    func apply(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        var output = applyBloomAndHalation(to: image, recipe: recipe)
        output = applyVignette(to: output, recipe: recipe)
        output = applyLuminanceAwareGrain(to: output, recipe: recipe)
        return output.cropped(to: image.extent)
    }

    private func applyBloomAndHalation(
        to image: CIImage,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard recipe.bloomIntensity > 0.001 || recipe.halationIntensity > 0.001 else {
            return image
        }

        let highlights = image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.46,
                kCIInputContrastKey: 2.8,
                kCIInputSaturationKey: 0.72
            ])
            .clampedToExtent()
        var output = image

        if recipe.bloomIntensity > 0.001 {
            let radius = min(max(image.extent.width, image.extent.height) * 0.004, 22)
            let bloom = highlights
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(recipe.bloomIntensity), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(recipe.bloomIntensity), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(recipe.bloomIntensity), w: 0)
                ])
            output = bloom.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: output
            ]).cropped(to: image.extent)
        }

        if recipe.halationIntensity > 0.001 {
            let radius = min(max(image.extent.width, image.extent.height) * 0.0022, 12)
            let amount = CGFloat(recipe.halationIntensity)
            let halation = highlights
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.0 * amount, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.32 * amount, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.12 * amount, w: 0)
                ])
            output = halation.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: output
            ]).cropped(to: image.extent)
        }
        return output
    }

    private func applyVignette(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard recipe.vignetteIntensity > 0.001 else { return image }
        return image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: recipe.vignetteIntensity,
            kCIInputRadiusKey: Float(min(image.extent.width, image.extent.height) * 0.78)
        ])
    }

    private func applyLuminanceAwareGrain(
        to image: CIImage,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard
            recipe.grainAmount > 0.001,
            let noise = CIFilter.randomGenerator().outputImage
        else {
            return image
        }

        let luminance = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let midShadowMask = luminance
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.45])
        let monochromeNoise = noise
            .cropped(to: image.extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 0.7,
                kCIInputBrightnessKey: -0.05
            ])
        let texture = monochromeNoise.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])
        let strength = recipe.grainAmount
        let mixed = image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: texture,
            kCIInputTimeKey: strength
        ])
        return mixed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: midShadowMask
        ]).cropped(to: image.extent)
    }
}
