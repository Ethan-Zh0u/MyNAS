import Foundation
import XCTest
@testable import MyPhotos

final class PhotoAnalysisQueueStoreTests: XCTestCase {
    func testPixelAnalysisIsOptInAndPreparingBeforeConsentFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let store = PhotoAnalysisQueueStore(directories: provider)

        let initialStatus = try await store.status(for: account)
        XCTAssertEqual(initialStatus, .disabled)

        do {
            _ = try await store.prepare(
                assets: [makeAsset(id: "asset-a", date: date(2026, 8, 6))],
                for: account
            )
            XCTFail("Queue preparation must not run before explicit consent")
        } catch let error as PhotoAnalysisQueueError {
            XCTAssertEqual(error, .pixelAnalysisNotAllowed)
        }

        let enabled = try await store.enablePixelAnalysis(for: account)
        XCTAssertTrue(enabled.isPixelAnalysisAllowed)
        XCTAssertEqual(enabled.pendingAssetCount, 0)
    }

    func testQueuePersistsOnlyIdentifiersAndMetadataDerivedVersions() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PhotoAnalysisQueueStore(directories: provider, now: { now })
        _ = try await store.enablePixelAnalysis(for: account)

        let result = try await store.prepare(
            assets: [
                makeAsset(id: "photo-a", date: date(2026, 8, 4), kind: .photo),
                makeAsset(id: "video-b", date: date(2026, 8, 5), kind: .video),
            ],
            for: account
        )

        XCTAssertEqual(result.insertedCount, 2)
        XCTAssertEqual(result.status.pendingAssetCount, 2)
        XCTAssertEqual(result.status.lastPreparedAt, now)

        let queueURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("pixel-analysis-consent-v1.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any]
        let items = raw?["items"] as? [[String: Any]]
        XCTAssertEqual(Set(items?.flatMap(\.keys) ?? []), ["assetID", "sourceVersion", "queuedAt"])
        XCTAssertFalse(raw?.keys.contains("imageData") == true)
        XCTAssertFalse(raw?.keys.contains("videoData") == true)
        XCTAssertFalse(raw?.keys.contains("thumbnail") == true)
        XCTAssertFalse(raw?.keys.contains("ocr") == true)
        XCTAssertFalse(raw?.keys.contains("embedding") == true)
    }

    func testPreparingQueueReusesUnchangedItemsAndReplacesChangedScope() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let store = PhotoAnalysisQueueStore(directories: provider)
        _ = try await store.enablePixelAnalysis(for: account)

        let first = makeAsset(id: "asset-a", date: date(2026, 8, 1))
        let removed = makeAsset(id: "asset-b", date: date(2026, 8, 2), kind: .video)
        _ = try await store.prepare(assets: [first, removed], for: account)

        let changed = makeAsset(
            id: "asset-a",
            date: date(2026, 8, 1),
            modificationDate: date(2026, 8, 6)
        )
        let inserted = makeAsset(id: "asset-c", date: date(2026, 8, 3), kind: .livePhoto)
        let second = try await store.prepare(assets: [changed, inserted], for: account)

        XCTAssertEqual(second.insertedCount, 1)
        XCTAssertEqual(second.updatedCount, 1)
        XCTAssertEqual(second.removedCount, 1)
        XCTAssertEqual(second.unchangedCount, 0)
        XCTAssertEqual(second.status.pendingAssetCount, 2)

        let third = try await store.prepare(assets: [changed, inserted], for: account)
        XCTAssertEqual(third.insertedCount, 0)
        XCTAssertEqual(third.updatedCount, 0)
        XCTAssertEqual(third.removedCount, 0)
        XCTAssertEqual(third.unchangedCount, 2)
    }

    func testAccountsCannotReadOrDeleteEachOthersQueue() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let store = PhotoAnalysisQueueStore(directories: provider)
        _ = try await store.enablePixelAnalysis(for: firstAccount)
        _ = try await store.prepare(
            assets: [makeAsset(id: "private-a", date: date(2026, 8, 5))],
            for: firstAccount
        )

        let secondStatus = try await store.status(for: secondAccount)
        XCTAssertEqual(secondStatus, .disabled)
        _ = try await store.disableAndDelete(for: secondAccount)
        let firstStatus = try await store.status(for: firstAccount)
        XCTAssertTrue(firstStatus.isPixelAnalysisAllowed)
        XCTAssertEqual(firstStatus.pendingAssetCount, 1)
    }

    func testCopiedQueueWithDifferentAccountIdentityFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let store = PhotoAnalysisQueueStore(directories: provider)
        _ = try await store.enablePixelAnalysis(for: firstAccount)
        _ = try await store.prepare(
            assets: [makeAsset(id: "private-a", date: date(2026, 8, 5))],
            for: firstAccount
        )
        let firstURL = try provider.directory(for: firstAccount, kind: .analysisQueue)
            .appendingPathComponent("pixel-analysis-consent-v1.json")
        let secondURL = try provider.directory(for: secondAccount, kind: .analysisQueue)
            .appendingPathComponent("pixel-analysis-consent-v1.json")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)

        do {
            _ = try await store.status(for: secondAccount)
            XCTFail("A copied account queue must not be readable")
        } catch let error as PhotoAnalysisQueueError {
            XCTAssertEqual(error, .accountIdentityMismatch)
        }
    }

    func testDisableDeletesQueueAndAccountCacheClearRevokesConsent() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let store = PhotoAnalysisQueueStore(directories: provider)
        _ = try await store.enablePixelAnalysis(for: account)
        _ = try await store.prepare(
            assets: [makeAsset(id: "asset-a", date: date(2026, 8, 5))],
            for: account
        )

        let disabledStatus = try await store.disableAndDelete(for: account)
        XCTAssertEqual(disabledStatus, .disabled)
        let statusAfterDisable = try await store.status(for: account)
        XCTAssertEqual(statusAfterDisable, .disabled)

        _ = try await store.enablePixelAnalysis(for: account)
        _ = try await store.prepare(
            assets: [makeAsset(id: "asset-a", date: date(2026, 8, 5))],
            for: account
        )
        _ = try await RemotePhotoCacheManager(directories: provider).clear(account: account)
        let statusAfterCacheClear = try await store.status(for: account)
        XCTAssertEqual(statusAfterCacheClear, .disabled)
    }

    func testCorruptedOrDuplicateQueueFailsClosedAndCanBeRemoved() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let queueURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("pixel-analysis-consent-v1.json")
        try Data("not-json".utf8).write(to: queueURL)
        let store = PhotoAnalysisQueueStore(directories: provider)

        do {
            _ = try await store.status(for: account)
            XCTFail("Corrupt bytes must fail closed")
        } catch let error as PhotoAnalysisQueueError {
            XCTAssertEqual(error, .corruptedQueue)
        }

        let resetStatus = try await store.resetCorruptedQueue(for: account)
        XCTAssertEqual(resetStatus, .disabled)

        // Reset now removes the whole consent namespace so later pixel-derived
        // artefacts, such as I3's OCR index, cannot outlive a corrupted or
        // revoked I2 consent. Recreate the isolated test directory before
        // writing the next independent corrupt fixture.
        _ = try provider.directory(for: account, kind: .analysisQueue)

        let duplicate = PhotoAnalysisQueueItem(
            assetID: "duplicate",
            sourceVersion: "source-v1",
            queuedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let snapshot = PhotoAnalysisQueueSnapshot(
            schemaVersion: PhotoAnalysisQueueStore.schemaVersion,
            consentRevision: PhotoAnalysisQueueStore.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastPreparedAt: duplicate.queuedAt,
            items: [duplicate, duplicate]
        )
        try JSONEncoder().encode(snapshot).write(to: queueURL)
        do {
            _ = try await store.status(for: account)
            XCTFail("Duplicate identifiers must fail closed")
        } catch let error as PhotoAnalysisQueueError {
            XCTAssertEqual(error, .corruptedQueue)
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    private func makeAccount(id: String, userID: String) -> AccountContext {
        AccountContext(
            accountID: id,
            serverID: "server-1",
            serverURL: URL(string: "https://mynas.example.invalid"),
            userID: userID,
            authenticationIdentity: userID,
            displayName: userID,
            avatarVersion: nil,
            selectedVolumeID: nil,
            serverCapabilities: .localOnly,
            availableVolumes: [],
            encryptionNamespace: nil
        )
    }

    private func makeAsset(
        id: String,
        date: Date,
        modificationDate: Date? = nil,
        kind: LocalMediaKind = .photo
    ) -> LocalPhotoAsset {
        LocalPhotoAsset(
            localIdentifier: id,
            creationDate: date,
            modificationDate: modificationDate ?? date,
            mediaKind: kind,
            isRAW: false,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: kind == .video ? 12 : 0,
            isFavorite: false
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
