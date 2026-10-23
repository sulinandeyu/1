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
            return [0.008, 0.075, 0.215, 0.5, 0.73, 0.9, 0.98]
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

/// 以连续色相权重执行真正的分区 HSL 调整，避免用全局饱和度冒充调色。
final class ProfessionalHSLProcessor {
    private let dimension = 32

    func apply(to image: CIImage, adjustment: ProfessionalHSLAdjustment) -> CIImage {
        guard adjustment != .neutral else { return image }
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)
        let denominator = Float(dimension - 1)
        for blueIndex in 0..<dimension {
            for greenIndex in 0..<dimension {
                for redIndex in 0..<dimension {
                    let rgb = SIMD3<Float>(
                        Float(redIndex) / denominator,
                        Float(greenIndex) / denominator,
                        Float(blueIndex) / denominator
                    )
                    var hsv = rgbToHSV(rgb)
                    let orange = hueWeight(hsv.x, center: 0.075, width: 0.095)
                    let yellow = hueWeight(hsv.x, center: 0.155, width: 0.09)
                    let green = hueWeight(hsv.x, center: 0.33, width: 0.13)
                    let cyan = hueWeight(hsv.x, center: 0.50, width: 0.10)
                    let blue = hueWeight(hsv.x, center: 0.64, width: 0.13)
                    let chromaGuard = min(1, hsv.y * 3.2)
                    let saturationDelta = (
                        orange * adjustment.orangeSaturation +
                        yellow * adjustment.yellowSaturation +
                        green * adjustment.greenSaturation +
                        cyan * adjustment.cyanSaturation +
                        blue * adjustment.blueSaturation
                    ) * chromaGuard
                    let luminanceDelta = (
                        orange * adjustment.orangeLuminance +
                        yellow * adjustment.yellowLuminance +
                        green * adjustment.greenLuminance +
                        cyan * adjustment.cyanLuminance +
                        blue * adjustment.blueLuminance
                    ) * chromaGuard
                    hsv.y = clamp(hsv.y * (1 + saturationDelta))
                    hsv.z = clamp(hsv.z + luminanceDelta)
                    let output = hsvToRGB(hsv)
                    cube.append(contentsOf: [output.x, output.y, output.z, 1])
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data
        ]).cropped(to: image.extent)
    }

    private func hueWeight(_ hue: Float, center: Float, width: Float) -> Float {
        let direct = abs(hue - center)
        let distance = min(direct, 1 - direct)
        let normalized = max(0, 1 - distance / width)
        return normalized * normalized * (3 - 2 * normalized)
    }

    private func rgbToHSV(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let maximum = max(rgb.x, rgb.y, rgb.z)
        let minimum = min(rgb.x, rgb.y, rgb.z)
        let delta = maximum - minimum
        var hue: Float = 0
        if delta > 0.0001 {
            if maximum == rgb.x { hue = ((rgb.y - rgb.z) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == rgb.y { hue = ((rgb.z - rgb.x) / delta) + 2 }
            else { hue = ((rgb.x - rgb.y) / delta) + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return SIMD3(hue, maximum > 0 ? delta / maximum : 0, maximum)
    }

    private func hsvToRGB(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let sector = hsv.x * 6
        let chroma = hsv.z * hsv.y
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = hsv.z - chroma
        let value: SIMD3<Float>
        switch Int(floor(sector)) % 6 {
        case 0: value = SIMD3(chroma, x, 0)
        case 1: value = SIMD3(x, chroma, 0)
        case 2: value = SIMD3(0, chroma, x)
        case 3: value = SIMD3(0, x, chroma)
        case 4: value = SIMD3(x, 0, chroma)
        default: value = SIMD3(chroma, 0, x)
        }
        return SIMD3(clamp(value.x + m), clamp(value.y + m), clamp(value.z + m))
    }

    private func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }
}

/// 以连续亮度蒙版分别处理可恢复阴影和高光，避免全局 HDR 把黑色抬灰或压暗主体。
final class LuminanceZoneProcessor {
    func apply(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let strength = recipe.luminanceMaskStrength
        guard strength > 0.001 else { return image }
        let luminance = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        var output = image
        if recipe.shadowZoneExposureEV > 0.001 {
            let inverted = luminance.applyingFilter("CIColorInvert")
            let shadowMask = inverted.applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": 2.35
            ]).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(strength), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(strength), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(strength), w: 0)
            ])
            let lifted = output.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: recipe.shadowZoneExposureEV
            ])
            output = blend(lifted, over: output, mask: shadowMask)
        }
        if recipe.highlightZoneExposureEV < -0.001 {
            let highlightMask = luminance.applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": 3.0
            ]).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(strength), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(strength), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(strength), w: 0)
            ])
            let protected = output.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: recipe.highlightZoneExposureEV
            ])
            output = blend(protected, over: output, mask: highlightMask)
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
                    "inputBiasVector": CIVector(x: -0.045 * amount, y: 0.008 * amount, z: 0.065 * amount, w: 0)
            ])
            output = blend(cool, over: output, mask: shadowMask)
        }
        if recipe.midtoneWarmAmount > 0.001 {
            let amount = CGFloat(intensity * recipe.midtoneWarmAmount)
            let warm = output.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: 0.06 * amount, y: 0.012 * amount, z: -0.045 * amount, w: 0)
            ])
            output = blend(warm, over: output, mask: midtoneMask)
        }
        if recipe.highlightWarmAmount > 0.001 {
            let amount = CGFloat(intensity * recipe.highlightWarmAmount)
            let warm = output.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: 0.07 * amount, y: 0.018 * amount, z: -0.05 * amount, w: 0)
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

        let highlightMask = makeSmoothHighlightMask(
            from: image,
            threshold: recipe.highlightGlowThreshold
        )
        let black = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ).cropped(to: image.extent)
        let isolatedHighlights = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: black,
            kCIInputMaskImageKey: highlightMask
        ]).cropped(to: image.extent)
        var output = image

        if recipe.bloomIntensity > 0.001 {
            let radius = min(max(image.extent.width, image.extent.height) * 0.0018, 9)
            let bloom = isolatedHighlights
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: image.extent)
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
            let radius = min(max(image.extent.width, image.extent.height) * 0.001, 5)
            let amount = CGFloat(recipe.halationIntensity)
            let halation = isolatedHighlights
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: image.extent)
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

    private func makeSmoothHighlightMask(
        from image: CIImage,
        threshold: Float
    ) -> CIImage {
        let grayscale = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        let transitionWidth: CGFloat = 0.08
        let scale = 1 / transitionWidth
        let bias = -CGFloat(threshold) * scale
        return grayscale
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.82])
            .cropped(to: image.extent)
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
