import CoreGraphics
import CoreImage
import Foundation

final class SkinTextureProtectionProcessor {
    func protectTexture(
        processedImage: CIImage,
        sourceImage: CIImage,
        analysis: PhotoAnalysis?,
        amount: Float
    ) -> CIImage {
        guard
            amount > 0.001,
            let analysis,
            let mask = makeProtectionMask(
                analysis: analysis,
                extent: processedImage.extent,
                amount: amount
            ),
            let blend = CIFilter(name: "CIBlendWithMask")
        else {
            return processedImage
        }

        blend.setValue(sourceImage, forKey: kCIInputImageKey)
        blend.setValue(processedImage, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: processedImage.extent) ?? processedImage
    }

    private func makeProtectionMask(
        analysis: PhotoAnalysis,
        extent: CGRect,
        amount: Float
    ) -> CIImage? {
        if let skinMask = analysis.skinMask,
           let pixelMask = makePixelMask(from: skinMask, extent: extent, amount: amount) {
            return pixelMask
        }

        guard !analysis.faceRegions.isEmpty else { return nil }
        return makeSkinTextureMask(
            for: analysis.faceRegions,
            extent: extent,
            amount: amount
        )
    }

    private func makePixelMask(
        from photoMask: NormalizedPhotoMask,
        extent: CGRect,
        amount: Float
    ) -> CIImage? {
        guard photoMask.isValid else { return nil }

        let maskImage = CIImage(
            bitmapData: photoMask.pixels,
            bytesPerRow: photoMask.width,
            size: CGSize(width: photoMask.width, height: photoMask.height),
            format: .L8,
            colorSpace: nil
        )
        let scaled = maskImage
            .transformed(
                by: CGAffineTransform(
                    scaleX: extent.width / CGFloat(photoMask.width),
                    y: extent.height / CGFloat(photoMask.height)
                )
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: extent.minX,
                    y: extent.minY
                )
            )

        let controlled = scaled.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(amount), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount), w: 0)
            ]
        )
        return controlled.cropped(to: extent)
    }

    private func makeSkinTextureMask(
        for faceRegions: [NormalizedPhotoRegion],
        extent: CGRect,
        amount: Float
    ) -> CIImage? {
        var combinedMask: CIImage?

        for face in faceRegions {
            let faceWidth = CGFloat(face.width) * extent.width
            let faceHeight = CGFloat(face.height) * extent.height
            let faceCenter = CGPoint(
                x: extent.minX + CGFloat(face.centerX) * extent.width,
                y: extent.minY + CGFloat(face.centerY) * extent.height
            )
            let baseRadius = max(1, min(faceWidth, faceHeight))

            // 只保护额头和双颊的纹理，避免把眼睛、嘴唇与头发一起柔化。
            let zones = [
                SkinZone(
                    center: CGPoint(
                        x: faceCenter.x,
                        y: faceCenter.y + (faceHeight * 0.22)
                    ),
                    innerRadius: baseRadius * 0.08,
                    outerRadius: baseRadius * 0.2
                ),
                SkinZone(
                    center: CGPoint(
                        x: faceCenter.x - (faceWidth * 0.2),
                        y: faceCenter.y - (faceHeight * 0.06)
                    ),
                    innerRadius: baseRadius * 0.1,
                    outerRadius: baseRadius * 0.24
                ),
                SkinZone(
                    center: CGPoint(
                        x: faceCenter.x + (faceWidth * 0.2),
                        y: faceCenter.y - (faceHeight * 0.06)
                    ),
                    innerRadius: baseRadius * 0.1,
                    outerRadius: baseRadius * 0.24
                )
            ]

            for zone in zones {
                guard let zoneMask = makeSoftMask(
                    zone: zone,
                    extent: extent,
                    amount: amount
                ) else {
                    continue
                }

                if let existingMask = combinedMask {
                    combinedMask = maximum(zoneMask, existingMask)
                } else {
                    combinedMask = zoneMask
                }
            }
        }

        return combinedMask?.cropped(to: extent)
    }

    private func makeSoftMask(
        zone: SkinZone,
        extent: CGRect,
        amount: Float
    ) -> CIImage? {
        guard let gradient = CIFilter(name: "CIRadialGradient") else {
            return nil
        }

        let maskValue = CGFloat(min(max(amount, 0), 1))
        gradient.setValue(CIVector(cgPoint: zone.center), forKey: "inputCenter")
        gradient.setValue(zone.innerRadius, forKey: "inputRadius0")
        gradient.setValue(zone.outerRadius, forKey: "inputRadius1")
        gradient.setValue(
            CIColor(red: maskValue, green: maskValue, blue: maskValue, alpha: 1),
            forKey: "inputColor0"
        )
        gradient.setValue(
            CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            forKey: "inputColor1"
        )
        return gradient.outputImage?.cropped(to: extent)
    }

    private func maximum(_ foreground: CIImage, _ background: CIImage) -> CIImage {
        guard let compositing = CIFilter(name: "CIMaximumCompositing") else {
            return foreground
        }

        compositing.setValue(foreground, forKey: kCIInputImageKey)
        compositing.setValue(background, forKey: kCIInputBackgroundImageKey)
        return compositing.outputImage ?? foreground
    }
}

private struct SkinZone {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
}
