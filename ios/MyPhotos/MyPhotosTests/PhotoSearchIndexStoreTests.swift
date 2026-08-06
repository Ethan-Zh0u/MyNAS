import Foundation
import XCTest
@testable import MyPhotos

final class PhotoSearchIndexStoreTests: XCTestCase {
    func testIndexIsOptInAndSearchesOnlyAfterSynchronization() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PhotoSearchIndexStore(directories: provider, now: { now })

        let initialStatus = try await store.status(for: account)
        XCTAssertEqual(initialStatus, .disabled)

        let enabledStatus = try await store.enable(for: account)
        XCTAssertTrue(enabledStatus.isEnabled)
        XCTAssertEqual(enabledStatus.indexedAssetCount, 0)

        let assets = [
            makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo, favorite: true),
            makeAsset(id: "video-b", date: date(2025, 1, 2), kind: .video),
        ]
        let result = try await store.synchronize(assets: assets, for: account)

        XCTAssertEqual(result.insertedCount, 2)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.status.indexedAssetCount, 2)
        XCTAssertEqual(result.status.lastSynchronizedAt, now)

        let favoriteResults = try await store.search("收藏 2026", for: account)
        XCTAssertEqual(favoriteResults.map(\.assetID), ["photo-a"])
        let videoResults = try await store.search("视频", for: account)
        XCTAssertEqual(videoResults.map(\.assetID), ["video-b"])
    }

    func testSynchronizationReusesUnchangedRecordsAndReplacesCurrentSourceVersion() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let store = PhotoSearchIndexStore(directories: provider)
        _ = try await store.enable(for: account)

        let first = makeAsset(id: "asset-a", date: date(2026, 8, 1), kind: .photo)
        let removed = makeAsset(id: "asset-b", date: date(2026, 8, 2), kind: .video)
        _ = try await store.synchronize(assets: [first, removed], for: account)

        let modified = makeAsset(
            id: "asset-a",
            date: date(2026, 8, 1),
            modificationDate: date(2026, 8, 4),
            kind: .photo,
            favorite: true
        )
        let inserted = makeAsset(id: "asset-c", date: date(2026, 8, 3), kind: .livePhoto)
        let second = try await store.synchronize(assets: [modified, inserted], for: account)

        XCTAssertEqual(second.insertedCount, 1)
        XCTAssertEqual(second.updatedCount, 1)
        XCTAssertEqual(second.removedCount, 1)
        XCTAssertEqual(second.unchangedCount, 0)
        let favoriteResults = try await store.search("收藏", for: account)
        let removedVideoResults = try await store.search("视频", for: account)
        XCTAssertEqual(favoriteResults.map(\.assetID), ["asset-a"])
        XCTAssertTrue(removedVideoResults.isEmpty)

        let third = try await store.synchronize(assets: [modified, inserted], for: account)
        XCTAssertEqual(third.insertedCount, 0)
        XCTAssertEqual(third.updatedCount, 0)
        XCTAssertEqual(third.removedCount, 0)
        XCTAssertEqual(third.unchangedCount, 2)
    }

    func testAccountsCannotReadOrClearEachOthersIndex() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let store = PhotoSearchIndexStore(directories: provider)

        _ = try await store.enable(for: firstAccount)
        _ = try await store.synchronize(
            assets: [makeAsset(id: "private-a", date: date(2026, 8, 5), kind: .photo)],
            for: firstAccount
        )

        let secondStatus = try await store.status(for: secondAccount)
        XCTAssertEqual(secondStatus, .disabled)
        _ = try await store.disableAndDelete(for: secondAccount)
        let firstResults = try await store.search("照片", for: firstAccount)
        XCTAssertEqual(firstResults.map(\.assetID), ["private-a"])
    }

    func testCopiedIndexWithDifferentAccountIdentityFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let store = PhotoSearchIndexStore(directories: provider)

        _ = try await store.enable(for: firstAccount)
        _ = try await store.synchronize(
            assets: [makeAsset(id: "private-a", date: date(2026, 8, 5), kind: .photo)],
            for: firstAccount
        )
        let firstURL = try provider.directory(for: firstAccount, kind: .searchIndex)
            .appendingPathComponent("local-index-v1.json")
        let secondURL = try provider.directory(for: secondAccount, kind: .searchIndex)
            .appendingPathComponent("local-index-v1.json")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)

        do {
            _ = try await store.status(for: secondAccount)
            XCTFail("A copied account index must not be readable")
        } catch let error as PhotoSearchIndexError {
            XCTAssertEqual(error, .accountIdentityMismatch)
        }
    }

    func testClearKeepsOptInButDisableDeletesTheIndex() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let store = PhotoSearchIndexStore(directories: provider)

        _ = try await store.enable(for: account)
        _ = try await store.synchronize(
            assets: [makeAsset(id: "asset-a", date: date(2026, 8, 5), kind: .photo)],
            for: account
        )
        let cleared = try await store.clear(for: account)
        XCTAssertTrue(cleared.isEnabled)
        XCTAssertEqual(cleared.indexedAssetCount, 0)
        let clearedResults = try await store.search("照片", for: account)
        XCTAssertTrue(clearedResults.isEmpty)

        let disabled = try await store.disableAndDelete(for: account)
        XCTAssertEqual(disabled, .disabled)
        let statusAfterDisable = try await store.status(for: account)
        XCTAssertEqual(statusAfterDisable, .disabled)
        do {
            _ = try await store.search("照片", for: account)
            XCTFail("A disabled index must reject search")
        } catch let error as PhotoSearchIndexError {
            XCTAssertEqual(error, .notEnabled)
        }
    }

    func testCorruptedIndexIsRejectedAndCanBeRemovedWithoutDecodingIt() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let indexURL = try provider.directory(for: account, kind: .searchIndex)
            .appendingPathComponent("local-index-v1.json")
        try Data("not-json".utf8).write(to: indexURL)
        let store = PhotoSearchIndexStore(directories: provider)

        do {
            _ = try await store.status(for: account)
            XCTFail("Corrupt bytes must fail closed")
        } catch let error as PhotoSearchIndexError {
            XCTAssertEqual(error, .corruptedIndex)
        }

        let resetStatus = try await store.resetCorruptedIndex(for: account)
        let finalStatus = try await store.status(for: account)
        XCTAssertEqual(resetStatus, .disabled)
        XCTAssertEqual(finalStatus, .disabled)
    }

    func testDuplicateAssetIDsInDecodableIndexFailClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duplicate = PhotoSearchIndexRecord(
            assetID: "duplicate",
            sourceVersion: "source-v1",
            modelRevision: PhotoSearchIndexStore.modelRevision,
            mediaKind: .photo,
            creationDate: now,
            isFavorite: false,
            isRAW: false,
            pixelWidth: 100,
            pixelHeight: 100,
            searchTerms: ["照片"],
            indexedAt: now
        )
        let snapshot = PhotoSearchIndexSnapshot(
            schemaVersion: PhotoSearchIndexStore.schemaVersion,
            modelRevision: PhotoSearchIndexStore.modelRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastSynchronizedAt: now,
            records: [duplicate, duplicate]
        )
        let indexURL = try provider.directory(for: account, kind: .searchIndex)
            .appendingPathComponent("local-index-v1.json")
        try JSONEncoder().encode(snapshot).write(to: indexURL)
        let store = PhotoSearchIndexStore(directories: provider)

        do {
            _ = try await store.status(for: account)
            XCTFail("Duplicate identifiers must not reach dictionary construction")
        } catch let error as PhotoSearchIndexError {
            XCTAssertEqual(error, .corruptedIndex)
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
        kind: LocalMediaKind,
        favorite: Bool = false
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
            isFavorite: favorite
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
