import CoreGraphics
import CoreImage
import Foundation
import Vision

final class PhotoAnalyzer {
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func analyze(data: Data) throws -> PhotoAnalysis {
        try analyze(data: data, includeFaceDetection: true)
    }

    func analyzeImageQuality(data: Data) throws -> PhotoAnalysis {
        try analyze(data: data, includeFaceDetection: false)
    }

    private func analyze(data: Data, includeFaceDetection: Bool) throws -> PhotoAnalysis {
        guard let image = CIImage(data: data) else {
            throw PhotoAnalysisError.invalidImageData
        }

        let average = try averageRGBA(for: image)
        let minMax = try luminanceMinMax(for: image)
        let faceRegions = includeFaceDetection ? detectFaceRegions(in: data) : []

        return PhotoAnalysis(
            averageLuminance: luminance(red: average.red, green: average.green, blue: average.blue),
            contrastRange: max(0, minMax.max - minMax.min),
            redAverage: average.red,
            greenAverage: average.green,
            blueAverage: average.blue,
            faceCount: faceRegions.count,
            faceRegions: faceRegions
        )
    }

    private func averageRGBA(for image: CIImage) throws -> RGBAValues {
        guard
            let filter = CIFilter(name: "CIAreaAverage")
        else {
            throw PhotoAnalysisError.analysisFailed
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)

        guard let outputImage = filter.outputImage else {
            throw PhotoAnalysisError.analysisFailed
        }

        var pixels = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixels,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return RGBAValues(
            red: Float(pixels[0]) / 255.0,
            green: Float(pixels[1]) / 255.0,
            blue: Float(pixels[2]) / 255.0
        )
    }

    private func luminanceMinMax(for image: CIImage) throws -> (min: Float, max: Float) {
        guard
            let filter = CIFilter(name: "CIAreaMinMax")
        else {
            throw PhotoAnalysisError.analysisFailed
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)

        guard let outputImage = filter.outputImage else {
            throw PhotoAnalysisError.analysisFailed
        }

        var pixels = [UInt8](repeating: 0, count: 8)
        context.render(
            outputImage,
            toBitmap: &pixels,
            rowBytes: 8,
            bounds: CGRect(x: 0, y: 0, width: 2, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let minimum = luminance(
            red: Float(pixels[0]) / 255.0,
            green: Float(pixels[1]) / 255.0,
            blue: Float(pixels[2]) / 255.0
        )
        let maximum = luminance(
            red: Float(pixels[4]) / 255.0,
            green: Float(pixels[5]) / 255.0,
            blue: Float(pixels[6]) / 255.0
        )

        return (minimum, maximum)
    }

    private func detectFaceRegions(in data: Data) -> [NormalizedPhotoRegion] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])

        do {
            try handler.perform([request])
            return request.results?.map { observation in
                NormalizedPhotoRegion(
                    x: Float(observation.boundingBox.origin.x),
                    y: Float(observation.boundingBox.origin.y),
                    width: Float(observation.boundingBox.width),
                    height: Float(observation.boundingBox.height)
                )
            } ?? []
        } catch {
            AppLogger.imageEngine.error("人脸检测失败：\(error.localizedDescription)")
            return []
        }
    }

    private func luminance(red: Float, green: Float, blue: Float) -> Float {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }
}

private struct RGBAValues {
    let red: Float
    let green: Float
    let blue: Float
}

enum PhotoAnalysisError: LocalizedError {
    case invalidImageData
    case analysisFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法分析这张照片的数据。"
        case .analysisFailed:
            return "照片分析流程没有生成结果。"
        }
    }
}

