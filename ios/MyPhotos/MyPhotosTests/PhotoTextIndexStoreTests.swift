import Foundation
import XCTest
@testable import MyPhotos

final class PhotoTextIndexStoreTests: XCTestCase {
    func testOCRRequiresBothPixelAnalysisAndSeparateOCRConsent() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoTextIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)

        let initialStatus = try await store.status(for: account)
        XCTAssertEqual(initialStatus, .disabled)
        do {
            _ = try await store.enable(for: account)
            XCTFail("OCR must reject when I2 pixel analysis has not been allowed")
        } catch let error as PhotoTextIndexError {
            XCTAssertEqual(error, .pixelAnalysisNotAllowed)
        }

        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        let enabled = try await store.enable(for: account)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.indexedAssetCount, 0)
    }

    func testOCRPersistsOnlyAccountBoundTextAndValueMetadata() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoTextIndexStore(
            directories: provider,
            now: { now },
            pixelAnalysisConsent: pixelConsent
        )
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account)

        let result = try await store.synchronize(
            assets: [
                makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo),
                makeAsset(id: "video-b", date: date(2026, 8, 5), kind: .video),
            ],
            outputs: [PhotoTextRecognitionOutput(assetID: "photo-a", recognizedText: "MyNAS 私有文字")],
            for: account
        )

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.deferredAssetCount, 0)
        XCTAssertEqual(result.status.indexedAssetCount, 1)
        XCTAssertEqual(result.status.lastSynchronizedAt, now)
        let privateTextResults = try await store.search("私有", for: account)
        XCTAssertEqual(privateTextResults.map(\.assetID), ["photo-a"])

        let indexURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("vision-ocr-index-v1.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        let records = raw?["records"] as? [[String: Any]]
        XCTAssertEqual(Set(records?.flatMap(\.keys) ?? []), ["assetID", "sourceVersion", "processorRevision", "recognizedText", "indexedAt"])
        XCTAssertFalse(raw?.keys.contains("imageData") == true)
        XCTAssertFalse(raw?.keys.contains("thumbnail") == true)
        XCTAssertFalse(raw?.keys.contains("fileURL") == true)
        XCTAssertFalse(raw?.keys.contains("visionObservation") == true)
        XCTAssertFalse(raw?.keys.contains("embedding") == true)
    }

    func testSynchronizationReusesCurrentResultsAndDropsChangedImageWhenNoLocalPixelsAreAvailable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoTextIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account)

        let first = makeAsset(id: "photo-a", date: date(2026, 8, 1), kind: .photo)
        _ = try await store.synchronize(
            assets: [first],
            outputs: [PhotoTextRecognitionOutput(assetID: "photo-a", recognizedText: "旧文字")],
            for: account
        )

        let unchanged = try await store.synchronize(
            assets: [first],
            outputs: [],
            for: account
        )
        XCTAssertEqual(unchanged.unchangedCount, 1)
        XCTAssertEqual(unchanged.deferredAssetCount, 0)
        let oldTextResults = try await store.search("旧文字", for: account)
        XCTAssertEqual(oldTextResults.count, 1)

        let changed = makeAsset(
            id: "photo-a",
            date: date(2026, 8, 1),
            modificationDate: date(2026, 8, 6),
            kind: .photo
        )
        let deferred = try await store.synchronize(assets: [changed], outputs: [], for: account)
        XCTAssertEqual(deferred.updatedCount, 0)
        XCTAssertEqual(deferred.removedCount, 1)
        XCTAssertEqual(deferred.deferredAssetCount, 1)
        let staleTextResults = try await store.search("旧文字", for: account)
        XCTAssertTrue(staleTextResults.isEmpty)

        let refreshed = try await store.synchronize(
            assets: [changed],
            outputs: [PhotoTextRecognitionOutput(assetID: "photo-a", recognizedText: "新文字")],
            for: account
        )
        XCTAssertEqual(refreshed.insertedCount, 1)
        let refreshedTextResults = try await store.search("新文字", for: account)
        XCTAssertEqual(refreshedTextResults.map(\.assetID), ["photo-a"])
    }

    func testOCRIndexIsAccountIsolatedAndCopiedIdentityFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let firstConsent = PhotoAnalysisQueueStore(directories: provider)
        let secondConsent = PhotoAnalysisQueueStore(directories: provider)
        let firstStore = PhotoTextIndexStore(directories: provider, pixelAnalysisConsent: firstConsent)
        let secondStore = PhotoTextIndexStore(directories: provider, pixelAnalysisConsent: secondConsent)
        _ = try await firstConsent.enablePixelAnalysis(for: firstAccount)
        _ = try await secondConsent.enablePixelAnalysis(for: secondAccount)
        _ = try await firstStore.enable(for: firstAccount)
        _ = try await firstStore.synchronize(
            assets: [makeAsset(id: "private-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [PhotoTextRecognitionOutput(assetID: "private-a", recognizedText: "账号 A 私密文字")],
            for: firstAccount
        )

        let secondInitialStatus = try await secondStore.status(for: secondAccount)
        XCTAssertEqual(secondInitialStatus, .disabled)
        let firstURL = try provider.directory(for: firstAccount, kind: .analysisQueue)
            .appendingPathComponent("vision-ocr-index-v1.json")
        let secondURL = try provider.directory(for: secondAccount, kind: .analysisQueue)
            .appendingPathComponent("vision-ocr-index-v1.json")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)

        do {
            _ = try await secondStore.status(for: secondAccount)
            XCTFail("A copied OCR index must not be readable by another account")
        } catch let error as PhotoTextIndexError {
            XCTAssertEqual(error, .accountIdentityMismatch)
        }
    }

    func testClearAndDisableAreIndependentButRevokingI2DeletesOCR() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoTextIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let asset = makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await pixelConsent.prepare(assets: [asset], for: account)
        _ = try await store.enable(for: account)
        _ = try await store.synchronize(
            assets: [asset],
            outputs: [PhotoTextRecognitionOutput(assetID: "photo-a", recognizedText: "可删除文字")],
            for: account
        )

        let cleared = try await store.clear(for: account)
        XCTAssertTrue(cleared.isEnabled)
        XCTAssertEqual(cleared.indexedAssetCount, 0)
        let statusAfterClear = try await pixelConsent.status(for: account)
        XCTAssertTrue(statusAfterClear.isPixelAnalysisAllowed)

        _ = try await store.synchronize(
            assets: [asset],
            outputs: [PhotoTextRecognitionOutput(assetID: "photo-a", recognizedText: "再次建立")],
            for: account
        )
        let disabled = try await store.disableAndDelete(for: account)
        XCTAssertEqual(disabled, .disabled)
        let statusAfterOCRDisable = try await pixelConsent.status(for: account)
        XCTAssertTrue(statusAfterOCRDisable.isPixelAnalysisAllowed)
        XCTAssertEqual(statusAfterOCRDisable.pendingAssetCount, 1)

        _ = try await store.enable(for: account)
        _ = try await store.synchronize(
            assets: [asset],
            outputs: [PhotoTextRecognitionOutput(assetID: "photo-a", recognizedText: "父许可删除")],
            for: account
        )
        let ocrURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("vision-ocr-index-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ocrURL.path))
        _ = try await pixelConsent.disableAndDelete(for: account)
        let statusAfterParentRevoke = try await store.status(for: account)
        let parentStatusAfterRevoke = try await pixelConsent.status(for: account)
        XCTAssertEqual(statusAfterParentRevoke, .disabled)
        XCTAssertEqual(parentStatusAfterRevoke, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ocrURL.path))
    }

    func testCorruptedOrDuplicateOCRIndexFailsClosedAndCanBeRemoved() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoTextIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        let indexURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("vision-ocr-index-v1.json")
        try Data("not-json".utf8).write(to: indexURL)

        do {
            _ = try await store.status(for: account)
            XCTFail("Corrupt OCR bytes must fail closed")
        } catch let error as PhotoTextIndexError {
            XCTAssertEqual(error, .corruptedIndex)
        }
        let resetStatus = try await store.resetCorruptedIndex(for: account)
        XCTAssertEqual(resetStatus, .disabled)

        let duplicate = PhotoTextIndexRecord(
            assetID: "duplicate",
            sourceVersion: "source-v1",
            processorRevision: PhotoTextIndexStore.processorRevision,
            recognizedText: "重复",
            indexedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let snapshot = PhotoTextIndexSnapshot(
            schemaVersion: PhotoTextIndexStore.schemaVersion,
            processorRevision: PhotoTextIndexStore.processorRevision,
            consentRevision: PhotoTextIndexStore.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastSynchronizedAt: duplicate.indexedAt,
            records: [duplicate, duplicate]
        )
        try JSONEncoder().encode(snapshot).write(to: indexURL)
        do {
            _ = try await store.status(for: account)
            XCTFail("Duplicate OCR asset identifiers must fail closed")
        } catch let error as PhotoTextIndexError {
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
        kind: LocalMediaKind
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
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
