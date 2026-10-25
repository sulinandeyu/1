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
        let regionAdjusted = applySemanticRegions(
            to: image,
            analysis: analysis,
            recipe: recipe
        )
        let subjectAdjusted = applySubjectRelighting(
            to: regionAdjusted,
            analysis: analysis,
            recipe: recipe
        )

        return applyFaceRelighting(
            to: subjectAdjusted,
            analysis: analysis,
            recipe: recipe
        )
    }

    private func applySemanticRegions(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard let analysis else { return image }
        // Region masks from a general scene model may overlap hair or skin. If a photo
        // contains a face but Vision cannot provide a reliable whole-person exclusion
        // mask, disable these local scene edits instead of risking a disguised beauty edit.
        if analysis.faceCount > 0, analysis.personMask?.isValid != true {
            return image
        }
        let facets = Set(analysis.photographyContext.sceneFacets)
        var output = image

        if !facets.isDisjoint(with: [.forest, .countryRoad, .nature]),
           isUsableRegionMask(analysis.vegetationMask),
           let mask = protectedRegionMask(from: analysis.vegetationMask, analysis: analysis, extent: image.extent) {
            let recoverableShadow = analysis.vegetationStatistics?.shadowRatio
                ?? max(0, analysis.shadowRatio - analysis.blackRatio)
            let saturationDelta = min(0.14, max(-0.10,
                (recipe.hsl.greenSaturation + recipe.hsl.yellowSaturation) * 0.85
            ))
            output = blendColorControls(
                image: output,
                saturation: 1 + saturationDelta,
                brightness: max(-0.012, min(0.028, (recipe.hsl.yellowLuminance * 0.32) + (recoverableShadow * 0.025))),
                contrast: 1 + min(0.055, recipe.localContrastAmount * 0.36),
                mask: mask
            )
        }

        if !facets.isDisjoint(with: [.water, .coast]),
           isUsableRegionMask(analysis.waterMask),
           let mask = protectedRegionMask(from: analysis.waterMask, analysis: analysis, extent: image.extent) {
            let saturationDelta = min(0.10, max(-0.10,
                (recipe.hsl.cyanSaturation + recipe.hsl.blueSaturation) * 0.78
            ))
            output = blendColorControls(
                image: output,
                saturation: 1 + saturationDelta,
                brightness: max(-0.018, min(0.018, recipe.hsl.blueLuminance * 0.3)),
                contrast: 1 + min(0.045, recipe.localContrastAmount * 0.3),
                mask: mask
            )
        }

        if !facets.isDisjoint(with: [.architecture, .city, .street, .interior, .workspace]),
           isUsableRegionMask(analysis.architectureMask),
           let mask = protectedRegionMask(from: analysis.architectureMask, analysis: analysis, extent: image.extent) {
            output = blendColorControls(
                image: output,
                saturation: 1,
                brightness: 0,
                contrast: 1 + min(0.06, recipe.localContrastAmount * 0.42),
                mask: mask
            )
        }

        if isUsableRegionMask(analysis.groundMask),
           let mask = protectedRegionMask(from: analysis.groundMask, analysis: analysis, extent: image.extent) {
            let isLandscapeGround = !facets.isDisjoint(with: [.mountain, .forest, .countryRoad, .nature])
            let groundContrast = analysis.groundStatistics?.contrastRange ?? analysis.contrastRange
            let recoverableShadow = analysis.groundStatistics?.shadowRatio
                ?? max(0, analysis.shadowRatio - analysis.blackRatio)
            let needsShadowLift = groundContrast < 0.56 && recoverableShadow > 0.2
            let exposureEV: Float = needsShadowLift
                ? min(0.09, recipe.shadowZoneExposureEV * 0.5)
                : min(0.025, recipe.shadowZoneExposureEV * 0.18)
            let contrastGain = isLandscapeGround
                ? min(0.075, recipe.localContrastAmount * 0.55)
                : min(0.04, recipe.localContrastAmount * 0.28)
            let adjusted = applyExposure(
                to: output.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1 + contrastGain
                ]),
                ev: exposureEV
            )
            output = blend(adjusted, over: output, mask: mask)
        }

        return output.cropped(to: image.extent)
    }

    func regionalExecutionDetails(
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> [String] {
        guard let analysis else { return ["区域精修：跳过（无分析结果）"] }
        let blocksSemanticRegions = analysis.faceCount > 0 && analysis.personMask?.isValid != true
        let facets = Set(analysis.photographyContext.sceneFacets)
        let semanticDetails = blocksSemanticRegions
            ? ["植被：跳过（人物保护）", "水面：跳过（人物保护）", "建筑：跳过（人物保护）", "地面/道路：跳过（人物保护）"]
            : [
                executionDetail(
                    name: "植被",
                    mask: analysis.vegetationMask,
                    sceneMatches: !facets.isDisjoint(with: [.forest, .countryRoad, .nature])
                ),
                executionDetail(
                    name: "水面",
                    mask: analysis.waterMask,
                    sceneMatches: !facets.isDisjoint(with: [.water, .coast])
                ),
                executionDetail(
                    name: "建筑",
                    mask: analysis.architectureMask,
                    sceneMatches: !facets.isDisjoint(with: [.architecture, .city, .street, .interior, .workspace])
                ),
                executionDetail(name: "地面/道路", mask: analysis.groundMask, sceneMatches: true)
            ]
        return semanticDetails + [skyExecutionDetail(analysis: analysis, recipe: recipe)]
    }

    private func executionDetail(
        name: String,
        mask: NormalizedPhotoMask?,
        sceneMatches: Bool
    ) -> String {
        guard sceneMatches else { return "\(name)：跳过（场景语义不匹配）" }
        guard let mask, mask.isValid else { return "\(name)：跳过（无有效蒙版）" }
        guard isUsableRegionMask(mask) else {
            return String(format: "%@：跳过（覆盖率 %.2f%% 不可靠）", name, mask.activeCoverage * 100)
        }
        return String(format: "%@：已执行（覆盖率 %.2f%%）", name, mask.activeCoverage * 100)
    }

    private func skyExecutionDetail(
        analysis: PhotoAnalysis,
        recipe: AutomaticEditingRecipe
    ) -> String {
        let requested = abs(recipe.skyExposureEV) > 0.001
            || recipe.skyHighlightAmount < 0.999
            || abs(recipe.skySaturation - 1) > 0.001
        guard requested else { return "天空：跳过（配方未请求天空调整）" }
        if analysis.faceCount > 0, analysis.personMask?.isValid != true {
            return "天空：跳过（人物保护缺少可靠整人物蒙版）"
        }
        return executionDetail(name: "天空", mask: analysis.skyMask, sceneMatches: true)
    }

    private func isUsableRegionMask(_ mask: NormalizedPhotoMask?) -> Bool {
        guard let mask, mask.isValid else { return false }
        return mask.activeCoverage >= 0.004 && mask.activeCoverage <= 0.86
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

    private func protectedRegionMask(
        from photoMask: NormalizedPhotoMask?,
        analysis: PhotoAnalysis,
        extent: CGRect
    ) -> CIImage? {
        guard let photoMask, var mask = makePixelMask(from: photoMask, extent: extent) else {
            return nil
        }
        if let person = analysis.personMask,
           let personMask = makePixelMask(from: person, extent: extent) {
            mask = multiply(mask, by: personMask.applyingFilter("CIColorInvert"))
        }
        return mask.cropped(to: extent)
    }

    private func blendColorControls(
        image: CIImage,
        saturation: Float,
        brightness: Float,
        contrast: Float,
        mask: CIImage
    ) -> CIImage {
        let adjusted = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast
        ])
        return blend(adjusted, over: image, mask: mask)
    }

    private func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: background.extent)
    }

    private func multiply(_ foreground: CIImage, by background: CIImage) -> CIImage {
        foreground.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: background
        ]).cropped(to: foreground.extent)
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

