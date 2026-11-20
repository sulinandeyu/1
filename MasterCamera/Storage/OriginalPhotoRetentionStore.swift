import CryptoKit
import Foundation

enum OriginalRetentionState: Equatable, Codable, Sendable {
    case staged
    case awaitingPhotoLibraryPermission
    case committingToPhotoLibrary(startedAt: Date)
    case committedToPhotoLibrary(assetIdentifier: String, committedAt: Date)
    case saveFailed(reason: String)
    case needsReconciliation(reason: String)
    case memoryOnly(reason: String)
    case unavailable(reason: String)
}

struct OriginalRetentionReceipt: Equatable, Codable, Sendable {
    let captureID: UUID
    let sha256: String
    let capturedAt: Date
    let relativePath: String?
    let state: OriginalRetentionState
    let updatedAt: Date

    var hasRecoverableOriginal: Bool {
        switch state {
        case .staged,
             .awaitingPhotoLibraryPermission,
             .committingToPhotoLibrary,
             .saveFailed,
             .needsReconciliation:
            return relativePath != nil
        case .committedToPhotoLibrary:
            return true
        case .memoryOnly, .unavailable:
            return false
        }
    }

    var isCommittedToPhotoLibrary: Bool {
        if case .committedToPhotoLibrary = state {
            return true
        }
        return false
    }

    static func memoryOnly(
        captureID: UUID,
        data: Data,
        capturedAt: Date,
        reason: String,
        now: Date = Date()
    ) -> OriginalRetentionReceipt {
        OriginalRetentionReceipt(
            captureID: captureID,
            sha256: OriginalPhotoRetentionStore.sha256(data),
            capturedAt: capturedAt,
            relativePath: nil,
            state: .memoryOnly(reason: reason),
            updatedAt: now
        )
    }
}

enum RetainedPhotoAssetKind: String, Equatable, Codable, Sendable {
    case original
    case formalEdit
}

enum RetainedPhotoAssetCommitState: Equatable, Codable, Sendable {
    case notRequested
    case committing(sha256: String, startedAt: Date)
    case committed(sha256: String, assetIdentifier: String, committedAt: Date)
    case saveFailed(sha256: String, reason: String)
    case needsReconciliation(sha256: String, reason: String)
}

struct OriginalRetentionManifestEntry: Equatable, Codable, Sendable {
    var original: OriginalRetentionReceipt
    var formalEdit: RetainedPhotoAssetCommitState
}

struct OriginalRetentionManifest: Equatable, Codable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var entries: [String: OriginalRetentionManifestEntry] = [:]

    static let empty = OriginalRetentionManifest()
}

struct OriginalRetentionRecoveryReport: Equatable, Sendable {
    let recoverableOriginals: [OriginalRetentionReceipt]
    let needsReconciliation: [OriginalRetentionReceipt]
    let issues: [String]
}

enum OriginalRetentionManifestLoadResult: Equatable, Sendable {
    case missing
    case loaded(OriginalRetentionManifest)
    case corrupted(preservedCopyName: String?)
}

struct OriginalRetentionCleanupReport: Equatable, Sendable {
    let removedCaptureIDs: [UUID]
    let issues: [String]
}

struct ValidatedOriginalForSave: Equatable, Sendable {
    let receipt: OriginalRetentionReceipt
    let stagedData: Data?
    let confirmedAssetIdentifier: String?
}

enum OriginalRetentionPolicy {
    static func shouldStageNewCapture(isDiagnosticImport: Bool) -> Bool {
        !isDiagnosticImport
    }
}

enum OriginalRetentionError: LocalizedError, Equatable {
    case emptyOriginal
    case captureIDCollision
    case stagedFileMissing
    case stagedFileHashMismatch
    case manifestUnavailable(String)
    case commitAlreadyInProgress
    case commitNeedsReconciliation(String)
    case unknownCapture
    case editedDataChanged
    case retentionEvidenceMismatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyOriginal:
            return "原始照片数据为空，无法建立安全副本。"
        case .captureIDCollision:
            return "拍摄标识已存在但原图哈希不同，已阻止覆盖。"
        case .stagedFileMissing:
            return "原图安全副本已登记但文件缺失。"
        case .stagedFileHashMismatch:
            return "原图安全副本校验失败，已阻止继续保存。"
        case .manifestUnavailable(let reason):
            return "原图安全索引不可用：\(reason)"
        case .commitAlreadyInProgress:
            return "这张照片正在保存，请稍后再试。"
        case .commitNeedsReconciliation(let reason):
            return "相册保存结果需要人工确认，已停止自动重试以避免重复：\(reason)"
        case .unknownCapture:
            return "找不到这张照片的原图安全记录。"
        case .editedDataChanged:
            return "同一拍摄记录对应的正式成片内容发生变化，已阻止重复保存。"
        case .retentionEvidenceMismatch(let reason):
            return "原图保存证据不一致，已阻止写入系统相册：\(reason)"
        }
    }
}

