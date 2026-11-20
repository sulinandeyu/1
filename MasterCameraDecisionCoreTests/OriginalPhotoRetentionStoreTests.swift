import Foundation
import XCTest
@testable import MasterCameraDecisionCore

final class OriginalPhotoRetentionStoreTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testDiagnosticImportsAreExcludedFromNewCaptureRetention() {
        XCTAssertFalse(
            OriginalRetentionPolicy.shouldStageNewCapture(isDiagnosticImport: true)
        )
        XCTAssertTrue(
            OriginalRetentionPolicy.shouldStageNewCapture(isDiagnosticImport: false)
        )
    }

    func testStagePreservesBytesHashAndIsIdempotent() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let captureID = UUID()
        let bytes = Data("unaltered-jpeg-bytes".utf8)

        let first = try await store.stageOriginal(
            data: bytes,
            captureID: captureID,
            capturedAt: capturedAt
        )
        let second = try await store.stageOriginal(
            data: bytes,
            captureID: captureID,
            capturedAt: capturedAt
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sha256, OriginalPhotoRetentionStore.sha256(bytes))
        let restored = try await store.originalData(for: first)
        XCTAssertEqual(restored, bytes)
        XCTAssertEqual(persistence.stageWriteCount, 1)
    }

    func testStagedOriginalSurvivesProcessingFailureAndRestart() async throws {
        let persistence = MemoryRetentionPersistence()
        let captureID = UUID()
        let bytes = Data("processing-will-fail-after-this".utf8)
        let firstStore = OriginalPhotoRetentionStore(persistence: persistence)
        _ = try await firstStore.stageOriginal(
            data: bytes,
            captureID: captureID,
            capturedAt: capturedAt
        )

        let relaunchedStore = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunchedStore.reconcileAfterColdLaunch()

        XCTAssertEqual(report.recoverableOriginals.map(\.captureID), [captureID])
        let restored = try await relaunchedStore.originalData(
            for: report.recoverableOriginals[0]
        )
        XCTAssertEqual(restored, bytes)
    }

    func testPermissionDeniedKeepsRecoverableOriginal() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .denied)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest()

        do {
            _ = try await coordinator.save(request)
            XCTFail("Expected permission denial")
        } catch let error as PhotoSaveCoordinatorError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let receipt = try await store.currentReceipt(captureID: request.captureID)
        XCTAssertEqual(receipt?.state, .awaitingPhotoLibraryPermission)
        XCTAssertTrue(receipt?.hasRecoverableOriginal == true)
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 0)
    }

    func testPhotoLibraryFailureKeepsOriginalAndRecordsFailure() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized, failCreate: true)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest()

        do {
            _ = try await coordinator.save(request)
            XCTFail("Expected Photos failure")
        } catch let error as PhotoSaveCoordinatorError {
            guard case .photoLibrarySaveFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        let current = try await store.currentReceipt(captureID: request.captureID)
        let receipt = try XCTUnwrap(current)
        guard case .saveFailed = receipt.state else {
            return XCTFail("Expected saveFailed, got \(receipt.state)")
        }
        let restored = try await store.originalData(for: receipt)
        XCTAssertEqual(restored, request.originalData)
    }

    func testRepeatedSaveDoesNotCreateDuplicateAssets() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest(edited: Data("approved-formal-b".utf8))

        let first = try await coordinator.save(request)
        let second = try await coordinator.save(request)

        XCTAssertFalse(first.originalWasAlreadySaved)
        XCTAssertFalse(first.editedWasAlreadySaved)
        XCTAssertTrue(second.originalWasAlreadySaved)
        XCTAssertTrue(second.editedWasAlreadySaved)
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testFormalBBytesPassThroughStorageWithoutMutation() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let edited = Data((0..<1_024).map { UInt8(($0 * 17) % 253) })
        let request = makeRequest(edited: edited)

        _ = try await coordinator.save(request)
        let payloads = await writer.createdPayloads()

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].data, request.originalData)
        XCTAssertEqual(payloads[1].data, edited)
    }

    func testConcurrentSaveRequestsAreSerializedAndIdempotent() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized, createDelayNanoseconds: 30_000_000)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest()

        async let first = coordinator.save(request)
        async let second = coordinator.save(request)
        let (firstResult, secondResult) = try await (first, second)
        let results = [firstResult, secondResult]

        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(
            Set(results.map(\.originalAssetIdentifier)).count,
            1
        )
    }

    func testConcurrentSameCaptureWithDifferentOriginalIsRejected() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(
            status: .authorized,
            createDelayNanoseconds: 100_000_000
        )
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let firstRequest = makeRequest()
        let conflicting = CapturedPhotoSaveRequest(
            captureID: firstRequest.captureID,
            capturedAt: firstRequest.capturedAt,
            originalData: Data("conflicting-original".utf8),
            originalReceipt: nil,
            approvedEditedData: nil
        )

        let firstTask = Task { try await coordinator.save(firstRequest) }
        await writer.waitUntilCreateCount(1)
        do {
            _ = try await coordinator.save(conflicting)
            XCTFail("Different original must not share active save")
        } catch let error as PhotoSaveCoordinatorError {
            guard case .activeRequestMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }
        _ = try await firstTask.value
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 1)
    }

    func testConcurrentSameCaptureWithDifferentFormalEditIsRejected() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(
            status: .authorized,
            createDelayNanoseconds: 100_000_000
        )
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let firstRequest = makeRequest(edited: Data("formal-b-one".utf8))
        let conflicting = CapturedPhotoSaveRequest(
            captureID: firstRequest.captureID,
            capturedAt: firstRequest.capturedAt,
            originalData: firstRequest.originalData,
            originalReceipt: nil,
            approvedEditedData: Data("formal-b-two".utf8)
        )

        let firstTask = Task { try await coordinator.save(firstRequest) }
        await writer.waitUntilCreateCount(1)
        do {
            _ = try await coordinator.save(conflicting)
            XCTFail("Different formal edit must not share active save")
        } catch let error as PhotoSaveCoordinatorError {
            guard case .activeRequestMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }
        _ = try await firstTask.value
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testRoutineRefreshDoesNotReconcileInFlightOriginalCommit() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        _ = try await store.reconcileAfterColdLaunch()
        let writer = FakePhotoLibraryWriter(
            status: .authorized,
            blockCreationNumber: 1
        )
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest()

        let saveTask = Task { try await coordinator.save(request) }
        await writer.waitUntilCreateCount(1)
        let duringSave = try await store.recoverySnapshot()
        let currentReceipt = try await store.currentReceipt(captureID: request.captureID)
        await writer.releaseBlockedCreate()
        _ = try await saveTask.value
        let receipt = try XCTUnwrap(currentReceipt)

        guard case .committingToPhotoLibrary = receipt.state else {
            return XCTFail("Routine refresh changed in-flight original state: \(receipt.state)")
        }
        XCTAssertTrue(duringSave.needsReconciliation.isEmpty)
    }

    func testRoutineRefreshDoesNotReconcileInFlightFormalEditCommit() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        _ = try await store.reconcileAfterColdLaunch()
        let writer = FakePhotoLibraryWriter(
            status: .authorized,
            blockCreationNumber: 2
        )
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest(edited: Data("formal-b".utf8))

        let saveTask = Task { try await coordinator.save(request) }
        await writer.waitUntilCreateCount(2)
        _ = try await store.recoverySnapshot()
        let manifestSnapshot = persistence.manifestSnapshot()
        await writer.releaseBlockedCreate()
        _ = try await saveTask.value
        let manifest = try XCTUnwrap(manifestSnapshot)
        let entry = try XCTUnwrap(
            manifest.entries[request.captureID.uuidString.lowercased()]
        )

        guard case .committing = entry.formalEdit else {
            return XCTFail("Routine refresh changed in-flight formal edit state")
        }
    }

    func testCorruptManifestAfterCommittedOriginalRequiresReconciliation() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let request = makeRequest()
        _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(request)
        persistence.simulateCorruptManifest()

        let relaunched = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunched.reconcileAfterColdLaunch()
        let recovered = try XCTUnwrap(report.needsReconciliation.first)
        guard case .needsReconciliation = recovered.state else {
            return XCTFail("Corrupt committed original became auto-saveable")
        }

        let retryWriter = FakePhotoLibraryWriter(status: .authorized)
        let retry = PhotoSaveCoordinator(store: relaunched, writer: retryWriter)
        let retryRequest = requestWithReceipt(request, receipt: recovered)
        do {
            _ = try await retry.save(retryRequest)
            XCTFail("Corrupt-manifest recovery must not auto-retry")
        } catch { }
        let retryCount = await retryWriter.createCount()
        XCTAssertEqual(retryCount, 0)
    }

    func testCorruptManifestAfterCommittedFormalEditRequiresReconciliation() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let request = makeRequest(edited: Data("committed-formal-b".utf8))
        _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(request)
        persistence.simulateCorruptManifest()

        let relaunched = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunched.reconcileAfterColdLaunch()
        XCTAssertEqual(report.needsReconciliation.count, 1)
        guard case .needsReconciliation = report.needsReconciliation[0].state else {
            return XCTFail("Lost formal-edit state must not become staged")
        }
    }

    func testCorruptManifestDuringCommitRequiresReconciliation() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(
            status: .authorized,
            confirmationUnknown: true
        )
        let request = makeRequest()
        do {
            _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(request)
            XCTFail("Expected unknown Photos result")
        } catch { }
        persistence.simulateCorruptManifest()

        let relaunched = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunched.reconcileAfterColdLaunch()
        XCTAssertEqual(report.needsReconciliation.count, 1)
        guard case .needsReconciliation = report.needsReconciliation[0].state else {
            return XCTFail("Lost committing state must not become staged")
        }
    }

    func testMismatchedOriginalBytesCannotCreatePhotosAsset() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let request = makeRequest()
        let receipt = try await store.stageOriginal(
            data: request.originalData,
            captureID: request.captureID,
            capturedAt: request.capturedAt
        )
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let tampered = CapturedPhotoSaveRequest(
            captureID: request.captureID,
            capturedAt: request.capturedAt,
            originalData: Data("different-original".utf8),
            originalReceipt: receipt,
            approvedEditedData: nil
        )

        do {
            _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(tampered)
            XCTFail("Mismatched bytes must be rejected")
        } catch { }
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 0)
        let current = try await store.currentReceipt(captureID: request.captureID)
        let failedReceipt = try XCTUnwrap(current)
        guard case .saveFailed(let reason) = failedReceipt.state else {
            return XCTFail("Integrity failure evidence was not persisted")
        }
        XCTAssertTrue(reason.contains("integrity-validation"))
    }

    func testForgedReceiptCannotBypassManifestValidation() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let request = makeRequest()
        let receipt = try await store.stageOriginal(
            data: request.originalData,
            captureID: request.captureID,
            capturedAt: request.capturedAt
        )
        let forged = OriginalRetentionReceipt(
            captureID: UUID(),
            sha256: receipt.sha256,
            capturedAt: receipt.capturedAt,
            relativePath: receipt.relativePath,
            state: receipt.state,
            updatedAt: receipt.updatedAt
        )
        let writer = FakePhotoLibraryWriter(status: .authorized)

        do {
            _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(
                requestWithReceipt(request, receipt: forged)
            )
            XCTFail("Forged receipt must be rejected")
        } catch { }
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 0)
        let current = try await store.currentReceipt(captureID: request.captureID)
        let failedReceipt = try XCTUnwrap(current)
        guard case .saveFailed(let reason) = failedReceipt.state else {
            return XCTFail("Forged receipt evidence was not persisted")
        }
        XCTAssertTrue(reason.contains("integrity-validation"))
    }

    func testCorruptStagedFileCannotBeMarkedSaved() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let request = makeRequest()
        let receipt = try await store.stageOriginal(
            data: request.originalData,
            captureID: request.captureID,
            capturedAt: request.capturedAt
        )
        let path = try XCTUnwrap(receipt.relativePath)
        persistence.replaceOriginal(relativePath: path, with: Data("corrupt".utf8))
        let writer = FakePhotoLibraryWriter(status: .authorized)

        do {
            _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(
                requestWithReceipt(request, receipt: receipt)
            )
            XCTFail("Corrupt staged file must be rejected")
        } catch { }
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 0)
        let current = try await store.currentReceipt(captureID: request.captureID)
        let failedReceipt = try XCTUnwrap(current)
        guard case .saveFailed(let reason) = failedReceipt.state else {
            return XCTFail("Corrupt file evidence was not persisted")
        }
        XCTAssertTrue(reason.contains("integrity-validation"))
    }

    func testCleanupDeletesOnlyOldConfirmedLocalOriginals() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence, now: { now })
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let committedRequest = makeRequest()
        _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(committedRequest)
        let pendingRequest = makeRequest()
        let pending = try await store.stageOriginal(
            data: pendingRequest.originalData,
            captureID: pendingRequest.captureID,
            capturedAt: pendingRequest.capturedAt
        )

        let cleanup = try await store.cleanupConfirmedOriginals(
            olderThan: now.addingTimeInterval(1)
        )

        XCTAssertEqual(cleanup.removedCaptureIDs, [committedRequest.captureID])
        let committed = try await store.currentReceipt(captureID: committedRequest.captureID)
        XCTAssertNil(committed?.relativePath)
        let pendingData = try await store.originalData(for: pending)
        XCTAssertEqual(pendingData, pendingRequest.originalData)
    }

    func testCleanupProtectsAwaitingPermissionAndFormalReconciliation() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence, now: { now })

        let awaitingRequest = makeRequest()
        _ = try await store.stageOriginal(
            data: awaitingRequest.originalData,
            captureID: awaitingRequest.captureID,
            capturedAt: awaitingRequest.capturedAt
        )
        _ = try await store.markAwaitingPhotoLibraryPermission(
            captureID: awaitingRequest.captureID
        )

        let formalRequest = makeRequest(edited: Data("formal-needs-reconciliation".utf8))
        let formalReceipt = try await store.stageOriginal(
            data: formalRequest.originalData,
            captureID: formalRequest.captureID,
            capturedAt: formalRequest.capturedAt
        )
        _ = try await store.markCommitSucceeded(
            captureID: formalRequest.captureID,
            kind: .original,
            sha256: formalReceipt.sha256,
            assetIdentifier: "confirmed-original"
        )
        _ = try await store.reserveCommit(
            captureID: formalRequest.captureID,
            kind: .formalEdit,
            sha256: OriginalPhotoRetentionStore.sha256(
                try XCTUnwrap(formalRequest.approvedEditedData)
            )
        )

        let relaunched = OriginalPhotoRetentionStore(persistence: persistence, now: { now })
        let recovery = try await relaunched.reconcileAfterColdLaunch()
        XCTAssertEqual(recovery.needsReconciliation.count, 1)
        let cleanup = try await relaunched.cleanupConfirmedOriginals(
            olderThan: now.addingTimeInterval(1)
        )

        XCTAssertTrue(cleanup.removedCaptureIDs.isEmpty)
        let awaiting = try await relaunched.currentReceipt(captureID: awaitingRequest.captureID)
        let formal = try await relaunched.currentReceipt(captureID: formalRequest.captureID)
        XCTAssertNotNil(awaiting?.relativePath)
        XCTAssertNotNil(formal?.relativePath)
    }

    func testConfirmedOriginalAfterCleanupIsNotRecreatedAndFormalBCanSave() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence, now: { now })
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let originalRequest = makeRequest()
        let originalOutcome = try await coordinator.save(originalRequest)
        let staleReceipt = originalOutcome.originalReceipt
        _ = try await store.cleanupConfirmedOriginals(
            olderThan: now.addingTimeInterval(1)
        )
        let cleaned = try await store.currentReceipt(captureID: originalRequest.captureID)
        XCTAssertNil(cleaned?.relativePath)

        let editedData = Data("approved-formal-b-after-cleanup".utf8)
        let editedRequest = CapturedPhotoSaveRequest(
            captureID: originalRequest.captureID,
            capturedAt: originalRequest.capturedAt,
            originalData: originalRequest.originalData,
            originalReceipt: staleReceipt,
            approvedEditedData: editedData
        )
        let editedOutcome = try await coordinator.save(editedRequest)
        let repeatedOutcome = try await coordinator.save(editedRequest)

        XCTAssertTrue(editedOutcome.originalWasAlreadySaved)
        XCTAssertFalse(editedOutcome.editedWasAlreadySaved)
        XCTAssertTrue(repeatedOutcome.originalWasAlreadySaved)
        XCTAssertTrue(repeatedOutcome.editedWasAlreadySaved)
        let payloads = await writer.createdPayloads()
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].data, originalRequest.originalData)
        XCTAssertEqual(payloads[1].data, editedData)
    }

    func testUnsubmittedOriginalWithoutPrivateFileStillFailsIntegrityCheck() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let request = makeRequest()
        let receipt = try await store.stageOriginal(
            data: request.originalData,
            captureID: request.captureID,
            capturedAt: request.capturedAt
        )
        let path = try XCTUnwrap(receipt.relativePath)
        try persistence.removeOriginal(relativePath: path)
        let writer = FakePhotoLibraryWriter(status: .authorized)

        do {
            _ = try await PhotoSaveCoordinator(store: store, writer: writer).save(
                requestWithReceipt(request, receipt: receipt)
            )
            XCTFail("Unsubmitted original without staged bytes must fail")
        } catch { }
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 0)
    }

    func testPhotosCommitWithoutManifestConfirmationRequiresReconciliation() async throws {
        let persistence = MemoryRetentionPersistence()
        // stage manifest = 1, committing manifest = 2, confirmation manifest = 3
        persistence.failPersistCall = 3
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(status: .authorized)
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest()

        do {
            _ = try await coordinator.save(request)
            XCTFail("Expected local confirmation failure")
        } catch let error as PhotoSaveCoordinatorError {
            guard case .confirmationUnknown = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }
        let creationCount = await writer.createCount()
        XCTAssertEqual(creationCount, 1)

        persistence.failPersistCall = nil
        let relaunchedStore = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunchedStore.reconcileAfterColdLaunch()
        XCTAssertEqual(report.needsReconciliation.count, 1)
        guard case .needsReconciliation = report.needsReconciliation[0].state else {
            return XCTFail("Expected reconciliation state")
        }
    }

    func testUnknownWriterConfirmationLeavesCommitPending() async throws {
        let persistence = MemoryRetentionPersistence()
        let store = OriginalPhotoRetentionStore(persistence: persistence)
        let writer = FakePhotoLibraryWriter(
            status: .authorized,
            confirmationUnknown: true
        )
        let coordinator = PhotoSaveCoordinator(store: store, writer: writer)
        let request = makeRequest()

        do {
            _ = try await coordinator.save(request)
            XCTFail("Expected unknown confirmation")
        } catch let error as PhotoSaveCoordinatorError {
            guard case .confirmationUnknown = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        let relaunchedStore = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunchedStore.reconcileAfterColdLaunch()
        XCTAssertEqual(report.needsReconciliation.count, 1)
    }

    func testStorageFailureDoesNotClaimPersistentRetention() async throws {
        let persistence = MemoryRetentionPersistence()
        persistence.failStage = true
        let store = OriginalPhotoRetentionStore(persistence: persistence)

        do {
            _ = try await store.stageOriginal(
                data: Data("jpeg".utf8),
                captureID: UUID(),
                capturedAt: capturedAt
            )
            XCTFail("Expected storage failure")
        } catch {
            let report = try await store.reconcileAfterColdLaunch()
            XCTAssertNil(report.recoverableOriginals.first)
        }
    }

    func testManifestInterruptionRecoversCompleteOrphanFile() async throws {
        let persistence = MemoryRetentionPersistence()
        persistence.failPersistCall = 1
        let captureID = UUID()
        let bytes = Data("complete-before-manifest-interruption".utf8)
        let store = OriginalPhotoRetentionStore(persistence: persistence)

        do {
            _ = try await store.stageOriginal(
                data: bytes,
                captureID: captureID,
                capturedAt: capturedAt
            )
            XCTFail("Expected manifest interruption")
        } catch { }

        persistence.failPersistCall = nil
        let relaunchedStore = OriginalPhotoRetentionStore(persistence: persistence)
        let report = try await relaunchedStore.reconcileAfterColdLaunch()
        XCTAssertEqual(report.recoverableOriginals.map(\.captureID), [captureID])
        let restored = try await relaunchedStore.originalData(
            for: report.recoverableOriginals[0]
        )
        XCTAssertEqual(restored, bytes)
    }

    func testFilePersistencePreservesExactBytesAcrossStoreInstances() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("original-retention-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<2_048).map { UInt8($0 % 251) })
        let captureID = UUID()
        let first = OriginalPhotoRetentionStore(
            persistence: FileOriginalRetentionPersistence(rootURL: root)
        )
        let receipt = try await first.stageOriginal(
            data: bytes,
            captureID: captureID,
            capturedAt: capturedAt
        )

        let second = OriginalPhotoRetentionStore(
            persistence: FileOriginalRetentionPersistence(rootURL: root)
        )
        let report = try await second.reconcileAfterColdLaunch()
        XCTAssertEqual(report.recoverableOriginals.map(\.captureID), [captureID])
        let restored = try await second.originalData(for: receipt)
        XCTAssertEqual(restored, bytes)
    }

    func testFilePersistencePreservesCorruptManifestEvidenceAndOriginalJPEG() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("original-corrupt-manifest-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = FileOriginalRetentionPersistence(rootURL: root)
        let data = Data("verified-original-jpeg".utf8)
        let path = "evidence.jpg"
        try persistence.stageVerifiedOriginal(
            data: data,
            relativePath: path,
            expectedSHA256: OriginalPhotoRetentionStore.sha256(data)
        )
        try persistence.persistManifest(.empty)
        try Data("{not-valid-json".utf8).write(
            to: root.appendingPathComponent("manifest.json")
        )

        let result = try persistence.loadManifest()
        guard case .corrupted(let preservedName) = result else {
            return XCTFail("Expected corrupt manifest result")
        }
        let name = try XCTUnwrap(preservedName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Recovery").appendingPathComponent(name).path
            )
        )
        XCTAssertEqual(try persistence.originalData(relativePath: path), data)
    }

    private func makeRequest(edited: Data? = nil) -> CapturedPhotoSaveRequest {
        CapturedPhotoSaveRequest(
            captureID: UUID(),
            capturedAt: capturedAt,
            originalData: Data("captured-original-jpeg".utf8),
            originalReceipt: nil,
            approvedEditedData: edited
        )
    }

    private func requestWithReceipt(
        _ request: CapturedPhotoSaveRequest,
        receipt: OriginalRetentionReceipt
    ) -> CapturedPhotoSaveRequest {
        CapturedPhotoSaveRequest(
            captureID: request.captureID,
            capturedAt: request.capturedAt,
            originalData: request.originalData,
            originalReceipt: receipt,
            approvedEditedData: request.approvedEditedData
        )
    }
}

