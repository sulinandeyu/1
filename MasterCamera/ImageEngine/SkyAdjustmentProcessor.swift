import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

final class SkyAdjustmentProcessor {
    func applySkyTreatment(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard
            let skyMask = analysis?.skyMask,
            skyMask.isValid,
            abs(recipe.skyExposureEV) > 0.001
                || recipe.skyHighlightAmount < 0.999
                || abs(recipe.skySaturation - 1.0) > 0.001,
            let mask = makeMask(from: skyMask, extent: image.extent)
        else {
            return image
        }

        let exposed = applyExposure(to: image, amount: recipe.skyExposureEV)
        let recovered = applyHighlightRecovery(
            to: exposed,
            amount: recipe.skyHighlightAmount
        )
        let colored = applySaturation(
            to: recovered,
            amount: recipe.skySaturation
        )

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            return image
        }
        blend.setValue(colored, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }

    private func applyExposure(to image: CIImage, amount: Float) -> CIImage {
        guard abs(amount) > 0.001 else { return image }
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = amount
        return filter.outputImage ?? image
    }

    private func applyHighlightRecovery(to image: CIImage, amount: Float) -> CIImage {
        guard amount < 0.999 else { return image }
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        filter.highlightAmount = amount
        filter.shadowAmount = 0
        return filter.outputImage ?? image
    }

    private func applySaturation(to image: CIImage, amount: Float) -> CIImage {
        guard abs(amount - 1.0) > 0.001 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = amount
        filter.brightness = 0
        filter.contrast = 1
        return filter.outputImage ?? image
    }

    private func makeMask(
        from photoMask: NormalizedPhotoMask,
        extent: CGRect
    ) -> CIImage? {
        let maskImage = CIImage(
            bitmapData: photoMask.pixels,
            bytesPerRow: photoMask.width,
            size: CGSize(width: photoMask.width, height: photoMask.height),
            format: .L8,
            colorSpace: nil
        )
        let scaleX = extent.width / CGFloat(photoMask.width)
        let scaleY = extent.height / CGFloat(photoMask.height)
        let scaled = maskImage
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(
                by: CGAffineTransform(
                    translationX: extent.minX,
                    y: extent.minY
                )
            )

        guard let blur = CIFilter(name: "CIGaussianBlur") else {
            return scaled.cropped(to: extent)
        }
        let radius = min(max(extent.width, extent.height) * 0.004, 14)
        blur.setValue(scaled.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        return blur.outputImage?.cropped(to: extent) ?? scaled.cropped(to: extent)
    }
}