protocol OriginalRetentionPersistence: Sendable {
    func loadManifest() throws -> OriginalRetentionManifestLoadResult
    func persistManifest(_ manifest: OriginalRetentionManifest) throws
    func stageVerifiedOriginal(data: Data, relativePath: String, expectedSHA256: String) throws
    func originalData(relativePath: String) throws -> Data
    func originalExists(relativePath: String) -> Bool
    func completeOriginalRelativePaths() throws -> [String]
    func removeOriginal(relativePath: String) throws
}

final class FileOriginalRetentionPersistence: OriginalRetentionPersistence, @unchecked Sendable {
    private let fileManager: FileManager
    private let rootURL: URL
    private let originalsURL: URL
    private let recoveryURL: URL
    private let manifestURL: URL

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.rootURL = rootURL
            ?? applicationSupport
                .appendingPathComponent("XiaoSuCamera", isDirectory: true)
                .appendingPathComponent("OriginalRetention", isDirectory: true)
        self.originalsURL = self.rootURL.appendingPathComponent("Originals", isDirectory: true)
        self.recoveryURL = self.rootURL.appendingPathComponent("Recovery", isDirectory: true)
        self.manifestURL = self.rootURL.appendingPathComponent("manifest.json")
    }

    func loadManifest() throws -> OriginalRetentionManifestLoadResult {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .missing }
        let data = try Data(contentsOf: manifestURL)
        do {
            return .loaded(
                try Self.decoder.decode(OriginalRetentionManifest.self, from: data)
            )
        } catch {
            let preserved = recoveryURL.appendingPathComponent(
                "manifest-corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
            )
            let preservedName: String?
            do {
                try fileManager.copyItem(at: manifestURL, to: preserved)
                preservedName = preserved.lastPathComponent
            } catch {
                preservedName = nil
            }
            return .corrupted(preservedCopyName: preservedName)
        }
    }

    func persistManifest(_ manifest: OriginalRetentionManifest) throws {
        try prepareDirectories()
        let data = try Self.encoder.encode(manifest)
        _ = try Self.decoder.decode(OriginalRetentionManifest.self, from: data)
        let temporaryURL = rootURL.appendingPathComponent("manifest-writing-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: protectedWriteOptions)
        let verifiedData = try Data(contentsOf: temporaryURL)
        _ = try Self.decoder.decode(OriginalRetentionManifest.self, from: verifiedData)

        if fileManager.fileExists(atPath: manifestURL.path) {
            _ = try fileManager.replaceItemAt(
                manifestURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: manifestURL)
        }
    }

    func stageVerifiedOriginal(
        data: Data,
        relativePath: String,
        expectedSHA256: String
    ) throws {
        try prepareDirectories()
        let destination = originalsURL.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination, options: .mappedIfSafe)
            guard OriginalPhotoRetentionStore.sha256(existing) == expectedSHA256 else {
                throw OriginalRetentionError.stagedFileHashMismatch
            }
            return
        }

        let temporaryURL = originalsURL.appendingPathComponent("original-writing-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: protectedWriteOptions)
        let verified = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        guard OriginalPhotoRetentionStore.sha256(verified) == expectedSHA256 else {
            throw OriginalRetentionError.stagedFileHashMismatch
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    func originalData(relativePath: String) throws -> Data {
        let url = originalsURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw OriginalRetentionError.stagedFileMissing
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func originalExists(relativePath: String) -> Bool {
        fileManager.fileExists(atPath: originalsURL.appendingPathComponent(relativePath).path)
    }

    func completeOriginalRelativePaths() throws -> [String] {
        try prepareDirectories()
        return try fileManager.contentsOfDirectory(
            at: originalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .map(\.lastPathComponent)
    }

    func removeOriginal(relativePath: String) throws {
        let url = originalsURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: originalsURL,
            withIntermediateDirectories: true,
            attributes: protectedDirectoryAttributes
        )
        try fileManager.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true,
            attributes: protectedDirectoryAttributes
        )
    }

    private var protectedWriteOptions: Data.WritingOptions {
#if os(iOS)
        return .completeFileProtection
#else
        return []
#endif
    }

    private var protectedDirectoryAttributes: [FileAttributeKey: Any]? {
#if os(iOS)
        return [.protectionKey: FileProtectionType.complete]
#else
        return nil
#endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum PhotoAssetCommitReservation: Equatable, Sendable {
    case create
    case alreadyCommitted(assetIdentifier: String)
    case inProgress
    case needsReconciliation(reason: String)
}

actor OriginalPhotoRetentionStore {
    static let shared = OriginalPhotoRetentionStore(
        persistence: FileOriginalRetentionPersistence()
    )

    private let persistence: any OriginalRetentionPersistence
    private let now: @Sendable () -> Date
    private var manifest: OriginalRetentionManifest?
    private var manifestWasCorrupted = false
    private var preservedCorruptManifestName: String?
    private var didPerformColdLaunchReconciliation = false

    init(
        persistence: any OriginalRetentionPersistence,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.now = now
    }

    func stageOriginal(
        data: Data,
        captureID: UUID,
        capturedAt: Date
    ) throws -> OriginalRetentionReceipt {
        guard !data.isEmpty else { throw OriginalRetentionError.emptyOriginal }
        let hash = Self.sha256(data)
        var current = try loadedManifest()
        let key = captureID.uuidString.lowercased()

        if let existing = current.entries[key] {
            guard existing.original.sha256 == hash else {
                throw OriginalRetentionError.captureIDCollision
            }
            if let path = existing.original.relativePath,
               persistence.originalExists(relativePath: path) {
                let staged = try persistence.originalData(relativePath: path)
                guard Self.sha256(staged) == hash else {
                    throw OriginalRetentionError.stagedFileHashMismatch
                }
            } else if !existing.original.isCommittedToPhotoLibrary {
                throw OriginalRetentionError.stagedFileMissing
            }
            return existing.original
        }

        let timestamp = Int64((capturedAt.timeIntervalSince1970 * 1_000).rounded())
        let relativePath = "\(captureID.uuidString.lowercased())__\(timestamp)__\(hash).jpg"
        try persistence.stageVerifiedOriginal(
            data: data,
            relativePath: relativePath,
            expectedSHA256: hash
        )
        let receipt = OriginalRetentionReceipt(
            captureID: captureID,
            sha256: hash,
            capturedAt: capturedAt,
            relativePath: relativePath,
            state: .staged,
            updatedAt: now()
        )
        current.entries[key] = OriginalRetentionManifestEntry(
            original: receipt,
            formalEdit: .notRequested
        )
        try persistAndInstall(current)
        return receipt
    }

    func originalData(for receipt: OriginalRetentionReceipt) throws -> Data {
        guard let relativePath = receipt.relativePath else {
            throw OriginalRetentionError.stagedFileMissing
        }
        let data = try persistence.originalData(relativePath: relativePath)
        guard Self.sha256(data) == receipt.sha256 else {
            throw OriginalRetentionError.stagedFileHashMismatch
        }
        return data
    }

    func currentReceipt(captureID: UUID) throws -> OriginalRetentionReceipt? {
        try loadedManifest().entries[captureID.uuidString.lowercased()]?.original
    }

    func validateOriginalForSave(
        captureID: UUID,
        proposedData: Data,
        suppliedReceipt: OriginalRetentionReceipt?
    ) throws -> ValidatedOriginalForSave {
        let current = try loadedManifest()
        let key = captureID.uuidString.lowercased()
        guard let entry = current.entries[key] else {
            throw OriginalRetentionError.unknownCapture
        }
        let authoritative = entry.original
        guard authoritative.captureID == captureID else {
            throw OriginalRetentionError.retentionEvidenceMismatch("manifest capture ID 不一致")
        }
        if let suppliedReceipt {
            guard suppliedReceipt.captureID == captureID else {
                throw OriginalRetentionError.retentionEvidenceMismatch("外部 receipt capture ID 不一致")
            }
            guard suppliedReceipt.sha256 == authoritative.sha256 else {
                throw OriginalRetentionError.retentionEvidenceMismatch("外部 receipt SHA-256 不一致")
            }
            if suppliedReceipt.relativePath != authoritative.relativePath {
                let isExpectedCleanupTransition = authoritative.isCommittedToPhotoLibrary
                    && authoritative.relativePath == nil
                guard isExpectedCleanupTransition else {
                    throw OriginalRetentionError.retentionEvidenceMismatch("外部 receipt 暂存路径不一致")
                }
            }
        }
        let proposedHash = Self.sha256(proposedData)
        guard proposedHash == authoritative.sha256 else {
            throw OriginalRetentionError.retentionEvidenceMismatch("待保存字节与 manifest SHA-256 不一致")
        }
        if let relativePath = authoritative.relativePath {
            let stagedData = try persistence.originalData(relativePath: relativePath)
            guard Self.sha256(stagedData) == authoritative.sha256 else {
                throw OriginalRetentionError.retentionEvidenceMismatch("私有暂存文件 SHA-256 不一致")
            }
            let confirmedIdentifier: String?
            if case .committedToPhotoLibrary(let identifier, _) = authoritative.state {
                confirmedIdentifier = identifier
            } else {
                confirmedIdentifier = nil
            }
            return ValidatedOriginalForSave(
                receipt: authoritative,
                stagedData: stagedData,
                confirmedAssetIdentifier: confirmedIdentifier
            )
        }

        guard case .committedToPhotoLibrary(let identifier, _) = authoritative.state else {
            throw OriginalRetentionError.retentionEvidenceMismatch("未提交原图缺少可校验的私有暂存文件")
        }
        return ValidatedOriginalForSave(
            receipt: authoritative,
            stagedData: nil,
            confirmedAssetIdentifier: identifier
        )
    }

    /// Performs process-restart recovery exactly once. Routine UI refreshes must
    /// call `recoverySnapshot()` so an in-flight Photos transaction in this
    /// process is never mistaken for a crash left by an earlier process.
    func reconcileAfterColdLaunch() throws -> OriginalRetentionRecoveryReport {
        if didPerformColdLaunchReconciliation {
            return try recoverySnapshot()
        }
        var current = try loadedManifest()
        var issues: [String] = []
        var changed = false

        if manifestWasCorrupted {
            let preserved = preservedCorruptManifestName ?? "副本保存失败"
            issues.append("manifest 损坏，原始副本：\(preserved)")
            // The corrupt bytes were preserved by persistence. Install a valid
            // manifest even when no recoverable JPEG exists, otherwise every
            // launch would repeat corruption recovery indefinitely.
            changed = true
        }

        for key in current.entries.keys.sorted() {
            guard var entry = current.entries[key] else { continue }
            switch entry.original.state {
            case .committingToPhotoLibrary:
                entry.original = replacing(
                    entry.original,
                    state: .needsReconciliation(
                        reason: "上次运行在 Photos 提交与本地确认之间中断；add-only 权限无法核对资产，禁止静默重试。"
                    )
                )
                changed = true
            default:
                break
            }
            if case .committing(let hash, _) = entry.formalEdit {
                entry.formalEdit = .needsReconciliation(
                    sha256: hash,
                    reason: "正式成片的 Photos 提交结果尚未写回本地，禁止静默重复创建。"
                )
                changed = true
            }
            if let path = entry.original.relativePath,
               !entry.original.isCommittedToPhotoLibrary {
                if !persistence.originalExists(relativePath: path) {
                    entry.original = replacing(
                        entry.original,
                        state: .unavailable(reason: "manifest 引用的原图文件缺失")
                    )
                    issues.append("\(entry.original.captureID.uuidString)：manifest 引用文件缺失")
                    changed = true
                } else if let data = try? persistence.originalData(relativePath: path),
                          Self.sha256(data) != entry.original.sha256 {
                    entry.original = replacing(
                        entry.original,
                        state: .unavailable(reason: "原图文件哈希与 manifest 不一致")
                    )
                    issues.append("\(entry.original.captureID.uuidString)：原图哈希不一致")
                    changed = true
                }
            }
            current.entries[key] = entry
        }

        let knownPaths = Set(current.entries.values.compactMap { $0.original.relativePath })
        for relativePath in try persistence.completeOriginalRelativePaths()
            where !knownPaths.contains(relativePath) {
            let orphanState: OriginalRetentionState = manifestWasCorrupted
                ? .needsReconciliation(
                    reason: "本地 manifest 损坏，无法确认原图或正式成片是否已提交到 Photos；已禁止自动重试。"
                )
                : .staged
            guard let recovered = try recoverOrphan(
                relativePath: relativePath,
                state: orphanState
            ) else {
                issues.append("无法从孤立原图文件恢复索引：\(relativePath)")
                continue
            }
            let key = recovered.captureID.uuidString.lowercased()
            if current.entries[key] == nil {
                current.entries[key] = OriginalRetentionManifestEntry(
                    original: recovered,
                    formalEdit: .notRequested
                )
                changed = true
            }
        }

        if changed {
            try persistAndInstall(current)
        } else {
            manifest = current
        }

        didPerformColdLaunchReconciliation = true
        return makeRecoveryReport(current: current, issues: issues)
    }

    /// Read-only state used by normal UI refreshes. It deliberately does not
    /// convert `committing` into `needsReconciliation` and does not scan orphans.
    func recoverySnapshot() throws -> OriginalRetentionRecoveryReport {
        let current = try loadedManifest()
        return makeRecoveryReport(current: current, issues: [])
    }

    /// Removes only local bytes whose original Photos asset has a confirmed
    /// identifier and whose confirmation predates `cutoff`. Unconfirmed states
    /// (staged/permission/failed/committing/reconciliation) are never removed.
    func cleanupConfirmedOriginals(
        olderThan cutoff: Date
    ) throws -> OriginalRetentionCleanupReport {
        var current = try loadedManifest()
        var removed: [UUID] = []
        var issues: [String] = []
        var changed = false

        for key in current.entries.keys.sorted() {
            guard var entry = current.entries[key],
                  let relativePath = entry.original.relativePath,
                  case .committedToPhotoLibrary(_, let committedAt) = entry.original.state,
                  committedAt <= cutoff,
                  isFormalEditSafeForOriginalCleanup(entry.formalEdit)
            else { continue }

            do {
                try persistence.removeOriginal(relativePath: relativePath)
                entry.original = OriginalRetentionReceipt(
                    captureID: entry.original.captureID,
                    sha256: entry.original.sha256,
                    capturedAt: entry.original.capturedAt,
                    relativePath: nil,
                    state: entry.original.state,
                    updatedAt: now()
                )
                current.entries[key] = entry
                removed.append(entry.original.captureID)
                changed = true
            } catch {
                issues.append("\(entry.original.captureID.uuidString)：已确认原图清理失败：\(error.localizedDescription)")
            }
        }

        if changed { try persistAndInstall(current) }
        return OriginalRetentionCleanupReport(
            removedCaptureIDs: removed,
            issues: issues
        )
    }

    private func makeRecoveryReport(
        current: OriginalRetentionManifest,
        issues: [String]
    ) -> OriginalRetentionRecoveryReport {
        let entries = Array(current.entries.values)
        let recoverable = entries.compactMap { entry -> OriginalRetentionReceipt? in
            let receipt = entry.original
            guard receipt.hasRecoverableOriginal else { return nil }
            if !receipt.isCommittedToPhotoLibrary { return receipt }
            if case .needsReconciliation = entry.formalEdit,
               receipt.relativePath != nil {
                return receipt
            }
            return nil
        }.sorted { $0.capturedAt > $1.capturedAt }
        let reconciliation = entries.compactMap { entry -> OriginalRetentionReceipt? in
            if case .needsReconciliation = entry.original.state {
                return entry.original
            }
            if case .needsReconciliation = entry.formalEdit {
                return entry.original
            }
            return nil
        }
        return OriginalRetentionRecoveryReport(
            recoverableOriginals: recoverable,
            needsReconciliation: reconciliation,
            issues: issues
        )
    }

    private func isFormalEditSafeForOriginalCleanup(
        _ state: RetainedPhotoAssetCommitState
    ) -> Bool {
        switch state {
        case .committing, .needsReconciliation:
            return false
        case .notRequested, .committed, .saveFailed:
            return true
        }
    }

    func markAwaitingPhotoLibraryPermission(captureID: UUID) throws -> OriginalRetentionReceipt {
        try updateOriginal(captureID: captureID) { receipt in
            replacing(receipt, state: .awaitingPhotoLibraryPermission)
        }
    }

    func recordOriginalValidationFailure(
        captureID: UUID,
        reason: String
    ) throws -> OriginalRetentionReceipt {
        try updateOriginal(captureID: captureID) { receipt in
            replacing(
                receipt,
                state: .saveFailed(reason: "integrity-validation: \(reason)")
            )
        }
    }

    func reserveCommit(
        captureID: UUID,
        kind: RetainedPhotoAssetKind,
        sha256: String
    ) throws -> PhotoAssetCommitReservation {
        var current = try loadedManifest()
        let key = captureID.uuidString.lowercased()
        guard var entry = current.entries[key] else {
            throw OriginalRetentionError.unknownCapture
        }

        switch kind {
        case .original:
            guard entry.original.sha256 == sha256 else {
                throw OriginalRetentionError.captureIDCollision
            }
            switch entry.original.state {
            case .committedToPhotoLibrary(let identifier, _):
                return .alreadyCommitted(assetIdentifier: identifier)
            case .committingToPhotoLibrary:
                return .inProgress
            case .needsReconciliation(let reason):
                return .needsReconciliation(reason: reason)
            case .unavailable(let reason):
                return .needsReconciliation(reason: reason)
            case .staged, .awaitingPhotoLibraryPermission, .saveFailed:
                entry.original = replacing(
                    entry.original,
                    state: .committingToPhotoLibrary(startedAt: now())
                )
            case .memoryOnly:
                throw OriginalRetentionError.unknownCapture
            }
        case .formalEdit:
            switch entry.formalEdit {
            case .notRequested, .saveFailed:
                entry.formalEdit = .committing(sha256: sha256, startedAt: now())
            case .committing:
                return .inProgress
            case .committed(let previousHash, let identifier, _):
                guard previousHash == sha256 else {
                    throw OriginalRetentionError.editedDataChanged
                }
                return .alreadyCommitted(assetIdentifier: identifier)
            case .needsReconciliation(let previousHash, let reason):
                guard previousHash == sha256 else {
                    throw OriginalRetentionError.editedDataChanged
                }
                return .needsReconciliation(reason: reason)
            }
        }

        current.entries[key] = entry
        try persistAndInstall(current)
        return .create
    }

    func markCommitSucceeded(
        captureID: UUID,
        kind: RetainedPhotoAssetKind,
        sha256: String,
        assetIdentifier: String
    ) throws -> OriginalRetentionReceipt {
        var current = try loadedManifest()
        let key = captureID.uuidString.lowercased()
        guard var entry = current.entries[key] else {
            throw OriginalRetentionError.unknownCapture
        }
        let committedAt = now()
        switch kind {
        case .original:
            guard entry.original.sha256 == sha256 else {
                throw OriginalRetentionError.captureIDCollision
            }
            entry.original = replacing(
                entry.original,
                state: .committedToPhotoLibrary(
                    assetIdentifier: assetIdentifier,
                    committedAt: committedAt
                )
            )
        case .formalEdit:
            entry.formalEdit = .committed(
                sha256: sha256,
                assetIdentifier: assetIdentifier,
                committedAt: committedAt
            )
        }
        current.entries[key] = entry
        try persistAndInstall(current)
        return entry.original
    }

    func markCommitFailed(
        captureID: UUID,
        kind: RetainedPhotoAssetKind,
        sha256: String,
        reason: String
    ) throws -> OriginalRetentionReceipt {
        var current = try loadedManifest()
        let key = captureID.uuidString.lowercased()
        guard var entry = current.entries[key] else {
            throw OriginalRetentionError.unknownCapture
        }
        switch kind {
        case .original:
            entry.original = replacing(
                entry.original,
                state: .saveFailed(reason: reason)
            )
        case .formalEdit:
            entry.formalEdit = .saveFailed(sha256: sha256, reason: reason)
        }
        current.entries[key] = entry
        try persistAndInstall(current)
        return entry.original
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func loadedManifest() throws -> OriginalRetentionManifest {
        if let manifest { return manifest }
        do {
            let loaded: OriginalRetentionManifest
            switch try persistence.loadManifest() {
            case .missing:
                loaded = .empty
            case .loaded(let stored):
                loaded = stored
            case .corrupted(let preservedCopyName):
                loaded = .empty
                manifestWasCorrupted = true
                preservedCorruptManifestName = preservedCopyName
            }
            manifest = loaded
            return loaded
        } catch {
            throw OriginalRetentionError.manifestUnavailable(error.localizedDescription)
        }
    }

    private func persistAndInstall(_ candidate: OriginalRetentionManifest) throws {
        do {
            try persistence.persistManifest(candidate)
            manifest = candidate
        } catch {
            throw OriginalRetentionError.manifestUnavailable(error.localizedDescription)
        }
    }

    private func updateOriginal(
        captureID: UUID,
        transform: (OriginalRetentionReceipt) -> OriginalRetentionReceipt
    ) throws -> OriginalRetentionReceipt {
        var current = try loadedManifest()
        let key = captureID.uuidString.lowercased()
        guard var entry = current.entries[key] else {
            throw OriginalRetentionError.unknownCapture
        }
        entry.original = transform(entry.original)
        current.entries[key] = entry
        try persistAndInstall(current)
        return entry.original
    }

    private func replacing(
        _ receipt: OriginalRetentionReceipt,
        state: OriginalRetentionState
    ) -> OriginalRetentionReceipt {
        OriginalRetentionReceipt(
            captureID: receipt.captureID,
            sha256: receipt.sha256,
            capturedAt: receipt.capturedAt,
            relativePath: receipt.relativePath,
            state: state,
            updatedAt: now()
        )
    }

    private func recoverOrphan(
        relativePath: String,
        state: OriginalRetentionState
    ) throws -> OriginalRetentionReceipt? {
        let filename = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        let components = filename.components(separatedBy: "__")
        guard components.count == 3,
              let captureID = UUID(uuidString: components[0]),
              let timestamp = Int64(components[1])
        else { return nil }
        let data = try persistence.originalData(relativePath: relativePath)
        let actualHash = Self.sha256(data)
        guard actualHash == components[2] else { return nil }
        return OriginalRetentionReceipt(
            captureID: captureID,
            sha256: actualHash,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000),
            relativePath: relativePath,
            state: state,
            updatedAt: now()
        )
    }
}

enum PhotoLibraryWriteAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
}

struct PhotoLibraryAssetPayload: Equatable, Sendable {
    let data: Data
    let filename: String
}

protocol PhotoLibraryAssetWriting: Sendable {
    func authorizationStatus() async -> PhotoLibraryWriteAuthorization
    func requestAuthorization() async -> PhotoLibraryWriteAuthorization
    func createAsset(_ payload: PhotoLibraryAssetPayload) async throws -> String
}

struct CapturedPhotoSaveRequest: Equatable, Sendable {
    let captureID: UUID
    let capturedAt: Date
    let originalData: Data
    let originalReceipt: OriginalRetentionReceipt?
    let approvedEditedData: Data?
}

struct PhotoLibrarySaveOutcome: Equatable, Sendable {
    let originalReceipt: OriginalRetentionReceipt
    let originalAssetIdentifier: String
    let editedAssetIdentifier: String?
    let originalWasAlreadySaved: Bool
    let editedWasAlreadySaved: Bool
}

enum PhotoSaveCoordinatorError: LocalizedError, Equatable {
    case permissionDenied
    case originalNotSafelyStaged(String)
    case saveInProgress
    case needsReconciliation(String)
    case photoLibrarySaveFailed(String)
    case confirmationUnknown(String)
    case activeRequestMismatch(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "需要相册写入权限才能保存；原图安全副本仍保留在 App 内。"
        case .originalNotSafelyStaged(let reason):
            return "原图尚未建立可靠安全副本：\(reason)"
        case .saveInProgress:
            return "这张照片正在保存，请稍后再试。"
        case .needsReconciliation(let reason):
            return "上次相册事务结果无法在 add-only 权限下确认。为避免重复保存，已停止自动重试：\(reason)"
        case .photoLibrarySaveFailed(let reason):
            return "相册保存失败，原图安全副本仍保留：\(reason)"
        case .confirmationUnknown(let reason):
            return "系统可能已经保存照片，但本地确认失败。已保留原图并停止自动重试：\(reason)"
        case .activeRequestMismatch(let reason):
            return "同一拍摄记录正在保存另一组内容，已拒绝合并请求：\(reason)"
        }
    }
}