private enum TestFailure: Error {
    case injected
}

private final class MemoryRetentionPersistence: OriginalRetentionPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: OriginalRetentionManifest?
    private var loadOverride: OriginalRetentionManifestLoadResult?
    private var originals: [String: Data] = [:]
    private var persistCalls = 0
    private var stageWrites = 0
    var failPersistCall: Int?
    var failStage = false

    var stageWriteCount: Int {
        locked { stageWrites }
    }

    func loadManifest() throws -> OriginalRetentionManifestLoadResult {
        locked {
            if let loadOverride { return loadOverride }
            if let manifest { return .loaded(manifest) }
            return .missing
        }
    }

    func persistManifest(_ manifest: OriginalRetentionManifest) throws {
        try locked {
            persistCalls += 1
            if failPersistCall == persistCalls { throw TestFailure.injected }
            self.manifest = manifest
            loadOverride = nil
        }
    }

    func stageVerifiedOriginal(
        data: Data,
        relativePath: String,
        expectedSHA256: String
    ) throws {
        try locked {
            if failStage { throw TestFailure.injected }
            if let existing = originals[relativePath] {
                guard OriginalPhotoRetentionStore.sha256(existing) == expectedSHA256 else {
                    throw OriginalRetentionError.stagedFileHashMismatch
                }
                return
            }
            originals[relativePath] = data
            stageWrites += 1
        }
    }

    func originalData(relativePath: String) throws -> Data {
        try locked {
            guard let data = originals[relativePath] else {
                throw OriginalRetentionError.stagedFileMissing
            }
            return data
        }
    }

    func originalExists(relativePath: String) -> Bool {
        locked { originals[relativePath] != nil }
    }

    func completeOriginalRelativePaths() throws -> [String] {
        locked { Array(originals.keys) }
    }

    func removeOriginal(relativePath: String) throws {
        locked { originals[relativePath] = nil }
    }

    func simulateCorruptManifest(preservedCopyName: String = "manifest-corrupt-test.json") {
        locked {
            manifest = nil
            loadOverride = .corrupted(preservedCopyName: preservedCopyName)
        }
    }

    func replaceOriginal(relativePath: String, with data: Data) {
        locked { originals[relativePath] = data }
    }

    func manifestSnapshot() -> OriginalRetentionManifest? {
        locked { manifest }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor FakePhotoLibraryWriter: PhotoLibraryAssetWriting {
    private let status: PhotoLibraryWriteAuthorization
    private let requestedStatus: PhotoLibraryWriteAuthorization
    private let failCreate: Bool
    private let confirmationUnknown: Bool
    private let createDelayNanoseconds: UInt64
    private let blockCreationNumber: Int?
    private var creations = 0
    private var payloads: [PhotoLibraryAssetPayload] = []
    private var startWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(
        status: PhotoLibraryWriteAuthorization,
        requestedStatus: PhotoLibraryWriteAuthorization = .authorized,
        failCreate: Bool = false,
        confirmationUnknown: Bool = false,
        createDelayNanoseconds: UInt64 = 0,
        blockCreationNumber: Int? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
        self.failCreate = failCreate
        self.confirmationUnknown = confirmationUnknown
        self.createDelayNanoseconds = createDelayNanoseconds
        self.blockCreationNumber = blockCreationNumber
    }

    func authorizationStatus() async -> PhotoLibraryWriteAuthorization { status }

    func requestAuthorization() async -> PhotoLibraryWriteAuthorization { requestedStatus }

    func createAsset(_ payload: PhotoLibraryAssetPayload) async throws -> String {
        creations += 1
        payloads.append(payload)
        let ready = startWaiters.filter { creations >= $0.minimum }
        startWaiters.removeAll { creations >= $0.minimum }
        ready.forEach { $0.continuation.resume() }
        if blockCreationNumber == creations {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        if createDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: createDelayNanoseconds)
        }
        if confirmationUnknown {
            throw PhotoLibraryAssetWriterError.commitConfirmationUnknown("injected confirmation gap")
        }
        if failCreate { throw TestFailure.injected }
        return "asset-\(creations)-\(payload.filename)"
    }

    func createCount() -> Int { creations }

    func createdPayloads() -> [PhotoLibraryAssetPayload] { payloads }

    func waitUntilCreateCount(_ minimum: Int) async {
        if creations >= minimum { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((minimum, continuation))
        }
    }

    func releaseBlockedCreate() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}
