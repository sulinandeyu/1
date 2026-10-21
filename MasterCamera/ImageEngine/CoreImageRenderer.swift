import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation
import UIKit

final class CoreImageRenderer {
    private let context = CIContext()
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let localAdjustmentProcessor = LocalAdjustmentProcessor()

    func renderOriginalPreview(from data: Data) -> UIImage? {
        guard
            let image = CIImage(data: data),
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
        guard let inputImage = CIImage(data: data) else {
            throw ImageRenderingError.invalidImageData
        }

        let locallyAdjusted = localAdjustmentProcessor.applyFaceRelighting(
            to: inputImage,
            analysis: analysis,
            recipe: recipe
        )
        let whiteBalanced = applyWhiteBalance(to: locallyAdjusted, recipe: recipe)
        let exposed = applyExposure(to: whiteBalanced, recipe: recipe)
        let recovered = applyHighlightShadow(to: exposed, recipe: recipe)
        let curved = applyToneCurve(to: recovered, recipe: recipe)
        let colored = applyColorControls(to: curved, recipe: recipe)
        let vibrant = applyVibrance(to: colored, recipe: recipe)
        let denoised = applyNoiseReduction(to: vibrant, recipe: recipe)
        let sharpened = applySharpening(to: denoised, recipe: recipe)
        let finished = applyVignette(to: sharpened, recipe: recipe)

        guard let jpegData = context.jpegRepresentation(
            of: finished,
            colorSpace: outputColorSpace,
            options: [:]
        ) else {
            throw ImageRenderingError.renderFailed
        }

        return jpegData
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

        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0.0, y: 0.012 * amount)
        filter.point1 = CGPoint(x: 0.25, y: 0.25 - (0.014 * amount))
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: 0.75 + (0.02 * amount))
        filter.point4 = CGPoint(x: 1.0, y: 1.0 - (0.014 * amount))
        return filter.outputImage ?? image
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

