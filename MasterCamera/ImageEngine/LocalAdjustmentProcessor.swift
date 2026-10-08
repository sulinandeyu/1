import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

final class LocalAdjustmentProcessor {
    func applyFaceRelighting(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard
            recipe.faceExposureEV > 0,
            let faceRegions = analysis?.faceRegions,
            !faceRegions.isEmpty
        else {
            return image
        }

        let lifted = applyExposure(to: image, ev: recipe.faceExposureEV)
        guard let mask = makeFaceMask(for: faceRegions, extent: image.extent) else {
            return image
        }

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            return image
        }

        blend.setValue(lifted, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)

        return blend.outputImage?.cropped(to: image.extent) ?? image
    }

    private func applyExposure(to image: CIImage, ev: Float) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = ev
        return filter.outputImage ?? image
    }

    private func makeFaceMask(
        for regions: [NormalizedPhotoRegion],
        extent: CGRect
    ) -> CIImage? {
        var combinedMask: CIImage?

        for region in regions {
            let mask = makeMask(for: region, extent: extent)

            if let existingMask = combinedMask {
                combinedMask = composite(mask, over: existingMask)
            } else {
                combinedMask = mask
            }
        }

        return combinedMask?.cropped(to: extent)
    }

    private func makeMask(
        for region: NormalizedPhotoRegion,
        extent: CGRect
    ) -> CIImage {
        let clearImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        let center = CGPoint(
            x: extent.minX + CGFloat(region.centerX) * extent.width,
            y: extent.minY + CGFloat(region.centerY) * extent.height
        )
        let radius = CGFloat(region.longestSide) * max(extent.width, extent.height) * 0.82

        guard let gradient = CIFilter(name: "CIRadialGradient") else {
            return clearImage.cropped(to: extent)
        }

        gradient.setValue(CIVector(cgPoint: center), forKey: "inputCenter")
        gradient.setValue(radius * 0.28, forKey: "inputRadius0")
        gradient.setValue(max(radius, 1), forKey: "inputRadius1")
        gradient.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0.72), forKey: "inputColor0")
        gradient.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")

        return gradient.outputImage?.cropped(to: extent) ?? clearImage.cropped(to: extent)
    }

    private func composite(_ foreground: CIImage, over background: CIImage) -> CIImage {
        guard let compositing = CIFilter(name: "CISourceOverCompositing") else {
            return foreground
        }

        compositing.setValue(foreground, forKey: kCIInputImageKey)
        compositing.setValue(background, forKey: kCIInputBackgroundImageKey)
        return compositing.outputImage ?? foreground
    }
}