/// A writer uses this error only when Photos may already contain the asset but
/// its identifier could not be confirmed. The manifest intentionally remains
/// in `committing` so launch reconciliation will block silent retries.
enum PhotoLibraryAssetWriterError: LocalizedError {
    case commitConfirmationUnknown(String)

    var errorDescription: String? {
        switch self {
        case .commitConfirmationUnknown(let reason):
            return reason
        }
    }
}

actor PhotoSaveCoordinator {
    private struct SaveIdentity: Equatable, Sendable {
        let originalSHA256: String
        let editedSHA256: String?
        let receiptCaptureID: UUID?
        let receiptSHA256: String?
        let receiptRelativePath: String?
    }

    private struct ActiveSave {
        let identity: SaveIdentity
        let task: Task<PhotoLibrarySaveOutcome, Error>
    }

    private let store: OriginalPhotoRetentionStore
    private let writer: any PhotoLibraryAssetWriting
    private var activeSaves: [UUID: ActiveSave] = [:]

    init(
        store: OriginalPhotoRetentionStore,
        writer: any PhotoLibraryAssetWriting
    ) {
        self.store = store
        self.writer = writer
    }

    func save(_ request: CapturedPhotoSaveRequest) async throws -> PhotoLibrarySaveOutcome {
        let identity = SaveIdentity(
            originalSHA256: OriginalPhotoRetentionStore.sha256(request.originalData),
            editedSHA256: request.approvedEditedData.map {
                OriginalPhotoRetentionStore.sha256($0)
            },
            receiptCaptureID: request.originalReceipt?.captureID,
            receiptSHA256: request.originalReceipt?.sha256,
            receiptRelativePath: request.originalReceipt?.relativePath
        )
        if let active = activeSaves[request.captureID] {
            guard active.identity == identity else {
                throw PhotoSaveCoordinatorError.activeRequestMismatch(
                    "原图、正式成片或 retention receipt 与进行中的请求不同"
                )
            }
            return try await active.task.value
        }

        let task = Task { try await self.performSave(request) }
        activeSaves[request.captureID] = ActiveSave(identity: identity, task: task)
        do {
            let result = try await task.value
            activeSaves[request.captureID] = nil
            return result
        } catch {
            activeSaves[request.captureID] = nil
            throw error
        }
    }

    private func performSave(
        _ request: CapturedPhotoSaveRequest
    ) async throws -> PhotoLibrarySaveOutcome {
        let initialReceipt: OriginalRetentionReceipt
        do {
            if let supplied = request.originalReceipt {
                initialReceipt = supplied
            } else {
                initialReceipt = try await store.stageOriginal(
                    data: request.originalData,
                    captureID: request.captureID,
                    capturedAt: request.capturedAt
                )
            }
        } catch {
            throw PhotoSaveCoordinatorError.originalNotSafelyStaged(error.localizedDescription)
        }

        let validated: ValidatedOriginalForSave
        do {
            validated = try await store.validateOriginalForSave(
                captureID: request.captureID,
                proposedData: request.originalData,
                suppliedReceipt: initialReceipt
            )
        } catch {
            _ = try? await store.recordOriginalValidationFailure(
                captureID: request.captureID,
                reason: error.localizedDescription
            )
            throw PhotoSaveCoordinatorError.originalNotSafelyStaged(error.localizedDescription)
        }
        let receipt = validated.receipt

        let authorization = await resolvedAuthorization()
        guard authorization == .authorized else {
            _ = try? await store.markAwaitingPhotoLibraryPermission(
                captureID: request.captureID
            )
            throw PhotoSaveCoordinatorError.permissionDenied
        }

        let stamp = Int(request.capturedAt.timeIntervalSince1970)
        let originalResult: (identifier: String, alreadySaved: Bool)
        if let confirmedIdentifier = validated.confirmedAssetIdentifier {
            originalResult = (confirmedIdentifier, true)
        } else {
            guard let stagedData = validated.stagedData else {
                throw PhotoSaveCoordinatorError.originalNotSafelyStaged(
                    "未提交原图缺少可验证的私有暂存字节"
                )
            }
            originalResult = try await saveTrackedAsset(
                captureID: request.captureID,
                kind: .original,
                sha256: receipt.sha256,
                payload: PhotoLibraryAssetPayload(
                    data: stagedData,
                    filename: "XiaoSuCamera_\(stamp)_\(request.captureID.uuidString)_Original.jpg"
                )
            )
        }
        let currentReceipt = try await store.currentReceipt(captureID: request.captureID)
            ?? receipt

        var editedIdentifier: String?
        var editedAlreadySaved = false
        if let editedData = request.approvedEditedData, !editedData.isEmpty {
            let editedHash = OriginalPhotoRetentionStore.sha256(editedData)
            let editedResult = try await saveTrackedAsset(
                captureID: request.captureID,
                kind: .formalEdit,
                sha256: editedHash,
                payload: PhotoLibraryAssetPayload(
                    data: editedData,
                    filename: "XiaoSuCamera_\(stamp)_\(request.captureID.uuidString)_AI_Edited.jpg"
                )
            )
            editedIdentifier = editedResult.identifier
            editedAlreadySaved = editedResult.alreadySaved
        }

        return PhotoLibrarySaveOutcome(
            originalReceipt: currentReceipt,
            originalAssetIdentifier: originalResult.identifier,
            editedAssetIdentifier: editedIdentifier,
            originalWasAlreadySaved: originalResult.alreadySaved,
            editedWasAlreadySaved: editedAlreadySaved
        )
    }

    private func resolvedAuthorization() async -> PhotoLibraryWriteAuthorization {
        let current = await writer.authorizationStatus()
        if current == .notDetermined {
            return await writer.requestAuthorization()
        }
        return current
    }

    private func saveTrackedAsset(
        captureID: UUID,
        kind: RetainedPhotoAssetKind,
        sha256: String,
        payload: PhotoLibraryAssetPayload
    ) async throws -> (identifier: String, alreadySaved: Bool) {
        let reservation = try await store.reserveCommit(
            captureID: captureID,
            kind: kind,
            sha256: sha256
        )
        switch reservation {
        case .alreadyCommitted(let identifier):
            return (identifier, true)
        case .inProgress:
            throw PhotoSaveCoordinatorError.saveInProgress
        case .needsReconciliation(let reason):
            throw PhotoSaveCoordinatorError.needsReconciliation(reason)
        case .create:
            break
        }

        let identifier: String
        do {
            identifier = try await writer.createAsset(payload)
        } catch {
            if let writerError = error as? PhotoLibraryAssetWriterError,
               case .commitConfirmationUnknown(let reason) = writerError {
                throw PhotoSaveCoordinatorError.confirmationUnknown(reason)
            }
            do {
                _ = try await store.markCommitFailed(
                    captureID: captureID,
                    kind: kind,
                    sha256: sha256,
                    reason: error.localizedDescription
                )
            } catch {
                throw PhotoSaveCoordinatorError.confirmationUnknown(error.localizedDescription)
            }
            throw PhotoSaveCoordinatorError.photoLibrarySaveFailed(error.localizedDescription)
        }

        do {
            _ = try await store.markCommitSucceeded(
                captureID: captureID,
                kind: kind,
                sha256: sha256,
                assetIdentifier: identifier
            )
        } catch {
            throw PhotoSaveCoordinatorError.confirmationUnknown(error.localizedDescription)
        }
        return (identifier, false)
    }
}
