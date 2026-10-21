import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class CoreImageRenderer {
    private let context = CIContext(options: [
        .cacheIntermediates: true,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    ])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let localAdjustmentProcessor = LocalAdjustmentProcessor()
    private let skyAdjustmentProcessor = SkyAdjustmentProcessor()
    private let skinTextureProtectionProcessor = SkinTextureProtectionProcessor()

    func renderOriginalPreview(from data: Data) -> UIImage? {
        guard
            let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
            let cgImage = context.createCGImage(image, from: image.extent)
        else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    func renderAutomaticEdit(
        from data: Data,
        recipe: AutomaticEditingRecipe = .naturalEnhancement,
        analysis: PhotoAnalysis? = nil
    ) throws -> Data {
        guard let inputImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw ImageRenderingError.invalidImageData
        }

        let exposed = applyExposure(to: inputImage, recipe: recipe)
        let recovered = applyHighlightShadow(to: exposed, recipe: recipe)
        let curved = applyToneCurve(to: recovered, recipe: recipe)
        let whiteBalanced = applyWhiteBalance(to: curved, recipe: recipe)
        let colored = applyColorControls(to: whiteBalanced, recipe: recipe)
        let vibrant = applyVibrance(to: colored, recipe: recipe)
        let graded = applyColorGrading(to: vibrant, recipe: recipe)
        let locallyAdjusted = localAdjustmentProcessor.applyLocalizedRelighting(
            to: graded,
            analysis: analysis,
            recipe: recipe
        )
        let skyAdjusted = skyAdjustmentProcessor.applySkyTreatment(
            to: locallyAdjusted,
            analysis: analysis,
            recipe: recipe
        )
        let denoised = applyNoiseReduction(to: skyAdjusted, recipe: recipe)
        let sharpened = applySharpening(to: denoised, recipe: recipe)
        let textureProtected = skinTextureProtectionProcessor.protectTexture(
            processedImage: sharpened,
            sourceImage: skyAdjusted,
            analysis: analysis,
            amount: recipe.skinTextureProtection
        )
        let vignetted = applyVignette(to: textureProtected, recipe: recipe)
        let finished = applyFilmGrain(to: vignetted, recipe: recipe)

        let modules = executedModules(for: recipe, analysis: analysis)
        AppLogger.imageEngine.info(
            "执行像素模块：\(modules.joined(separator: " → "))；输出范围 \(Int(finished.extent.width))×\(Int(finished.extent.height))"
        )

        guard let renderedJPEG = context.jpegRepresentation(
            of: finished,
            colorSpace: outputColorSpace,
            options: [.lossyCompressionQuality: 0.95]
        ) else {
            throw ImageRenderingError.renderFailed
        }
        let jpegData = metadataPreservingJPEG(
            renderedData: renderedJPEG,
            originalData: data
        ) ?? renderedJPEG

        AppLogger.imageEngine.info(
            "完整分辨率 JPEG 渲染完成：\(jpegData.count) bytes，sRGB"
        )

        return jpegData
    }

    private func metadataPreservingJPEG(
        renderedData: Data,
        originalData: Data
    ) -> Data? {
        guard
            let originalSource = CGImageSourceCreateWithData(originalData as CFData, nil),
            let renderedSource = CGImageSourceCreateWithData(renderedData as CFData, nil),
            let originalProperties = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil)
                as? [CFString: Any]
        else {
            return nil
        }

        var properties = originalProperties
        properties[kCGImagePropertyOrientation] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImageFromSource(
            destination,
            renderedSource,
            0,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func executedModules(
        for recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?
    ) -> [String] {
        var modules = ["方向/色彩空间", "曝光", "高光阴影"]
        if recipe.toneCurveAmount > 0.001 { modules.append("\(recipe.toneCurveStyle.rawValue)曲线") }
        if abs(recipe.temperatureShift) > 0.5 || abs(recipe.tintShift) > 0.01 { modules.append("白平衡") }
        modules.append("色彩控制")
        if recipe.vibrance > 0.001 { modules.append("自然饱和度") }
        if recipe.colorGradeIntensity > 0.001 { modules.append("分区色彩分级") }
        if recipe.subjectExposureEV > 0.001 || recipe.faceExposureEV > 0.001 { modules.append("主体/人脸补光") }
        if analysis?.skyMask != nil,
           recipe.skyExposureEV < -0.001 || recipe.skyHighlightAmount < 0.999 {
            modules.append("天空保护")
        }
        if recipe.noiseReductionAmount > 0.001 { modules.append("降噪") }
        if recipe.sharpeningAmount > 0.001 { modules.append("亮度锐化") }
        if recipe.skinTextureProtection > 0.001 { modules.append("肤质保护") }
        if recipe.vignetteIntensity > 0.001 { modules.append("暗角") }
        if recipe.grainAmount > 0.001 { modules.append("胶片颗粒") }
        return modules
    }

    private func applyWhiteBalance(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard abs(recipe.temperatureShift) > 0.5 || abs(recipe.tintShift) > 0.01 else {
            return image
        }

        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(
            x: CGFloat(6500 + recipe.temperatureShift),
            y: CGFloat(recipe.tintShift)
        )
        return filter.outputImage ?? image
    }

    private func applyExposure(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = recipe.exposureEV
        return filter.outputImage ?? image
    }

    private func applyHighlightShadow(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        filter.highlightAmount = recipe.highlightAmount
        filter.shadowAmount = recipe.shadowAmount
        return filter.outputImage ?? image
    }

    private func applyColorControls(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = recipe.brightness
        filter.contrast = recipe.contrast
        filter.saturation = recipe.saturation
        return filter.outputImage ?? image
    }

    private func applyToneCurve(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let amount = CGFloat(recipe.toneCurveAmount)
        guard amount > 0.001 else { return image }

        let targetPoints: [CGPoint]
        switch recipe.toneCurveStyle {
        case .neutral:
            targetPoints = [
                CGPoint(x: 0, y: 0.012), CGPoint(x: 0.25, y: 0.23),
                CGPoint(x: 0.5, y: 0.515), CGPoint(x: 0.75, y: 0.78),
                CGPoint(x: 1, y: 0.985)
            ]
        case .portrait:
            targetPoints = [
                CGPoint(x: 0, y: 0.018), CGPoint(x: 0.25, y: 0.265),
                CGPoint(x: 0.5, y: 0.535), CGPoint(x: 0.75, y: 0.77),
                CGPoint(x: 1, y: 0.975)
            ]
        case .landscape:
            targetPoints = [
                CGPoint(x: 0, y: 0.006), CGPoint(x: 0.25, y: 0.215),
                CGPoint(x: 0.5, y: 0.515), CGPoint(x: 0.75, y: 0.805),
                CGPoint(x: 1, y: 0.985)
            ]
        case .cinematic:
            targetPoints = [
                CGPoint(x: 0, y: 0.024), CGPoint(x: 0.25, y: 0.225),
                CGPoint(x: 0.5, y: 0.505), CGPoint(x: 0.75, y: 0.79),
                CGPoint(x: 1, y: 0.965)
            ]
        case .softHighlights:
            targetPoints = [
                CGPoint(x: 0, y: 0.012), CGPoint(x: 0.25, y: 0.255),
                CGPoint(x: 0.5, y: 0.525), CGPoint(x: 0.75, y: 0.765),
                CGPoint(x: 1, y: 0.955)
            ]
        }

        let identityPoints = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25),
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.75),
            CGPoint(x: 1, y: 1)
        ]
        let points = zip(identityPoints, targetPoints).map { identity, target in
            CGPoint(
                x: identity.x,
                y: identity.y + ((target.y - identity.y) * amount)
            )
        }

        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = points[0]
        filter.point1 = points[1]
        filter.point2 = points[2]
        filter.point3 = points[3]
        filter.point4 = points[4]
        return filter.outputImage ?? image
    }

    private func applyColorGrading(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let intensity = recipe.colorGradeIntensity
        guard intensity > 0.001 else { return image }

        let grayscale = image.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0.0]
        )
        let highlightMask = grayscale.applyingFilter(
            "CIGammaAdjust",
            parameters: ["inputPower": 2.2]
        )
        let shadowMask = grayscale
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.0])

        var output = image
        if recipe.shadowCoolAmount > 0.001 {
            let strength = CGFloat(intensity * recipe.shadowCoolAmount)
            let cooled = image.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(
                    x: -0.018 * strength,
                    y: 0.004 * strength,
                    z: 0.026 * strength,
                    w: 0
                )
            ])
            output = cooled.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: shadowMask
            ])
        }

        if recipe.highlightWarmAmount > 0.001 {
            let strength = CGFloat(intensity * recipe.highlightWarmAmount)
            let warmed = output.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(
                    x: 0.025 * strength,
                    y: 0.008 * strength,
                    z: -0.018 * strength,
                    w: 0
                )
            ])
            output = warmed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: highlightMask
            ])
        }

        return output.cropped(to: image.extent)
    }

    private func applyVibrance(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = recipe.vibrance
        return filter.outputImage ?? image
    }

    private func applyNoiseReduction(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard recipe.noiseReductionAmount > 0.001 else { return image }
        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = recipe.noiseReductionAmount
        filter.sharpness = 0.42
        return filter.outputImage ?? image
    }

    private func applySharpening(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard recipe.sharpeningAmount > 0.001 else { return image }
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = recipe.sharpeningAmount
        return filter.outputImage ?? image
    }

    private func applyVignette(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard recipe.vignetteIntensity > 0.001 else { return image }
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = recipe.vignetteIntensity
        filter.radius = Float(min(image.extent.width, image.extent.height) * 0.72)
        return filter.outputImage ?? image
    }

    private func applyFilmGrain(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard
            recipe.grainAmount > 0.001,
            let generatedNoise = CIFilter.randomGenerator().outputImage
        else {
            return image
        }

        let noise = generatedNoise
            .cropped(to: image.extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 0.55
            ])
        let textured = noise.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: textured,
            kCIInputTimeKey: recipe.grainAmount
        ]).cropped(to: image.extent)
    }
}

enum ImageRenderingError: LocalizedError {
    case invalidImageData
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法加载拍摄的图片数据。"
        case .renderFailed:
            return "无法渲染 AI 成片。"
        }
    }
}

