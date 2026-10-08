import Photos
import UIKit

enum PhotoLibraryManager {
    static func savePhoto(_ photo: CapturedPhoto) async throws {
        try await savePhotos(photo)
    }

    static func savePhotos(_ photo: CapturedPhoto) async throws {
        guard
            let originalImage = photo.originalImage,
            let editedImage = photo.editedImage
        else {
            throw PhotoLibraryError.invalidImageData
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorized: Bool

        switch status {
        case .authorized, .limited:
            authorized = true
        case .notDetermined:
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            authorized = requested == .authorized || requested == .limited
        default:
            authorized = false
        }

        guard authorized else {
            throw PhotoLibraryError.permissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: originalImage)
            PHAssetChangeRequest.creationRequestForAsset(from: editedImage)
        }
    }
}

enum PhotoLibraryError: LocalizedError {
    case invalidImageData
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法解码拍摄的图片。"
        case .permissionDenied:
            return "需要相册写入权限才能保存照片。"
        }
    }
}

