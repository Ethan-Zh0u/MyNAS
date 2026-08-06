import XCTest
import UIKit
@testable import MyPhotos

@MainActor
final class PhotoBackupBackgroundTransferTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPhotosTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testRemotePreviewDecoderDownsamplesJPEGIntoCompatibleImage() async throws {
        let sourceSize = CGSize(width: 900, height: 600)
        let jpeg = UIGraphicsImageRenderer(size: sourceSize).jpegData(
            withCompressionQuality: 0.82
        ) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
        }

        let image = await RemotePreviewImageDecoder.decode(
            jpeg,
            maximumPixelSize: 320
        )
        let decoded = try XCTUnwrap(image)
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 320)
    }

    func testXCTestHostDisablesProductionLifecycle() {
        XCTAssertTrue(MyPhotosRuntime.isRunningXCTest)
    }

    func testRestartNormalizesAutomaticInFlightJobToWaiting() throws {
        let account = connectedAccount()
        let queueURL = temporaryRoot.appendingPathComponent("jobs.json", isDirectory: false)
        let policyURL = temporaryRoot.appendingPathComponent("policies.json", isDirectory: false)
        let persistence = PhotoBackupPersistenceStore(explicitURL: queueURL)
        let interruptedJob = PhotoBackupJob(
            id: UUID(),
            accountID: account.accountID,
            localIdentifier: "interrupted-automatic-asset",
            mediaKind: .video,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceModificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            status: .uploading,
            totalBytes: 1_024,
            uploadedBytes: 512,
            resourceCount: 1,
            assetID: nil,
            sourceState: nil,
            derivativeState: nil,
            origin: .automatic,
            message: "上传中",
            failure: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try persistence.save([interruptedJob])

        let defaultsSuite = "MyPhotosTests.restart-normalization.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = PhotoBackupCoordinator(
            persistence: persistence,
            automationPersistence: PhotoBackupAutomationPolicyStore(explicitURL: policyURL),
            userDefaults: userDefaults
        )

        let restoredJob = try XCTUnwrap(coordinator.jobs(for: account.accountID).first)
        XCTAssertEqual(restoredJob.origin, .automatic)
        XCTAssertEqual(restoredJob.status, .waiting)
        XCTAssertEqual(restoredJob.uploadedBytes, 512)
        XCTAssertEqual(restoredJob.message, "等待从 MyNAS 已接收的位置继续")
        XCTAssertNil(restoredJob.failure)
        XCTAssertEqual(try persistence.load(), [restoredJob])
    }

    func testLegacyQueueWithoutPendingVerifiedRemoteAssetIDStillLoads() throws {
        let queueURL = temporaryRoot.appendingPathComponent("legacy-jobs.json", isDirectory: false)
        let persistence = PhotoBackupPersistenceStore(explicitURL: queueURL)
        let legacyJob = PhotoBackupJob(
            id: UUID(),
            accountID: "legacy-account",
            localIdentifier: "legacy-local",
            mediaKind: .photo,
            creationDate: nil,
            sourceModificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            status: .completed,
            totalBytes: 512,
            uploadedBytes: 512,
            resourceCount: 1,
            assetID: "legacy-remote",
            sourceState: .committed,
            derivativeState: .ready,
            origin: .manual,
            message: "旧版本记录",
            failure: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let encoded = try JSONEncoder().encode([legacyJob])
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        payload[0].removeValue(forKey: "pendingVerifiedRemoteAssetID")
        try JSONSerialization.data(withJSONObject: payload).write(to: queueURL)

        let restored = try XCTUnwrap(persistence.load().first)
        XCTAssertEqual(restored.id, legacyJob.id)
        XCTAssertEqual(restored.assetID, legacyJob.assetID)
        XCTAssertNil(restored.pendingVerifiedRemoteAssetID)
    }

    func testMetadataOnlyLibraryChangeKeepsCompletedProofAndDeletionVersion() throws {
        let account = connectedAccount()
        let queueURL = temporaryRoot.appendingPathComponent("metadata-change-jobs.json", isDirectory: false)
        let policyURL = temporaryRoot.appendingPathComponent("metadata-change-policies.json", isDirectory: false)
        let persistence = PhotoBackupPersistenceStore(explicitURL: queueURL)
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_100)
        let favouriteDate = sourceDate.addingTimeInterval(60)
        let completedJob = PhotoBackupJob(
            id: UUID(),
            accountID: account.accountID,
            localIdentifier: "metadata-only-local-photo",
            mediaKind: .photo,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceModificationDate: sourceDate,
            status: .completed,
            totalBytes: 2_048,
            uploadedBytes: 2_048,
            resourceCount: 1,
            assetID: "remote-metadata-only",
            sourceState: .committed,
            derivativeState: .ready,
            origin: .manual,
            message: "原件和浏览预览均已就绪",
            failure: nil,
            updatedAt: sourceDate
        )
        try persistence.save([completedJob])
        let defaultsSuite = "MyPhotosTests.metadata-only-change.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = PhotoBackupCoordinator(
            persistence: persistence,
            automationPersistence: PhotoBackupAutomationPolicyStore(explicitURL: policyURL),
            userDefaults: userDefaults
        )
        let favouriteAsset = LocalPhotoAsset(
            localIdentifier: completedJob.localIdentifier,
            creationDate: completedJob.creationDate,
            modificationDate: favouriteDate,
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1_200,
            pixelHeight: 900,
            duration: 0,
            isFavorite: true
        )

        coordinator.reconcileMetadataOnlyLibraryChanges(
            assetIdentifiers: [favouriteAsset.localIdentifier],
            assets: [favouriteAsset],
            accountID: account.accountID
        )

        let updated = try XCTUnwrap(coordinator.jobs(for: account.accountID).first)
        XCTAssertEqual(updated.status, .completed)
        XCTAssertEqual(updated.assetID, completedJob.assetID)
        XCTAssertEqual(updated.sourceModificationDate, sourceDate)
        XCTAssertEqual(updated.lastKnownLocalModificationDate, favouriteDate)
        XCTAssertTrue(updated.matchesCurrentLocalAsset(favouriteAsset))
        XCTAssertTrue(coordinator.hasCurrentVerifiedBackup(for: favouriteAsset, accountID: account.accountID))
        XCTAssertEqual(coordinator.pendingCount(for: [favouriteAsset], accountID: account.accountID), 0)
        XCTAssertEqual(
            coordinator.deletionCandidates(for: [favouriteAsset], accountID: account.accountID).first?.sourceModificationDate,
            PhotoBackupSourceVersion.string(from: sourceDate)
        )
        XCTAssertEqual(try persistence.load(), [updated])
    }

    func testRemoteOnlyDeletionKeepsLocalPhotoButRequiresExplicitManualRebackup() throws {
        let account = connectedAccount()
        let queueURL = temporaryRoot.appendingPathComponent("remote-delete-jobs.json", isDirectory: false)
        let policyURL = temporaryRoot.appendingPathComponent("remote-delete-policies.json", isDirectory: false)
        let persistence = PhotoBackupPersistenceStore(explicitURL: queueURL)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_100)
        let completedJob = PhotoBackupJob(
            id: UUID(),
            accountID: account.accountID,
            localIdentifier: "retained-local-photo",
            mediaKind: .photo,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceModificationDate: originalDate,
            status: .completed,
            totalBytes: 2_048,
            uploadedBytes: 2_048,
            resourceCount: 1,
            assetID: "remote-asset-to-delete",
            sourceState: .committed,
            derivativeState: .ready,
            origin: .manual,
            message: "原件和浏览预览均已就绪",
            failure: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try persistence.save([completedJob])
        let defaultsSuite = "MyPhotosTests.remote-delete.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = PhotoBackupCoordinator(
            persistence: persistence,
            automationPersistence: PhotoBackupAutomationPolicyStore(explicitURL: policyURL),
            userDefaults: userDefaults
        )
        coordinator.markRemoteBackupDeleted(
            assetID: "remote-asset-to-delete",
            accountID: account.accountID
        )

        let invalidated = try XCTUnwrap(coordinator.jobs(for: account.accountID).first)
        XCTAssertEqual(invalidated.localIdentifier, "retained-local-photo")
        XCTAssertEqual(invalidated.sourceModificationDate, originalDate)
        XCTAssertEqual(invalidated.status, .failed)
        XCTAssertNil(invalidated.assetID)
        XCTAssertNil(invalidated.sourceState)
        XCTAssertNil(invalidated.derivativeState)
        XCTAssertEqual(invalidated.failure?.kind, .remoteDeleted)
        XCTAssertEqual(invalidated.message, "MyNAS 副本已删除；本机照片仍保留")
        XCTAssertEqual(try persistence.load(), [invalidated])
    }

    func testPairedDeletionRecordsLocalPhotoAsRecentlyDeleted() throws {
        let account = connectedAccount()
        let queueURL = temporaryRoot.appendingPathComponent("paired-delete-jobs.json", isDirectory: false)
        let policyURL = temporaryRoot.appendingPathComponent("paired-delete-policies.json", isDirectory: false)
        let persistence = PhotoBackupPersistenceStore(explicitURL: queueURL)
        let completedJob = PhotoBackupJob(
            id: UUID(),
            accountID: account.accountID,
            localIdentifier: "recently-deleted-local-photo",
            mediaKind: .photo,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceModificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            status: .completed,
            totalBytes: 2_048,
            uploadedBytes: 2_048,
            resourceCount: 1,
            assetID: "paired-remote-asset",
            sourceState: .committed,
            derivativeState: .ready,
            origin: .manual,
            message: "原件和浏览预览均已就绪",
            failure: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try persistence.save([completedJob])
        let defaultsSuite = "MyPhotosTests.paired-delete.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = PhotoBackupCoordinator(
            persistence: persistence,
            automationPersistence: PhotoBackupAutomationPolicyStore(explicitURL: policyURL),
            userDefaults: userDefaults
        )
        coordinator.markRemoteBackupDeleted(
            assetID: "paired-remote-asset",
            accountID: account.accountID,
            localDisposition: .movedToRecentlyDeleted
        )

        let invalidated = try XCTUnwrap(coordinator.jobs(for: account.accountID).first)
        XCTAssertEqual(invalidated.status, .failed)
        XCTAssertEqual(invalidated.failure?.kind, .remoteDeleted)
        XCTAssertEqual(invalidated.message, "MyNAS 副本已删除；本机照片已移入“最近删除”")
        XCTAssertEqual(
            invalidated.failure?.detail,
            "用户已从 MyNAS 图库永久删除该项目，本机照片已由 iOS 移入“最近删除”。"
        )
        XCTAssertEqual(try persistence.load(), [invalidated])
    }

    func testBackupSummaryUsesCurrentPhotoLibraryCountAsDenominator() {
        let snapshot = PhotoBackupProgressSnapshot(
            completedCount: 2,
            failedCount: 0,
            totalCount: 3,
            isRunning: false,
            uploadedBytes: 10,
            totalBytes: 10,
            sizePendingCount: 1,
            provisionalBytes: 0
        )

        XCTAssertEqual(snapshot.countText, "2 / 3")
        XCTAssertEqual(snapshot.statusSummary, "原件已上传 2 / 3 项，1 项待备份")
    }

    func testBackgroundProgressUsesTransferBytesWithoutMarkingAnAssetComplete() {
        let snapshot = PhotoBackupProgressSnapshot(
            completedCount: 0,
            failedCount: 0,
            totalCount: 1,
            isRunning: true,
            uploadedBytes: 25,
            totalBytes: 100,
            sizePendingCount: 0,
            provisionalBytes: 25
        )

        XCTAssertEqual(snapshot.percentage, 25)
        XCTAssertEqual(snapshot.countText, "0 / 1")
        XCTAssertTrue(snapshot.hasProvisionalBytes)
    }

    func testAutomaticEligibilityWaitsForWiFiButAllowsPermittedNetwork() {
        let account = connectedAccount()
        var policy = enabledAutomaticPolicy(for: account)
        let cellular = automationConditions(network: .available(isWiFi: false))

        XCTAssertEqual(
            automaticPauseStatus(policy: policy, account: account, conditions: cellular),
            .waitingForWiFi
        )

        policy.networkPolicy = .anyNetwork
        XCTAssertNil(automaticPauseStatus(policy: policy, account: account, conditions: cellular))
    }

    func testAutomaticEligibilityPausesForLowPowerBeforeNetworkUpload() {
        let account = connectedAccount()
        let policy = enabledAutomaticPolicy(for: account)

        XCTAssertEqual(
            automaticPauseStatus(
                policy: policy,
                account: account,
                conditions: automationConditions(network: .available(isWiFi: true), lowPower: true)
            ),
            .pausedForLowPower
        )
    }

    func testBackgroundTransferEngineRejectsLowPowerBeforeStaging() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("low-power-source", isDirectory: false)
        let sourceData = Data("must-not-stage-in-low-power-mode".utf8)
        try sourceData.write(to: sourceURL)

        let localAsset = LocalPhotoAsset(
            localIdentifier: "low-power-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1200,
            pixelHeight: 900,
            duration: 0,
            isFavorite: false
        )
        let preparedAsset = PreparedPhotoAsset(
            localAsset: localAsset,
            temporaryDirectory: temporaryRoot,
            resourceDrafts: [
                .init(
                    role: "photo",
                    originalFilename: "low-power.heic",
                    contentType: "image/heic",
                    byteSize: Int64(sourceData.count),
                    sha256: FileSHA256.digest(of: sourceData),
                    fileURL: sourceURL
                )
            ]
        )
        let account = connectedAccount(supportsBackgroundTransfers: true)
        let policy = enabledAutomaticPolicy(for: account)
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("low-power-records.json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("low-power-staging", isDirectory: true)
        )
        let engine = PhotoBackupBackgroundTransferEngine(
            journal: journal,
            isLowPowerModeEnabled: { true }
        )

        do {
            _ = try await engine.beginAutomaticTransfer(
                preparedAsset: preparedAsset,
                account: account,
                policy: policy,
                deviceID: "ios-test-device"
            )
            XCTFail("Low Power Mode must reject G2 before it stages a resource group.")
        } catch let error as PhotoBackupBackgroundTransferEngineError {
            XCTAssertEqual(error.errorDescription, "iPhone 当前处于低电量模式，自动备份策略要求暂停。")
        }
        XCTAssertEqual(try journal.load(), [])

        XCTAssertFalse(
            PhotoBackupBackgroundTransferEngine.permitsCurrentPower(
                policy: policy,
                isLowPowerModeEnabled: true
            )
        )
        XCTAssertTrue(
            PhotoBackupBackgroundTransferEngine.permitsCurrentPower(
                policy: policy,
                isLowPowerModeEnabled: false
            )
        )

        var unrestrictedPolicy = policy
        unrestrictedPolicy.pausesInLowPowerMode = false
        XCTAssertTrue(
            PhotoBackupBackgroundTransferEngine.permitsCurrentPower(
                policy: unrestrictedPolicy,
                isLowPowerModeEnabled: true
            )
        )
    }

    func testBackgroundTransferEnginePublishesRevisionAfterJournalMutation() throws {
        let account = connectedAccount(supportsBackgroundTransfers: true)
        let localAsset = LocalPhotoAsset(
            localIdentifier: "revision-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1200,
            pixelHeight: 900,
            duration: 0,
            isFavorite: false
        )
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("revision-records.json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("revision-staging", isDirectory: true)
        )
        var record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: localAsset,
            fingerprint: String(repeating: "a", count: 64),
            resources: [
                PhotoBackupBackgroundTransferResource(
                    clientResourceID: "resource-0",
                    role: "photo",
                    originalFilename: "revision.heic",
                    contentType: "image/heic",
                    byteSize: 1,
                    sha256: String(repeating: "b", count: 64),
                    stagedFilename: "resource-0",
                    remoteResourceID: nil,
                    receivedBytes: 1,
                    systemTaskIdentifier: nil
                )
            ]
        )
        record.state = .completed
        record.outcome = PhotoBackupBackgroundTransferOutcome(
            assetID: "revision-asset",
            wasDuplicate: false,
            sourceState: .committed,
            derivativeState: .pending,
            browseReady: false
        )
        _ = try journal.stagingDirectory(for: record)
        try journal.save([record])

        let engine = PhotoBackupBackgroundTransferEngine(journal: journal)
        XCTAssertEqual(engine.stateRevision, 0)
        XCTAssertTrue(engine.discardCompletedTransfer(record, for: account))
        XCTAssertEqual(engine.stateRevision, 1)
        XCTAssertEqual(try journal.load(), [])
    }

    func testBackgroundTransferProgressIsBoundedAndNeverChangesConfirmedOffset() throws {
        let account = connectedAccount(supportsBackgroundTransfers: true)
        let localAsset = LocalPhotoAsset(
            localIdentifier: "progress-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .video,
            isRAW: false,
            pixelWidth: 1920,
            pixelHeight: 1080,
            duration: 1,
            isFavorite: false
        )
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("progress-records.json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("progress-staging", isDirectory: true)
        )
        var record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: localAsset,
            fingerprint: String(repeating: "a", count: 64),
            resources: [
                PhotoBackupBackgroundTransferResource(
                    clientResourceID: "resource-0",
                    role: "video",
                    originalFilename: "progress.mov",
                    contentType: "video/quicktime",
                    byteSize: 100,
                    sha256: String(repeating: "b", count: 64),
                    stagedFilename: "resource-0",
                    remoteResourceID: "remote-resource",
                    receivedBytes: 10,
                    chunkSize: 20,
                    systemTaskIdentifier: nil
                )
            ]
        )
        record.uploadSessionID = "progress-session"
        record.transition(to: .sessionCreated)
        try record.registerPendingSystemTask(
            PhotoBackupBackgroundTransferTask(
                taskIdentifier: 44,
                networkPolicy: .wifiOnly,
                kind: .uploadPart,
                clientResourceID: "resource-0",
                remoteResourceID: "remote-resource",
                partNumber: 0,
                offset: 10,
                byteCount: 20,
                bodyFilename: "part-0",
                responseFilename: "response-44"
            )
        )
        try journal.save([record])

        let engine = PhotoBackupBackgroundTransferEngine(journal: journal)
        XCTAssertFalse(
            engine.recordUploadProgress(
                taskIdentifier: 44,
                networkPolicy: .anyNetwork,
                totalBytesSent: 20
            )
        )
        XCTAssertTrue(
            engine.recordUploadProgress(
                taskIdentifier: 44,
                networkPolicy: .wifiOnly,
                totalBytesSent: 99
            )
        )
        let progress = try XCTUnwrap(engine.activeTransferProgress(for: account).first)
        XCTAssertEqual(progress.confirmedBytes, 10)
        XCTAssertEqual(progress.reportedBytes, 30)
        XCTAssertEqual(progress.totalBytes, 100)
        XCTAssertEqual(engine.transferProgressRevision, 1)
        XCTAssertEqual(try XCTUnwrap(try journal.load().first).resources[0].receivedBytes, 10)
    }

    func testActiveSystemSessionReconnectPoliciesStayBoundToCurrentTransferringRecords() throws {
        let account = connectedAccount(supportsBackgroundTransfers: true)
        let otherAccount = connectedAccount(
            accountID: "other-account",
            supportsBackgroundTransfers: true
        )
        var wifiRecord = try backgroundTransferRecord(
            account: account,
            localIdentifier: "active-wifi"
        )
        try wifiRecord.registerPendingSystemTask(backgroundPartTask(
            identifier: 101,
            networkPolicy: .wifiOnly
        ))

        var cellularRecord = try backgroundTransferRecord(
            account: account,
            localIdentifier: "active-cellular"
        )
        try cellularRecord.registerPendingSystemTask(backgroundPartTask(
            identifier: 102,
            networkPolicy: .anyNetwork
        ))

        var pausedRecord = try backgroundTransferRecord(
            account: account,
            localIdentifier: "paused"
        )
        pausedRecord.transition(to: .paused)

        var otherAccountRecord = try backgroundTransferRecord(
            account: otherAccount,
            localIdentifier: "other-account-active"
        )
        try otherAccountRecord.registerPendingSystemTask(backgroundPartTask(
            identifier: 103,
            networkPolicy: .wifiOnly
        ))

        XCTAssertEqual(
            PhotoBackupBackgroundTransferEngine.activeSystemTaskNetworkPolicies(
                in: [wifiRecord, cellularRecord, pausedRecord, otherAccountRecord],
                for: account
            ),
            [.wifiOnly, .anyNetwork]
        )
    }

    func testAutomaticEligibilityFailsClosedUntilMappingRecoverySucceeds() {
        let account = connectedAccount()
        let policy = enabledAutomaticPolicy(for: account)
        let conditions = automationConditions(network: .available(isWiFi: true))

        XCTAssertEqual(
            automaticPauseStatus(
                policy: policy,
                account: account,
                conditions: conditions,
                isMappingRecoveryInProgress: true,
                hasRecoveredMappings: false
            ),
            .verifyingExistingBackups
        )
        XCTAssertEqual(
            automaticPauseStatus(
                policy: policy,
                account: account,
                conditions: conditions,
                isMappingRecoveryInProgress: false,
                hasRecoveredMappings: false
            ),
            .waitingToVerifyExistingBackups
        )
    }

    func testAutomaticEligibilityRejectsPolicyForDifferentAccountIdentity() {
        let account = connectedAccount()
        let policy = enabledAutomaticPolicy(for: account)
        let differentAccount = connectedAccount(userID: "another-user")

        XCTAssertEqual(
            automaticPauseStatus(
                policy: policy,
                account: differentAccount,
                conditions: automationConditions(network: .available(isWiFi: true))
            ),
            .disabled
        )
    }

    func testBackgroundTaskJournalBindsAResponseToOnePreparedTransfer() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("task-source", isDirectory: false)
        let sourceData = Data("background-task-body".utf8)
        try sourceData.write(to: sourceURL)

        let localAsset = LocalPhotoAsset(
            localIdentifier: "task-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .video,
            isRAW: false,
            pixelWidth: 1920,
            pixelHeight: 1080,
            duration: 1,
            isFavorite: false
        )
        let preparedAsset = PreparedPhotoAsset(
            localAsset: localAsset,
            temporaryDirectory: temporaryRoot,
            resourceDrafts: [
                .init(
                    role: "video",
                    originalFilename: "task.mov",
                    contentType: "video/quicktime",
                    byteSize: Int64(sourceData.count),
                    sha256: FileSHA256.digest(of: sourceData),
                    fileURL: sourceURL
                )
            ]
        )
        let account = connectedAccount()
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("task-records-json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("task-staging", isDirectory: true)
        )
        let record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: localAsset,
            fingerprint: preparedAsset.fingerprint,
            resources: preparedAsset.resources.map {
                PhotoBackupBackgroundTransferResource(
                    clientResourceID: $0.clientResourceID,
                    role: $0.role,
                    originalFilename: $0.originalFilename,
                    contentType: $0.contentType,
                    byteSize: $0.byteSize,
                    sha256: $0.sha256,
                    stagedFilename: $0.clientResourceID,
                    remoteResourceID: nil,
                    receivedBytes: 0,
                    systemTaskIdentifier: nil
                )
            }
        )
        _ = try journal.stagingDirectory(for: record)

        var pendingRecord = record
        let task = PhotoBackupBackgroundTransferTask(
            taskIdentifier: 42,
            networkPolicy: .wifiOnly,
            kind: .createSession,
            bodyFilename: record.manifestFilename,
            responseFilename: "response-42"
        )
        try pendingRecord.registerPendingSystemTask(
            task,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(pendingRecord.state, .transferring)
        XCTAssertEqual(pendingRecord.pendingSystemTask, task)
        XCTAssertEqual(pendingRecord.pendingSystemTask?.networkPolicy, .wifiOnly)

        try pendingRecord.markPendingSystemTaskAwaitingCallback(
            taskIdentifier: 42,
            responseStatusCode: 201,
            responseByteCount: 320,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        XCTAssertEqual(pendingRecord.state, .awaitingAppCallback)
        XCTAssertEqual(pendingRecord.pendingSystemTask?.responseStatusCode, 201)
        XCTAssertEqual(pendingRecord.pendingSystemTask?.responseByteCount, 320)

        try pendingRecord.pausePendingSystemTask(
            taskIdentifier: 42,
            error: PhotoBackupFailure(
                kind: .network,
                detail: "test interruption",
                occurredAt: Date(timeIntervalSince1970: 1_700_000_400)
            )
        )
        XCTAssertEqual(pendingRecord.state, .paused)
        XCTAssertNil(pendingRecord.pendingSystemTask)
        XCTAssertNil(pendingRecord.uploadSessionID)

        try journal.save([pendingRecord])
        XCTAssertEqual(try journal.load(), [pendingRecord])
        XCTAssertNoThrow(try journal.stagingDirectory(for: pendingRecord))

        var invalidRecord = record
        XCTAssertThrowsError(
            try invalidRecord.registerPendingSystemTask(
                PhotoBackupBackgroundTransferTask(
                    taskIdentifier: 43,
                    networkPolicy: .wifiOnly,
                    kind: .createSession,
                    bodyFilename: "wrong-body",
                    responseFilename: "response-43"
                )
            )
        )
    }

    func testBackgroundTaskIdentitySeparatesEqualIDsFromDifferentSystemSessions() {
        let wifiTask = PhotoBackupBackgroundTransferTask(
            taskIdentifier: 42,
            networkPolicy: .wifiOnly,
            kind: .createSession,
            bodyFilename: "create-session",
            responseFilename: "response-42"
        )
        let cellularTask = PhotoBackupBackgroundTransferTask(
            taskIdentifier: 42,
            networkPolicy: .anyNetwork,
            kind: .createSession,
            bodyFilename: "create-session",
            responseFilename: "response-42"
        )

        XCTAssertNotEqual(wifiTask.callbackIdentity, cellularTask.callbackIdentity)
    }

    func testLegacyTaskWithoutSessionPolicyDecodesForFailClosedCallbackMigration() throws {
        struct LegacyTask: Codable {
            let taskIdentifier: Int
            let kind: PhotoBackupBackgroundTransferTaskKind
            let clientResourceID: String?
            let remoteResourceID: String?
            let partNumber: Int64?
            let offset: Int64?
            let byteCount: Int64?
            let bodyFilename: String
            let responseFilename: String
            let responseStatusCode: Int?
            let responseByteCount: Int64?
        }

        let legacyData = try JSONEncoder().encode(LegacyTask(
            taskIdentifier: 42,
            kind: .createSession,
            clientResourceID: nil,
            remoteResourceID: nil,
            partNumber: nil,
            offset: nil,
            byteCount: nil,
            bodyFilename: "create-session",
            responseFilename: "response-42",
            responseStatusCode: nil,
            responseByteCount: nil
        ))
        let decoded = try JSONDecoder().decode(PhotoBackupBackgroundTransferTask.self, from: legacyData)

        XCTAssertNil(decoded.networkPolicy)
        XCTAssertNil(decoded.callbackIdentity)
    }

    func testBackgroundEngineFailsClosedBeforeStagingWhenServerCapabilityIsOff() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("capability-source", isDirectory: false)
        let sourceData = Data("must-not-stage".utf8)
        try sourceData.write(to: sourceURL)

        let localAsset = LocalPhotoAsset(
            localIdentifier: "capability-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1200,
            pixelHeight: 900,
            duration: 0,
            isFavorite: false
        )
        let preparedAsset = PreparedPhotoAsset(
            localAsset: localAsset,
            temporaryDirectory: temporaryRoot,
            resourceDrafts: [
                .init(
                    role: "photo",
                    originalFilename: "capability.heic",
                    contentType: "image/heic",
                    byteSize: Int64(sourceData.count),
                    sha256: FileSHA256.digest(of: sourceData),
                    fileURL: sourceURL
                )
            ]
        )
        let account = connectedAccount()
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("capability-records-json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("capability-staging", isDirectory: true)
        )
        let engine = PhotoBackupBackgroundTransferEngine(journal: journal)

        do {
            _ = try await engine.beginAutomaticTransfer(
                preparedAsset: preparedAsset,
                account: account,
                policy: enabledAutomaticPolicy(for: account),
                deviceID: "ios-test-device"
            )
            XCTFail("A server without background-transfer capability must not stage or schedule work.")
        } catch let error as PhotoBackupBackgroundTransferEngineError {
            XCTAssertEqual(error.errorDescription, "当前 MyNAS 或自动备份策略尚未允许系统后台传输。")
        }
        XCTAssertEqual(try journal.load(), [])
    }

    func testBackgroundProcessingRequiresTheCurrentPersistedAccountAndCapability() throws {
        let account = connectedAccount(supportsBackgroundTransfers: true)
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("processing-records.json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("processing-staging", isDirectory: true)
        )
        let record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: LocalPhotoAsset(
                localIdentifier: "processing-local-asset",
                creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
                mediaKind: .photo,
                isRAW: false,
                pixelWidth: 1200,
                pixelHeight: 900,
                duration: 0,
                isFavorite: false
            ),
            fingerprint: String(repeating: "a", count: 64),
            resources: [
                PhotoBackupBackgroundTransferResource(
                    clientResourceID: "resource-0",
                    role: "photo",
                    originalFilename: "processing.heic",
                    contentType: "image/heic",
                    byteSize: 1,
                    sha256: String(repeating: "b", count: 64),
                    stagedFilename: "resource-0",
                    remoteResourceID: nil,
                    receivedBytes: 0,
                    systemTaskIdentifier: nil
                )
            ]
        )
        try journal.save([record])

        let accountStore = AccountPersistenceStore(
            explicitURL: temporaryRoot.appendingPathComponent("processing-accounts.json", isDirectory: false)
        )
        try accountStore.save(AccountPersistenceSnapshot(
            currentAccountID: account.accountID,
            accounts: [account]
        ))
        let policyStore = PhotoBackupAutomationPolicyStore(
            explicitURL: temporaryRoot.appendingPathComponent("processing-policies.json", isDirectory: false)
        )
        try policyStore.save([enabledAutomaticPolicy(for: account)])
        let engine = PhotoBackupBackgroundTransferEngine(
            journal: journal,
            accountPersistence: accountStore,
            policyPersistence: policyStore
        )
        XCTAssertTrue(engine.hasEligiblePersistedTransferForBackgroundProcessing())

        try accountStore.save(AccountPersistenceSnapshot(
            currentAccountID: "another-account",
            accounts: [account]
        ))
        XCTAssertFalse(engine.hasEligiblePersistedTransferForBackgroundProcessing())
    }

    func testBackgroundProcessingIdentifierIsStableAndSeparateFromTransferSessions() {
        XCTAssertEqual(
            PhotoBackupBackgroundProcessingScheduler.taskIdentifier,
            "com.ethanzhou.MyPhotos.photo-backup-processing"
        )
        XCTAssertFalse(
            PhotoBackupBackgroundProcessingScheduler.taskIdentifier.hasPrefix(
                PhotoBackupBackgroundTransferEngine.sessionIdentifierPrefix
            )
        )
    }

    func testCompletedTransferCleanupRemovesOnlyVerifiedRecordStaging() throws {
        let account = connectedAccount()
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("completed-records.json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("completed-staging", isDirectory: true)
        )
        let localAsset = LocalPhotoAsset(
            localIdentifier: "completed-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1200,
            pixelHeight: 900,
            duration: 0,
            isFavorite: false
        )
        let record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: localAsset,
            fingerprint: String(repeating: "c", count: 64),
            resources: [
                PhotoBackupBackgroundTransferResource(
                    clientResourceID: "resource-0",
                    role: "photo",
                    originalFilename: "completed.heic",
                    contentType: "image/heic",
                    byteSize: 1,
                    sha256: String(repeating: "d", count: 64),
                    stagedFilename: "resource-0",
                    remoteResourceID: nil,
                    receivedBytes: 0,
                    systemTaskIdentifier: nil
                )
            ]
        )
        let recordDirectory = try journal.stagingDirectory(for: record)
        let unrelatedDirectory = temporaryRoot.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)

        try journal.save([record])
        XCTAssertThrowsError(try journal.removeCompletedTransfer(record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordDirectory.path))

        var completedRecord = record
        completedRecord.outcome = PhotoBackupBackgroundTransferOutcome(
            assetID: "asset-completed",
            wasDuplicate: false,
            sourceState: .committed,
            derivativeState: .pending,
            browseReady: false
        )
        completedRecord.transition(to: .completed)
        try journal.save([completedRecord])

        try journal.removeCompletedTransfer(completedRecord)
        XCTAssertEqual(try journal.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
    }

    func testStagingPersistsVerifiedManifestAndNeverOverwritesPartBody() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("source-resource", isDirectory: false)
        let sourceData = Data("abcdefgh".utf8)
        try sourceData.write(to: sourceURL)

        let localAsset = LocalPhotoAsset(
            localIdentifier: "test-local-asset",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1200,
            pixelHeight: 900,
            duration: 0,
            isFavorite: false
        )
        let preparedAsset = PreparedPhotoAsset(
            localAsset: localAsset,
            temporaryDirectory: temporaryRoot,
            resourceDrafts: [
                .init(
                    role: "photo",
                    originalFilename: "source.heic",
                    contentType: "image/heic",
                    byteSize: Int64(sourceData.count),
                    sha256: FileSHA256.digest(of: sourceData),
                    fileURL: sourceURL
                )
            ]
        )
        let account = connectedAccount()
        let journal = PhotoBackupBackgroundTransferJournal(
            explicitURL: temporaryRoot.appendingPathComponent("records-json", isDirectory: false),
            explicitStagingRootURL: temporaryRoot.appendingPathComponent("staging", isDirectory: true)
        )
        let stager = PhotoBackupBackgroundTransferStager(journal: journal)

        let record = try await stager.stage(
            preparedAsset: preparedAsset,
            account: account,
            deviceID: "ios-test-device"
        )
        XCTAssertEqual(try journal.load(), [record])

        let directory = try journal.stagingDirectory(for: record)
        let manifest = try JSONDecoder().decode(
            PhotoUploadSessionRequest.self,
            from: Data(contentsOf: directory.appendingPathComponent(record.manifestFilename))
        )
        XCTAssertEqual(manifest.volumeID, account.selectedVolumeID)
        XCTAssertEqual(manifest.deviceID, "ios-test-device")
        XCTAssertEqual(manifest.localIdentifier, localAsset.localIdentifier)
        XCTAssertEqual(manifest.fingerprint, preparedAsset.fingerprint)
        XCTAssertEqual(manifest.resources.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(record.completionFilename)),
            Data()
        )

        let materializer = PhotoBackupBackgroundTransferPartMaterializer(journal: journal)
        let firstPart = try await materializer.materializePart(
            record: record,
            clientResourceID: preparedAsset.resources[0].clientResourceID,
            offset: 2,
            byteCount: 3
        )
        let partURL = directory.appendingPathComponent(firstPart.filename)
        XCTAssertEqual(try Data(contentsOf: partURL), Data("cde".utf8))
        XCTAssertEqual(firstPart.byteSize, 3)
        XCTAssertEqual(firstPart.sha256, FileSHA256.digest(of: Data("cde".utf8)))

        // A future URLSession task may still be reading this body. Changing the
        // staged source must therefore not replace an already materialized part.
        try Data("XXXXXXXX".utf8).write(
            to: directory.appendingPathComponent(record.resources[0].stagedFilename)
        )
        let repeatedPart = try await materializer.materializePart(
            record: record,
            clientResourceID: preparedAsset.resources[0].clientResourceID,
            offset: 2,
            byteCount: 3
        )
        XCTAssertEqual(repeatedPart, firstPart)
        XCTAssertEqual(try Data(contentsOf: partURL), Data("cde".utf8))
    }

    private func connectedAccount(
        accountID: String = "test-account",
        userID: String = "test-user",
        supportsBackgroundTransfers: Bool = false
    ) -> AccountContext {
        AccountContext(
            accountID: accountID,
            serverID: "test-server",
            serverURL: URL(string: "https://test.tailnet.ts.net"),
            userID: userID,
            authenticationIdentity: "test-identity",
            displayName: "Test MyNAS",
            avatarVersion: nil,
            selectedVolumeID: "test-volume",
            serverCapabilities: ServerCapabilities(
                apiVersion: "0.8.5",
                supportsPhotoAssets: true,
                supportsBackgroundTransfers: supportsBackgroundTransfers,
                supportsLivePhotos: true,
                supportsRemoteBrowsing: true,
                supportsChangeFeed: true,
                supportsDeviceAssetMappingRecovery: true,
                supportsPhotoDeletion: true,
                backupStateModelVersion: 1,
                derivativePolicyVersion: "test",
                availableDerivativeRecipes: []
            ),
            availableVolumes: [],
            encryptionNamespace: nil
        )
    }

    private func enabledAutomaticPolicy(for account: AccountContext) -> PhotoBackupAutomationPolicy {
        PhotoBackupAutomationPolicy(
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            isEnabled: true,
            networkPolicy: .wifiOnly,
            pausesInLowPowerMode: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func backgroundTransferRecord(
        account: AccountContext,
        localIdentifier: String
    ) throws -> PhotoBackupBackgroundTransferRecord {
        let localAsset = LocalPhotoAsset(
            localIdentifier: localIdentifier,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: .video,
            isRAW: false,
            pixelWidth: 1920,
            pixelHeight: 1080,
            duration: 1,
            isFavorite: false
        )
        var record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: localAsset,
            fingerprint: String(repeating: "a", count: 64),
            resources: [
                PhotoBackupBackgroundTransferResource(
                    clientResourceID: "resource-0",
                    role: "video",
                    originalFilename: "test.mov",
                    contentType: "video/quicktime",
                    byteSize: 100,
                    sha256: String(repeating: "b", count: 64),
                    stagedFilename: "resource-0",
                    remoteResourceID: "remote-resource",
                    receivedBytes: 10,
                    chunkSize: 20,
                    systemTaskIdentifier: nil
                )
            ]
        )
        record.uploadSessionID = "session-\(localIdentifier)"
        record.transition(to: .sessionCreated)
        return record
    }

    private func backgroundPartTask(
        identifier: Int,
        networkPolicy: PhotoBackupAutomaticNetworkPolicy
    ) -> PhotoBackupBackgroundTransferTask {
        PhotoBackupBackgroundTransferTask(
            taskIdentifier: identifier,
            networkPolicy: networkPolicy,
            kind: .uploadPart,
            clientResourceID: "resource-0",
            remoteResourceID: "remote-resource",
            partNumber: 0,
            offset: 10,
            byteCount: 20,
            bodyFilename: "part-0",
            responseFilename: "response-\(identifier)"
        )
    }

    private func automationConditions(
        network: PhotoBackupAutomationConditionSnapshot.NetworkState,
        lowPower: Bool = false
    ) -> PhotoBackupAutomationConditionSnapshot {
        PhotoBackupAutomationConditionSnapshot(
            network: network,
            isLowPowerModeEnabled: lowPower
        )
    }

    private func automaticPauseStatus(
        policy: PhotoBackupAutomationPolicy,
        account: AccountContext,
        conditions: PhotoBackupAutomationConditionSnapshot,
        isMappingRecoveryInProgress: Bool = false,
        hasRecoveredMappings: Bool = true
    ) -> PhotoBackupAutomationStatus? {
        PhotoBackupAutomaticEligibility.pauseStatus(
            policy: policy,
            account: account,
            isAppInForeground: true,
            isSelectedAccount: true,
            requiresDeviceMappingRecovery: true,
            isMappingRecoveryInProgress: isMappingRecoveryInProgress,
            hasRecoveredMappings: hasRecoveredMappings,
            conditions: conditions
        )
    }
}
