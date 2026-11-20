import Photos

enum PhotoLibrarySaveResult: Equatable, Sendable {
    case captured(PhotoLibrarySaveOutcome)
    case originalMemoryRescue(OriginalRetentionReceipt)
    case diagnosticAssets
}

private struct SystemPhotoLibraryAssetWriter: PhotoLibraryAssetWriting {
    func authorizationStatus() async -> PhotoLibraryWriteAuthorization {
        Self.mapped(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAuthorization() async -> PhotoLibraryWriteAuthorization {
        Self.mapped(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    func createAsset(_ payload: PhotoLibraryAssetPayload) async throws -> String {
        let identifier = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = payload.filename
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: payload.data, options: options)
            identifier.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let value = identifier.value, !value.isEmpty else {
            throw PhotoLibraryAssetWriterError.commitConfirmationUnknown(
                "Photos 事务可能已完成，但未返回资产标识。"
            )
        }
        return value
    }

    private static func mapped(_ status: PHAuthorizationStatus) -> PhotoLibraryWriteAuthorization {
        switch status {
        case .authorized, .limited:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }
}

private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}

enum PhotoLibraryManager {
    private static let systemWriter = SystemPhotoLibraryAssetWriter()
    private static let saveCoordinator = PhotoSaveCoordinator(
        store: .shared,
        writer: systemWriter
    )
    private static let memoryRescueCoordinator = MemoryOriginalRescueCoordinator(
        writer: systemWriter
    )

    static func savePhoto(_ photo: CapturedPhoto) async throws -> PhotoLibrarySaveResult {
        try await savePhotos(photo)
    }

    static func savePhotos(_ photo: CapturedPhoto) async throws -> PhotoLibrarySaveResult {
        guard !photo.originalImageData.isEmpty else {
            throw PhotoLibraryError.invalidImageData
        }

        if photo.isDiagnosticImport {
            guard photo.hasCompletedProcessing else {
                throw PhotoLibraryError.processingIncomplete
            }
            try await saveDiagnosticAssets(photo)
            return .diagnosticAssets
        }

        if let receipt = photo.originalRetentionReceipt,
           case .memoryOnly = receipt.state {
            let receipt = try await memoryRescueCoordinator.save(photo)
            return .originalMemoryRescue(receipt)
        }

        let approvedEdit = photo.hasCompletedProcessing
            ? photo.editedImageData
            : nil
        let result = try await saveCoordinator.save(
            CapturedPhotoSaveRequest(
                captureID: photo.id,
                capturedAt: photo.capturedAt,
                originalData: photo.originalImageData,
                originalReceipt: photo.originalRetentionReceipt,
                approvedEditedData: approvedEdit
            )
        )
        return .captured(result)
    }

    private static func saveDiagnosticAssets(_ photo: CapturedPhoto) async throws {
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
        guard authorized else { throw PhotoLibraryError.permissionDenied }

        try await PHPhotoLibrary.shared().performChanges {
            let stamp = Int(photo.capturedAt.timeIntervalSince1970)
            let originalOptions = PHAssetResourceCreationOptions()
            originalOptions.originalFilename = "XiaoSuCamera_\(stamp)_Diagnostic_A_Original.jpg"
            let originalRequest = PHAssetCreationRequest.forAsset()
            originalRequest.addResource(
                with: .photo,
                data: photo.originalImageData,
                options: originalOptions
            )

            let editedOptions = PHAssetResourceCreationOptions()
            editedOptions.originalFilename = "XiaoSuCamera_\(stamp)_Diagnostic_B_Formal.jpg"
            let editedRequest = PHAssetCreationRequest.forAsset()
            editedRequest.addResource(
                with: .photo,
                data: photo.editedImageData,
                options: editedOptions
            )

            let diagnosticExports: [(identifier: String, filename: String)] = [
                ("C", "C_ReferenceCandidate"),
                ("D", "D_MeasuredAesthetic"),
                ("E1", "E1_SpatialEmphasis"),
                ("E2", "E2_RestrainedDepth"),
                ("M", "M_ManualRenderer")
            ]
            for export in diagnosticExports {
                let evidence = photo.diagnosticCandidates.first { $0.identifier == export.identifier }
                guard let candidate = DiagnosticBundleExporter.resolvedPreview(
                    for: evidence,
                    in: photo.processingStagePreviews
                ), !candidate.imageData.isEmpty else { continue }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "XiaoSuCamera_\(stamp)_\(export.filename).jpg"
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: candidate.imageData, options: options)
            }
        }
    }
}

/// Process-lifetime idempotency for the emergency path where private staging
/// itself failed. There is deliberately no claim of crash-safe exactly-once
/// behavior because that would require the unavailable persistent store.
private actor MemoryOriginalRescueCoordinator {
    private let writer: any PhotoLibraryAssetWriting
    private var completed: [UUID: OriginalRetentionReceipt] = [:]
    private var inProgress: Set<UUID> = []

    init(writer: any PhotoLibraryAssetWriting) {
        self.writer = writer
    }

    func save(_ photo: CapturedPhoto) async throws -> OriginalRetentionReceipt {
        if let receipt = completed[photo.id] { return receipt }
        guard !inProgress.contains(photo.id) else {
            throw PhotoSaveCoordinatorError.saveInProgress
        }
        inProgress.insert(photo.id)
        defer { inProgress.remove(photo.id) }

        let current = await writer.authorizationStatus()
        let authorization: PhotoLibraryWriteAuthorization
        if current == .notDetermined {
            authorization = await writer.requestAuthorization()
        } else {
            authorization = current
        }
        guard authorization == .authorized else {
            throw PhotoLibraryError.permissionDenied
        }

        let stamp = Int(photo.capturedAt.timeIntervalSince1970)
        let identifier = try await writer.createAsset(
            PhotoLibraryAssetPayload(
                data: photo.originalImageData,
                filename: "XiaoSuCamera_\(stamp)_\(photo.id.uuidString)_Original_Rescue.jpg"
            )
        )
        let now = Date()
        let receipt = OriginalRetentionReceipt(
            captureID: photo.id,
            sha256: OriginalPhotoRetentionStore.sha256(photo.originalImageData),
            capturedAt: photo.capturedAt,
            relativePath: nil,
            state: .committedToPhotoLibrary(
                assetIdentifier: identifier,
                committedAt: now
            ),
            updatedAt: now
        )
        completed[photo.id] = receipt
        return receipt
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
            return "需要相册写入权限才能保存照片；原图安全副本不会被删除。"
        }
    }
}

