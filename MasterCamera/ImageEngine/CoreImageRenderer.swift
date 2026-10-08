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
        let exposed = applyExposure(to: locallyAdjusted, recipe: recipe)
        let recovered = applyHighlightShadow(to: exposed, recipe: recipe)
        let colored = applyColorControls(to: recovered, recipe: recipe)
        let vibrant = applyVibrance(to: colored, recipe: recipe)
        let denoised = applyNoiseReduction(to: vibrant, recipe: recipe)
        let sharpened = applySharpening(to: denoised, recipe: recipe)

        guard let jpegData = context.jpegRepresentation(
            of: sharpened,
            colorSpace: outputColorSpace,
            options: [:]
        ) else {
            throw ImageRenderingError.renderFailed
        }

        return jpegData
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

    private func applyVibrance(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = recipe.vibrance
        return filter.outputImage ?? image
    }

    private func applyNoiseReduction(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = recipe.noiseReductionAmount
        filter.sharpness = 0.42
        return filter.outputImage ?? image
    }

    private func applySharpening(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = recipe.sharpeningAmount
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

