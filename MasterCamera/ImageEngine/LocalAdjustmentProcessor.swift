import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

final class LocalAdjustmentProcessor {
    func applyLocalizedRelighting(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        let subjectAdjusted = applySubjectRelighting(
            to: image,
            analysis: analysis,
            recipe: recipe
        )

        return applyFaceRelighting(
            to: subjectAdjusted,
            analysis: analysis,
            recipe: recipe
        )
    }

    private func applySubjectRelighting(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard
            recipe.subjectExposureEV > 0,
            let analysis,
            let photoMask = analysis.personMask ?? analysis.salientSubjectMask,
            let mask = makePixelMask(from: photoMask, extent: image.extent)
        else {
            return image
        }

        return blendExposure(
            image: image,
            exposureEV: recipe.subjectExposureEV,
            mask: mask
        )
    }

    private func applyFaceRelighting(
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

        guard let mask = makeFaceMask(for: faceRegions, extent: image.extent) else {
            return image
        }

        return blendExposure(
            image: image,
            exposureEV: recipe.faceExposureEV,
            mask: mask
        )
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

    private func makePixelMask(
        from photoMask: NormalizedPhotoMask,
        extent: CGRect
    ) -> CIImage? {
        guard photoMask.isValid else { return nil }

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
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))

        guard let blur = CIFilter(name: "CIGaussianBlur") else {
            return scaled.cropped(to: extent)
        }

        let radius = min(max(extent.width, extent.height) * 0.006, 18)
        blur.setValue(scaled.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        return blur.outputImage?.cropped(to: extent) ?? scaled.cropped(to: extent)
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

    private func blendExposure(
        image: CIImage,
        exposureEV: Float,
        mask: CIImage
    ) -> CIImage {
        let lifted = applyExposure(to: image, ev: exposureEV)
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            return image
        }

        blend.setValue(lifted, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }
}

