import Photos

enum PhotoLibraryManager {
    static func savePhoto(_ photo: CapturedPhoto) async throws {
        try await savePhotos(photo)
    }

    static func savePhotos(_ photo: CapturedPhoto) async throws {
        guard !photo.originalImageData.isEmpty, !photo.editedImageData.isEmpty else {
            throw PhotoLibraryError.invalidImageData
        }
        guard photo.hasCompletedProcessing else {
            throw PhotoLibraryError.processingIncomplete
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
            let stamp = Int(photo.capturedAt.timeIntervalSince1970)

            let originalOptions = PHAssetResourceCreationOptions()
            originalOptions.originalFilename = "XiaoSuCamera_\(stamp)_Original.jpg"
            let originalRequest = PHAssetCreationRequest.forAsset()
            originalRequest.addResource(
                with: .photo,
                data: photo.originalImageData,
                options: originalOptions
            )

            let editedOptions = PHAssetResourceCreationOptions()
            editedOptions.originalFilename = "XiaoSuCamera_\(stamp)_AI_Edited.jpg"
            let editedRequest = PHAssetCreationRequest.forAsset()
            editedRequest.addResource(
                with: .photo,
                data: photo.editedImageData,
                options: editedOptions
            )
        }
    }
}

enum PhotoLibraryError: LocalizedError {
    case invalidImageData
    case processingIncomplete
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "无法解码拍摄的图片。"
        case .processingIncomplete:
            return "AI 后期尚未完成或未通过质量检查，已阻止把原图保存为 AI 成片。"
        case .permissionDenied:
            return "需要相册写入权限才能保存照片。"
        }
    }
}

