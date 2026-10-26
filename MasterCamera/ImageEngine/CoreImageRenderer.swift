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
    private let cinematicToneMappingEngine = CinematicToneMappingEngine()
    private let professionalHSLProcessor = ProfessionalHSLProcessor()
    private let luminanceZoneProcessor = LuminanceZoneProcessor()
    private let cinematicColorGradingEngine = CinematicColorGradingEngine()
    private let cinematicSpatialDepthProcessor = CinematicSpatialDepthProcessor()
    private let cinematicLensCharacterProcessor = CinematicLensCharacterProcessor()

    func renderOriginalPreview(from data: Data) -> UIImage? {
        guard let decodedImage = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) else {
            return nil
        }
        let image = canonicalImage(decodedImage)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    func renderEvaluationOriginal(
        from data: Data,
        maximumLongEdge: CGFloat = 640
    ) throws -> Data {
        guard let decoded = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) else {
            throw ImageRenderingError.invalidImageData
        }
        return try evaluationJPEG(
            from: scaledForEvaluation(canonicalImage(decoded), maximumLongEdge: maximumLongEdge)
        )
    }

    func renderEvaluationPreview(
        from data: Data,
        recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?,
        maximumLongEdge: CGFloat = 640
    ) throws -> Data {
        let result = try processImage(
            data: data,
            recipe: recipe,
            analysis: analysis,
            maximumLongEdge: maximumLongEdge
        )
        return try evaluationJPEG(from: result.finalImage)
    }

    func renderStagePreviews(
        from data: Data,
        recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?
    ) throws -> [ProcessingStagePreview] {
        let result = try processImage(data: data, recipe: recipe, analysis: analysis)
        return result.stages.compactMap { name, image in
            guard let imageData = makeStagePreviewData(from: image) else { return nil }
            return ProcessingStagePreview(name: name, imageData: imageData)
        }
    }

    /// Development evidence for mask coordinates and coverage. These previews use
    /// exactly the same normalized-mask scaling as the renderer; they are diagnostic
    /// artifacts, not alternative photographs.
    func renderMaskDiagnosticPreviews(
        from data: Data,
        analysis: PhotoAnalysis,
        recipe: AutomaticEditingRecipe,
        maximumLongEdge: CGFloat = 640
    ) throws -> [ProcessingStagePreview] {
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw ImageRenderingError.invalidImageData
        }
        let source = scaledForEvaluation(
            canonicalImage(decoded),
            maximumLongEdge: maximumLongEdge
        )
        let masks: [(String, NormalizedPhotoMask?)] = [
            ("主体优先", analysis.subjectPriorityProfile.primarySubjectMask),
            ("显著性原始", analysis.subjectPriorityProfile.primarySubjectMask == nil ? analysis.salientSubjectMask : nil),
            ("天空", analysis.skyMask),
            ("地面道路", analysis.groundMask),
            ("植被", analysis.vegetationMask),
            ("水面", analysis.waterMask),
            ("建筑", analysis.architectureMask),
            ("人物", analysis.personMask)
        ]
        var previews: [ProcessingStagePreview] = []
        for (name, optionalMask) in masks {
            guard let mask = optionalMask, let maskImage = diagnosticMask(mask, extent: source.extent) else {
                continue
            }
            let rawMask = maskImage.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.15
            ]).cropped(to: source.extent)
            let tint = CIImage(color: CIColor(red: 1, green: 0.28, blue: 0.02, alpha: 1))
                .cropped(to: source.extent)
            let tintedRegion = tint.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: maskImage
            ]).cropped(to: source.extent)
            let overlay = source.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: tintedRegion,
                kCIInputTimeKey: 0.48
            ]).cropped(to: source.extent)
            previews.append(ProcessingStagePreview(
                name: "蒙版-\(name)",
                imageData: try evaluationJPEG(from: rawMask)
            ))
            previews.append(ProcessingStagePreview(
                name: "蒙版叠加-\(name)",
                imageData: try evaluationJPEG(from: overlay)
            ))
        }
        if analysis.subjectPriorityProfile.mode == .primarySubject,
           analysis.faceCount == 0 {
            let pipeline = try processImage(
                data: data,
                recipe: recipe,
                analysis: analysis,
                maximumLongEdge: maximumLongEdge
            )
            if let global = pipeline.stages.first(where: { $0.0 == "B 仅全局调整" })?.1 {
                let subjectAdjusted = localAdjustmentProcessor.applyRegionalAdjustment(
                    .subject,
                    to: global,
                    analysis: analysis,
                    recipe: recipe
                )
                let difference = subjectAdjusted
                    .applyingFilter("CIDifferenceBlendMode", parameters: [
                        kCIInputBackgroundImageKey: global
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 5, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 5, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                    ])
                    .cropped(to: global.extent)
                previews.append(ProcessingStagePreview(
                    name: "主体调整前-仅全局",
                    imageData: try evaluationJPEG(from: global)
                ))
                previews.append(ProcessingStagePreview(
                    name: "主体单独调整后",
                    imageData: try evaluationJPEG(from: subjectAdjusted)
                ))
                previews.append(ProcessingStagePreview(
                    name: "主体调整差异-放大5倍",
                    imageData: try evaluationJPEG(from: difference)
                ))
            }
        }
        return previews
    }

    func renderAutomaticEdit(
        from data: Data,
        recipe: AutomaticEditingRecipe = .naturalEnhancement,
        analysis: PhotoAnalysis? = nil
    ) throws -> Data {
        AppLogger.imageEngine.info(
            "渲染器收到配方：\(recipe.traceSummary, privacy: .public)；局部蒙版 person=\(analysis?.personMask?.isValid == true)，subject=\(analysis?.salientSubjectMask?.isValid == true)，sky=\(analysis?.skyMask?.isValid == true)，ground=\(analysis?.groundMask?.isValid == true)，vegetation=\(analysis?.vegetationMask?.isValid == true)，water=\(analysis?.waterMask?.isValid == true)，architecture=\(analysis?.architectureMask?.isValid == true)"
        )
        let result = try processImage(data: data, recipe: recipe, analysis: analysis)
        let finished = result.finalImage
        let canvas = result.canvas

        let modules = executedModuleNames(for: recipe, analysis: analysis)
        AppLogger.imageEngine.info(
            "执行像素模块：\(modules.joined(separator: " → "))；输出范围 \(Int(finished.extent.width))×\(Int(finished.extent.height))"
        )
        let timingSummary = String(
            format: "影调 %.1fms，色彩 %.1fms，空间 %.1fms，细节/镜头 %.1fms",
            result.timings[0] * 1_000,
            result.timings[1] * 1_000,
            result.timings[2] * 1_000,
            result.timings[3] * 1_000
        )
        AppLogger.imageEngine.info("V3 阶段耗时：\(timingSummary, privacy: .public)")

        guard let renderedJPEG = context.jpegRepresentation(
            of: finished,
            colorSpace: outputColorSpace,
            options: [:]
        ) else {
            throw ImageRenderingError.renderFailed
        }
        try validateEncodedGeometry(renderedJPEG, expectedCanvas: canvas)
        let jpegData = metadataPreservingJPEG(
            renderedData: renderedJPEG,
            originalData: data
        ) ?? renderedJPEG

        AppLogger.imageEngine.info(
            "完整分辨率 JPEG 渲染完成：\(jpegData.count) bytes，sRGB"
        )

        return jpegData
    }

    private func processImage(
        data: Data,
        recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?,
        maximumLongEdge: CGFloat? = nil
    ) throws -> (finalImage: CIImage, canvas: CGRect, stages: [(String, CIImage)], timings: [TimeInterval]) {
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw ImageRenderingError.invalidImageData
        }
        let canonical = canonicalImage(decoded)
        let input = maximumLongEdge.map {
            scaledForEvaluation(canonical, maximumLongEdge: $0)
        } ?? canonical
        let canvas = input.extent
        var start = ProcessInfo.processInfo.systemUptime
        let exposed = applyExposure(to: input, recipe: recipe)
        let recovered = applyHighlightShadow(to: exposed, recipe: recipe)
        let blackAdjusted = applyBlackPoint(to: recovered, recipe: recipe)
        let baseCurved = applyToneCurve(to: blackAdjusted, recipe: recipe)
        let filmic = cinematicToneMappingEngine.apply(to: baseCurved, recipe: recipe)
        let curved = try checkedCanvas(luminanceZoneProcessor.apply(to: filmic, recipe: recipe), canvas: canvas, stage: "亮度蒙版影调")
        let toneTime = ProcessInfo.processInfo.systemUptime - start

        start = ProcessInfo.processInfo.systemUptime
        let whiteBalanced = applyWhiteBalance(to: curved, recipe: recipe)
        let colored = applyColorControls(to: whiteBalanced, recipe: recipe)
        let vibrant = applyVibrance(to: colored, recipe: recipe)
        let hslAdjusted = professionalHSLProcessor.apply(to: vibrant, adjustment: recipe.hsl)
        let graded = try checkedCanvas(cinematicColorGradingEngine.apply(to: hslAdjusted, recipe: recipe), canvas: canvas, stage: "专业色彩分级")
        let colorTime = ProcessInfo.processInfo.systemUptime - start

        start = ProcessInfo.processInfo.systemUptime
        let relit = localAdjustmentProcessor.applyLocalizedRelighting(to: graded, analysis: analysis, recipe: recipe)
        let sky = skyAdjustmentProcessor.applySkyTreatment(to: relit, analysis: analysis, recipe: recipe)
        let separated = cinematicSpatialDepthProcessor.apply(to: sky, analysis: analysis, recipe: recipe)
        let local = try checkedCanvas(applyLocalContrast(to: separated, recipe: recipe), canvas: canvas, stage: "局部空间与材质")
        let spatialTime = ProcessInfo.processInfo.systemUptime - start

        start = ProcessInfo.processInfo.systemUptime
        let denoised = applyNoiseReduction(to: local, recipe: recipe)
        let sharpened = applySharpening(to: denoised, recipe: recipe)
        let protected = skinTextureProtectionProcessor.protectTexture(processedImage: sharpened, sourceImage: local, analysis: analysis, amount: recipe.skinTextureProtection)
        let finished = try checkedCanvas(cinematicLensCharacterProcessor.apply(to: protected, recipe: recipe), canvas: canvas, stage: "镜头特征")
        let detailTime = ProcessInfo.processInfo.systemUptime - start
        return (finished, canvas, [
            ("A 原始照片", input),
            ("曝光与动态范围", blackAdjusted),
            ("七段电影影调", curved),
            ("B 仅全局调整", graded),
            ("C 全局+局部蒙版", local),
            ("E 自动选择最终结果", finished)
        ], [toneTime, colorTime, spatialTime, detailTime])
    }

    private func diagnosticMask(
        _ photoMask: NormalizedPhotoMask,
        extent: CGRect
    ) -> CIImage? {
        guard photoMask.isValid else { return nil }
        let image = CIImage(
            bitmapData: photoMask.pixels,
            bytesPerRow: photoMask.width,
            size: CGSize(width: photoMask.width, height: photoMask.height),
            format: .L8,
            colorSpace: nil
        )
        let scaled = image
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / CGFloat(photoMask.width),
                y: extent.height / CGFloat(photoMask.height)
            ))
            .transformed(by: CGAffineTransform(
                translationX: extent.minX,
                y: extent.minY
            ))
        return scaled.cropped(to: extent)
    }

    private func canonicalImage(_ image: CIImage) -> CIImage {
        let sourceExtent = image.extent.integral
        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )
        return translated.cropped(
            to: CGRect(origin: .zero, size: sourceExtent.size)
        )
    }

    private func scaledForEvaluation(
        _ image: CIImage,
        maximumLongEdge: CGFloat
    ) -> CIImage {
        let longEdge = max(image.extent.width, image.extent.height)
        guard longEdge > maximumLongEdge else { return image }
        let scale = maximumLongEdge / longEdge
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(
                x: 0,
                y: 0,
                width: (image.extent.width * scale).rounded(.down),
                height: (image.extent.height * scale).rounded(.down)
            ))
    }

    private func evaluationJPEG(from image: CIImage) throws -> Data {
        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: outputColorSpace,
            options: [:]
        ) else {
            throw ImageRenderingError.renderFailed
        }
        return data
    }

    private func checkedCanvas(
        _ image: CIImage,
        canvas: CGRect,
        stage: String
    ) throws -> CIImage {
        let extent = image.extent
        guard
            !extent.isNull,
            !extent.isEmpty,
            extent.minX <= canvas.minX,
            extent.minY <= canvas.minY,
            extent.maxX >= canvas.maxX,
            extent.maxY >= canvas.maxY
        else {
            AppLogger.imageEngine.error(
                "画布检查失败：\(stage, privacy: .public)，输出=\(String(describing: extent), privacy: .public)，预期=\(String(describing: canvas), privacy: .public)"
            )
            throw ImageRenderingError.canvasMismatch(stage)
        }
        return image.cropped(to: canvas)
    }

    private func validateEncodedGeometry(
        _ data: Data,
        expectedCanvas: CGRect
    ) throws {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageRenderingError.renderFailed
        }
        let expectedWidth = Int(expectedCanvas.width.rounded())
        let expectedHeight = Int(expectedCanvas.height.rounded())
        guard width == expectedWidth, height == expectedHeight else {
            AppLogger.imageEngine.error(
                "JPEG 尺寸异常：\(width)×\(height)，预期 \(expectedWidth)×\(expectedHeight)"
            )
            throw ImageRenderingError.canvasMismatch("JPEG 编码")
        }
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

    private func makeStagePreviewData(from image: CIImage) -> Data? {
        let maximumLongEdge: CGFloat = 720
        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let scale = min(
            1,
            maximumLongEdge / max(translated.extent.width, translated.extent.height)
        )
        let preview = translated.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return context.jpegRepresentation(
            of: preview,
            colorSpace: outputColorSpace,
            options: [:]
        )
    }

    func executedModuleNames(
        for recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?
    ) -> [String] {
        var modules = ["方向/色彩空间", "曝光", "高光阴影"]
        if recipe.blackPoint > 0.001 { modules.append("黑位") }
        if recipe.toneCurveAmount > 0.001 { modules.append("\(recipe.toneCurveStyle.rawValue)曲线") }
        modules.append("七段电影影调/\(recipe.cinematicIntensity.title)")
        if abs(recipe.temperatureShift) > 0.5 || abs(recipe.tintShift) > 0.01 { modules.append("白平衡") }
        modules.append("色彩控制")
        if recipe.vibrance > 0.001 { modules.append("自然饱和度") }
        if recipe.hsl != .neutral { modules.append("分区 HSL") }
        if recipe.luminanceMaskStrength > 0.001 { modules.append("亮度蒙版高光/阴影") }
        if recipe.colorGradeIntensity > 0.001 { modules.append("阴影/中间调/高光电影分级") }
        if recipe.subjectExposureEV > 0.001 || recipe.faceExposureEV > 0.001 { modules.append("主体/人脸补光") }
        modules.append(contentsOf: regionalExecutionDetails(for: recipe, analysis: analysis)
            .filter { $0.contains("已执行") })
        if recipe.backgroundSeparation > 0.001,
           analysis?.personMask != nil || analysis?.salientSubjectMask != nil {
            modules.append("主体/背景空间层次")
        }
        if recipe.localContrastAmount > 0.001 { modules.append("局部对比/材质") }
        if recipe.noiseReductionAmount > 0.001 { modules.append("降噪") }
        if recipe.sharpeningAmount > 0.001 { modules.append("亮度锐化") }
        if recipe.skinTextureProtection > 0.001 { modules.append("肤质保护") }
        if recipe.vignetteIntensity > 0.001 { modules.append("暗角") }
        if recipe.grainAmount > 0.001 { modules.append("胶片颗粒") }
        if recipe.bloomIntensity > 0.001 { modules.append("高光 Bloom") }
        if recipe.halationIntensity > 0.001 { modules.append("暖色 Halation") }
        return modules
    }

    func regionalExecutionDetails(
        for recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis?
    ) -> [String] {
        localAdjustmentProcessor.regionalExecutionDetails(
            analysis: analysis,
            recipe: recipe
        )
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
                CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.23),
                CGPoint(x: 0.5, y: 0.515), CGPoint(x: 0.75, y: 0.78),
                CGPoint(x: 1, y: 0.99)
            ]
        case .portrait:
            targetPoints = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.258),
                CGPoint(x: 0.5, y: 0.525), CGPoint(x: 0.75, y: 0.775),
                CGPoint(x: 1, y: 0.99)
            ]
        case .landscape:
            targetPoints = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.22),
                CGPoint(x: 0.5, y: 0.515), CGPoint(x: 0.75, y: 0.805),
                CGPoint(x: 1, y: 0.99)
            ]
        case .cinematic:
            targetPoints = [
                CGPoint(x: 0, y: 0.024), CGPoint(x: 0.25, y: 0.225),
                CGPoint(x: 0.5, y: 0.505), CGPoint(x: 0.75, y: 0.79),
                CGPoint(x: 1, y: 0.965)
            ]
        case .softHighlights:
            targetPoints = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.252),
                CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.75, y: 0.77),
                CGPoint(x: 1, y: 0.975)
            ]
        case .interior:
            targetPoints = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.275),
                CGPoint(x: 0.5, y: 0.525), CGPoint(x: 0.75, y: 0.78),
                CGPoint(x: 1, y: 0.975)
            ]
        case .workspace:
            targetPoints = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.235),
                CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.75, y: 0.79),
                CGPoint(x: 1, y: 0.98)
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

    private func applyBlackPoint(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        let blackPoint = CGFloat(recipe.blackPoint)
        guard blackPoint > 0.001, blackPoint < 0.99 else { return image }
        let slope = 1 / (1 - blackPoint)
        let offset = -blackPoint * slope
        let coefficients = CIVector(x: offset, y: slope, z: 0, w: 0)
        return image.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": coefficients,
            "inputGreenCoefficients": coefficients,
            "inputBlueCoefficients": coefficients
        ])
    }

    private func applyLocalContrast(to image: CIImage, recipe: AutomaticEditingRecipe) -> CIImage {
        guard recipe.localContrastAmount > 0.001 else { return image }
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(min(max(image.extent.width, image.extent.height) * 0.0009, 3.5))
        filter.intensity = recipe.localContrastAmount * 0.62
        return (filter.outputImage ?? image).cropped(to: image.extent)
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
        filter.sharpness = 0.18
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
    case canvasMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法加载拍摄的图片数据。"
        case .renderFailed:
            return "无法渲染 AI 成片。"
        case .canvasMismatch(let stage):
            return "\(stage) 的图像画布与原图不一致，已阻止保存异常成片。"
        }
    }
}

