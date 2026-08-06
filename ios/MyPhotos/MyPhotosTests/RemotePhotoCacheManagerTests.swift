import Foundation
import XCTest
@testable import MyPhotos

final class RemotePhotoCacheManagerTests: XCTestCase {
    func testTrimRemovesTemporaryDownloadsBeforePreviewsAndThumbnails() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")

        let temporaryRoot = try provider.directory(for: account, kind: .temporaryDownloads)
        let temporaryDownload = temporaryRoot.appendingPathComponent("completed-download", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDownload, withIntermediateDirectories: false)
        let temporaryFile = temporaryDownload.appendingPathComponent("original.heic")
        try write(byteCount: 96, to: temporaryFile)

        let previewFile = try provider.directory(for: account, kind: .previews)
            .appendingPathComponent("preview.image")
        try write(byteCount: 80, to: previewFile)

        let thumbnailFile = try provider.directory(for: account, kind: .thumbnails)
            .appendingPathComponent("thumbnail.image")
        try write(byteCount: 70, to: thumbnailFile)

        let manager = RemotePhotoCacheManager(directories: provider)
        let result = try await manager.trim(account: account, maximumByteCount: 155)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDownload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailFile.path))
        XCTAssertEqual(result.removedEntryCount, 1)
        XCTAssertEqual(result.removedByteCount, 96)
        XCTAssertEqual(result.remainingUsage.totalByteCount, 150)
    }

    func testTrimUsesLeastRecentlyUsedEntryWithinSameCacheKind() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let previewDirectory = try provider.directory(for: account, kind: .previews)
        let olderPreview = previewDirectory.appendingPathComponent("older.image")
        let newerPreview = previewDirectory.appendingPathComponent("newer.image")
        try write(byteCount: 90, to: olderPreview)
        try write(byteCount: 80, to: newerPreview)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: olderPreview.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: newerPreview.path
        )

        let manager = RemotePhotoCacheManager(directories: provider)
        let result = try await manager.trim(account: account, maximumByteCount: 85)

        XCTAssertFalse(FileManager.default.fileExists(atPath: olderPreview.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerPreview.path))
        XCTAssertEqual(result.remainingUsage.totalByteCount, 80)
    }

    func testClearingOneAccountDoesNotRemoveAnotherAccountsCache() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let firstFile = try provider.directory(for: firstAccount, kind: .thumbnails)
            .appendingPathComponent("first.image")
        let secondFile = try provider.directory(for: secondAccount, kind: .thumbnails)
            .appendingPathComponent("second.image")
        try write(byteCount: 17, to: firstFile)
        try write(byteCount: 29, to: secondFile)

        let manager = RemotePhotoCacheManager(directories: provider)
        let result = try await manager.clear(account: firstAccount)
        let remainingSecondUsage = try await manager.usage(for: secondAccount)

        XCTAssertEqual(result.removedByteCount, 17)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
        XCTAssertEqual(remainingSecondUsage.totalByteCount, 29)
    }

    func testDiscardingOrphanedDownloadsLeavesReusableCacheUntouched() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")

        let temporaryRoot = try provider.directory(for: account, kind: .temporaryDownloads)
        let populatedDownload = temporaryRoot.appendingPathComponent("orphan-a", isDirectory: true)
        let emptyDownload = temporaryRoot.appendingPathComponent("orphan-b", isDirectory: true)
        try FileManager.default.createDirectory(at: populatedDownload, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: emptyDownload, withIntermediateDirectories: false)
        try write(
            byteCount: 123,
            to: populatedDownload.appendingPathComponent("original.heic")
        )

        let previewFile = try provider.directory(for: account, kind: .previews)
            .appendingPathComponent("preview.image")
        try write(byteCount: 45, to: previewFile)

        let manager = RemotePhotoCacheManager(directories: provider)
        let result = try await manager.discardOrphanedTemporaryDownloads(account: account)

        XCTAssertFalse(FileManager.default.fileExists(atPath: populatedDownload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyDownload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewFile.path))
        XCTAssertEqual(result.removedByteCount, 123)
        XCTAssertEqual(result.removedEntryCount, 2)
        XCTAssertEqual(result.remainingUsage.totalByteCount, 45)
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

    private func write(byteCount: Int, to url: URL) throws {
        try Data(repeating: 0xA5, count: byteCount).write(to: url)
    }
}
