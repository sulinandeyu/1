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
        var output = image

        let candidates: [TreatmentRegion] = [
            .subject, .ground, .vegetation, .water, .architecture
        ]
        for region in candidates {
            output = applyRegionalAdjustment(
                region,
                to: output,
                analysis: analysis,
                recipe: recipe
            )
        }

        return output.cropped(to: image.extent)
    }

    /// Used by the diagnostic renderer as well as the production loop so the
    /// subject-only preview cannot drift from the real local-processing branch.
    func applyRegionalAdjustment(
        _ region: TreatmentRegion,
        to image: CIImage,
        analysis: PhotoAnalysis,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        if analysis.faceCount > 0, analysis.personMask?.isValid != true {
            return image
        }
        let photoMask: NormalizedPhotoMask?
        switch region {
        case .subject: photoMask = analysis.salientSubjectMask
        case .ground: photoMask = analysis.groundMask
        case .vegetation: photoMask = analysis.vegetationMask
        case .water: photoMask = analysis.waterMask
        case .architecture: photoMask = analysis.architectureMask
        default: return image
        }
        guard
            let adjustment = RegionalPixelAdjustment.make(
                region: region,
                analysis: analysis,
                recipe: recipe
            ),
            let mask = protectedRegionMask(
                from: photoMask,
                analysis: analysis,
                excludingSalientSubject: region != .subject,
                extent: image.extent
            )
        else { return image }
        return apply(adjustment: adjustment, to: image, mask: mask)
            .cropped(to: image.extent)
    }

    func regionalExecutionDetails(
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> [String] {
        guard let analysis else { return ["区域精修：跳过（无分析结果）"] }
        let blocksSemanticRegions = analysis.faceCount > 0 && analysis.personMask?.isValid != true
        let semanticDetails = blocksSemanticRegions
            ? ["显著主体：跳过（人物保护）", "植被：跳过（人物保护）", "水面：跳过（人物保护）", "建筑：跳过（人物保护）", "地面/道路：跳过（人物保护）"]
            : [
                executionDetail(
                    name: "显著主体",
                    region: .subject,
                    mask: analysis.salientSubjectMask,
                    analysis: analysis,
                    recipe: recipe
                ),
                executionDetail(
                    name: "植被",
                    region: .vegetation,
                    mask: analysis.vegetationMask,
                    analysis: analysis,
                    recipe: recipe
                ),
                executionDetail(
                    name: "水面",
                    region: .water,
                    mask: analysis.waterMask,
                    analysis: analysis,
                    recipe: recipe
                ),
                executionDetail(
                    name: "建筑",
                    region: .architecture,
                    mask: analysis.architectureMask,
                    analysis: analysis,
                    recipe: recipe
                ),
                executionDetail(
                    name: "地面/道路",
                    region: .ground,
                    mask: analysis.groundMask,
                    analysis: analysis,
                    recipe: recipe
                )
            ]
        return semanticDetails + [skyExecutionDetail(analysis: analysis, recipe: recipe)]
    }

    private func executionDetail(
        name: String,
        region: TreatmentRegion,
        mask: NormalizedPhotoMask?,
        analysis: PhotoAnalysis,
        recipe: AutomaticEditingRecipe
    ) -> String {
        guard let mask, mask.isValid else { return "\(name)：跳过（无有效蒙版）" }
        guard isUsableRegionMask(mask) else {
            return String(format: "%@：跳过（覆盖率 %.2f%% 不可靠）", name, mask.activeCoverage * 100)
        }
        let exclusions = [analysis.personMask, region == .subject ? nil : analysis.salientSubjectMask]
            .compactMap { $0 }
        let effectiveCoverage = mask.activeCoverage(excluding: exclusions)
        guard effectiveCoverage >= 0.004 else {
            return String(format: "%@：跳过（保护人物/主体后有效覆盖仅 %.2f%%）", name, effectiveCoverage * 100)
        }
        guard let adjustment = RegionalPixelAdjustment.make(
            region: region,
            analysis: analysis,
            recipe: recipe
        ) else {
            return "\(name)：跳过（场景证据、区域统计或调整幅度不足）"
        }
        return String(
            format: "%@：已执行（覆盖率 %.2f%%；软边 %.1f%%；边界 %.1f%%；可靠度 %.0f%%；%@）",
            name,
            effectiveCoverage * 100,
            mask.qualityAssessment.softEdgeRatio * 100,
            mask.qualityAssessment.boundaryDensity * 100,
            mask.qualityAssessment.reliability * 100,
            adjustment.traceSummary
        )
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
        guard let mask = analysis.skyMask, mask.isValid else { return "天空：跳过（无有效蒙版）" }
        guard isUsableRegionMask(mask) else {
            return String(format: "天空：跳过（覆盖率 %.2f%% 不可靠）", mask.activeCoverage * 100)
        }
        return String(
            format: "天空：已执行（覆盖率 %.2f%%；EV=%+.3f highlights=%.3f saturation=%.3f）",
            mask.activeCoverage * 100,
            recipe.skyExposureEV,
            recipe.skyHighlightAmount,
            recipe.skySaturation
        )
    }

    private func isUsableRegionMask(_ mask: NormalizedPhotoMask?) -> Bool {
        guard let mask, mask.isValid else { return false }
        return mask.qualityAssessment.isUsable
    }

    private func applySubjectRelighting(
        to image: CIImage,
        analysis: PhotoAnalysis?,
        recipe: AutomaticEditingRecipe
    ) -> CIImage {
        guard
            (analysis?.faceCount ?? 0) > 0,
            recipe.subjectExposureEV > 0,
            let analysis,
            let photoMask = analysis.personMask,
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
        excludingSalientSubject: Bool,
        extent: CGRect
    ) -> CIImage? {
        let exclusions = [analysis.personMask, excludingSalientSubject ? analysis.salientSubjectMask : nil]
            .compactMap { $0 }
        guard let photoMask, photoMask.activeCoverage(excluding: exclusions) >= 0.004 else {
            return nil
        }
        guard var mask = makePixelMask(from: photoMask, extent: extent) else {
            return nil
        }
        if let person = analysis.personMask,
           let personMask = makePixelMask(from: person, extent: extent) {
            mask = multiply(mask, by: personMask.applyingFilter("CIColorInvert"))
        }
        if excludingSalientSubject,
           let subject = analysis.salientSubjectMask,
           let subjectMask = makePixelMask(from: subject, extent: extent) {
            mask = multiply(mask, by: subjectMask.applyingFilter("CIColorInvert"))
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

    private func apply(
        adjustment: RegionalPixelAdjustment,
        to image: CIImage,
        mask: CIImage
    ) -> CIImage {
        var adjusted = image
        if abs(adjustment.exposureEV) > 0.001 {
            adjusted = applyExposure(to: adjusted, ev: adjustment.exposureEV)
        }
        if adjustment.highlightAmount < 0.999 || adjustment.shadowAmount > 0.001 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = adjusted
            filter.highlightAmount = adjustment.highlightAmount
            filter.shadowAmount = adjustment.shadowAmount
            adjusted = filter.outputImage ?? adjusted
        }
        if abs(adjustment.temperatureShift) > 0.5 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = adjusted
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(
                x: CGFloat(6500 + adjustment.temperatureShift),
                y: 0
            )
            adjusted = filter.outputImage ?? adjusted
        }
        adjusted = adjusted.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: adjustment.saturation,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: adjustment.contrast
        ])
        if adjustment.clarity > 0.001 {
            let clarity = CIFilter.unsharpMask()
            clarity.inputImage = adjusted
            clarity.radius = Float(min(max(image.extent.width, image.extent.height) * 0.0008, 3.0))
            clarity.intensity = adjustment.clarity
            adjusted = clarity.outputImage ?? adjusted
        }
        return blend(adjusted.cropped(to: image.extent), over: image, mask: mask)
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

