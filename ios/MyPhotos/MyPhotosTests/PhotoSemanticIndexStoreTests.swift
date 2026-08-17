import Foundation
import XCTest
@testable import MyPhotos

@MainActor
final class PhotoSemanticIndexStoreTests: XCTestCase {
    func testSemanticIndexRequiresPixelAnalysisThenExplicitSemanticEnable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let profile = try makeProfile()

        let initialStatus = try await store.status(for: account)
        XCTAssertEqual(initialStatus, .disabled)
        do {
            _ = try await store.enable(for: account, modelProfile: profile)
            XCTFail("Semantic indexing must not bypass I2 pixel-analysis consent")
        } catch let error as PhotoSemanticIndexError {
            XCTAssertEqual(error, .pixelAnalysisNotAllowed)
        }

        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        let enabled = try await store.enable(for: account, modelProfile: profile)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.indexedAssetCount, 0)
        XCTAssertEqual(enabled.modelProfile, profile)
    }

    func testSynchronizePersistsOnlyAccountBoundVectorMetadataAndSearches() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(
            directories: provider,
            now: { now },
            pixelAnalysisConsent: pixelConsent
        )
        let profile = try makeProfile()
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: profile)

        let result = try await store.synchronize(
            assets: [
                makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo),
                makeAsset(id: "video-b", date: date(2026, 8, 5), kind: .video),
            ],
            outputs: [try output("photo-a", values: [4, 0, 0])],
            modelProfile: profile,
            for: account
        )

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.deferredAssetCount, 0)
        XCTAssertEqual(result.status.indexedAssetCount, 1)
        XCTAssertEqual(result.status.lastSynchronizedAt, now)
        let matches = try await store.search(
            query: try vector([2, 0, 0]),
            modelProfile: profile,
            minimumScore: 0,
            for: account
        )
        XCTAssertEqual(matches.map(\.assetID), ["photo-a"])
        let topScore = try XCTUnwrap(matches.first?.score)
        XCTAssertEqual(topScore, 1, accuracy: 0.0001)

        let indexURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("local-semantic-index-v1.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        let records = raw?["records"] as? [[String: Any]]
        XCTAssertEqual(
            Set(records?.flatMap(\.keys) ?? []),
            ["assetID", "sourceVersion", "modelProfile", "embedding", "indexedAt"]
        )
        XCTAssertFalse(raw?.keys.contains("imageData") == true)
        XCTAssertFalse(raw?.keys.contains("thumbnail") == true)
        XCTAssertFalse(raw?.keys.contains("fileURL") == true)
        XCTAssertFalse(raw?.keys.contains("photoKitAsset") == true)
    }

    func testCurrentRecordsExposeOnlyValidatedAccountBoundVectorValues() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let profile = try makeProfile()
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: profile)
        _ = try await store.synchronize(
            assets: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [try output("photo-a", values: [1, 0, 0])],
            modelProfile: profile,
            for: account
        )

        let records = try await store.currentRecords(modelProfile: profile, for: account)

        XCTAssertEqual(records.map(\.assetID), ["photo-a"])
        XCTAssertEqual(records.first?.embedding.dimension, profile.dimension)
    }

    func testSynchronizationReusesCurrentVectorsAndDropsChangedPhotoWithoutNewOutput() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let profile = try makeProfile()
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: profile)

        let first = makeAsset(id: "photo-a", date: date(2026, 8, 1), kind: .photo)
        _ = try await store.synchronize(
            assets: [first],
            outputs: [try output("photo-a", values: [1, 0, 0])],
            modelProfile: profile,
            for: account
        )

        let unchanged = try await store.synchronize(
            assets: [first],
            outputs: [],
            modelProfile: profile,
            for: account
        )
        XCTAssertEqual(unchanged.unchangedCount, 1)
        XCTAssertEqual(unchanged.deferredAssetCount, 0)
        let unchangedResults = try await store.search(
            query: try vector([1, 0, 0]),
            modelProfile: profile,
            minimumScore: 0,
            for: account
        )
        XCTAssertEqual(unchangedResults.count, 1)

        let changed = makeAsset(
            id: "photo-a",
            date: date(2026, 8, 1),
            modificationDate: date(2026, 8, 6),
            kind: .photo
        )
        let deferred = try await store.synchronize(
            assets: [changed],
            outputs: [],
            modelProfile: profile,
            for: account
        )
        XCTAssertEqual(deferred.updatedCount, 0)
        XCTAssertEqual(deferred.removedCount, 1)
        XCTAssertEqual(deferred.deferredAssetCount, 1)
        let staleResults = try await store.search(
            query: try vector([1, 0, 0]),
            modelProfile: profile,
            minimumScore: 0,
            for: account
        )
        XCTAssertTrue(staleResults.isEmpty)

        let refreshed = try await store.synchronize(
            assets: [changed],
            outputs: [try output("photo-a", values: [0, 1, 0])],
            modelProfile: profile,
            for: account
        )
        XCTAssertEqual(refreshed.insertedCount, 1)
        let refreshedResults = try await store.search(
            query: try vector([0, 1, 0]),
            modelProfile: profile,
            minimumScore: 0,
            for: account
        )
        XCTAssertEqual(refreshedResults.map(\.assetID), ["photo-a"])
    }

    func testSynchronizationPreflightOnlyReportsAddedChangedOrRemovedStaticPhotos() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let profile = try makeProfile()
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: profile)

        let original = makeAsset(id: "photo-a", date: date(2026, 8, 1), kind: .photo)
        _ = try await store.synchronize(
            assets: [original],
            outputs: [try output("photo-a", values: [1, 0, 0])],
            modelProfile: profile,
            for: account
        )

        let unchangedNeedsSynchronization = try await store.needsSynchronization(
            from: [original, makeAsset(id: "video-a", date: date(2026, 8, 1), kind: .video)],
            modelProfile: profile,
            for: account
        )
        XCTAssertFalse(unchangedNeedsSynchronization)

        let changed = makeAsset(
            id: "photo-a",
            date: date(2026, 8, 1),
            modificationDate: date(2026, 8, 2),
            kind: .photo
        )
        let changedNeedsSynchronization = try await store.needsSynchronization(
            from: [changed],
            modelProfile: profile,
            for: account
        )
        XCTAssertTrue(changedNeedsSynchronization)
        let addedNeedsSynchronization = try await store.needsSynchronization(
            from: [original, makeAsset(id: "photo-b", date: date(2026, 8, 1), kind: .photo)],
            modelProfile: profile,
            for: account
        )
        XCTAssertTrue(addedNeedsSynchronization)
        let removedNeedsSynchronization = try await store.needsSynchronization(
            from: [],
            modelProfile: profile,
            for: account
        )
        XCTAssertTrue(removedNeedsSynchronization)
    }

    func testChangingModelProfileRequiresExplicitRebuildAndNeverMixesVectors() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let originalProfile = try makeProfile(revision: "r1")
        let replacementProfile = try makeProfile(revision: "r2")
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: originalProfile)
        _ = try await store.synchronize(
            assets: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [try output("photo-a", values: [1, 0, 0])],
            modelProfile: originalProfile,
            for: account
        )

        do {
            _ = try await store.assetsNeedingEmbedding(
                from: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
                modelProfile: replacementProfile,
                for: account
            )
            XCTFail("A different model profile must never reuse the old vector space")
        } catch let error as PhotoSemanticIndexError {
            XCTAssertEqual(error, .modelProfileMismatch)
        }

        let rebuilt = try await store.enable(for: account, modelProfile: replacementProfile)
        XCTAssertTrue(rebuilt.isEnabled)
        XCTAssertEqual(rebuilt.modelProfile, replacementProfile)
        XCTAssertEqual(rebuilt.indexedAssetCount, 0)
        let replacementCandidates = try await store.assetsNeedingEmbedding(
            from: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
            modelProfile: replacementProfile,
            for: account
        )
        XCTAssertEqual(replacementCandidates.map(\.localIdentifier), ["photo-a"])
    }

    func testIndexIsAccountIsolatedAndCopiedIdentityFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let firstAccount = makeAccount(id: "account-a", userID: "user-a")
        let secondAccount = makeAccount(id: "account-b", userID: "user-b")
        let firstConsent = PhotoAnalysisQueueStore(directories: provider)
        let secondConsent = PhotoAnalysisQueueStore(directories: provider)
        let firstStore = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: firstConsent)
        let secondStore = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: secondConsent)
        let profile = try makeProfile()
        _ = try await firstConsent.enablePixelAnalysis(for: firstAccount)
        _ = try await secondConsent.enablePixelAnalysis(for: secondAccount)
        _ = try await firstStore.enable(for: firstAccount, modelProfile: profile)
        _ = try await firstStore.synchronize(
            assets: [makeAsset(id: "private-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [try output("private-a", values: [1, 0, 0])],
            modelProfile: profile,
            for: firstAccount
        )

        let firstURL = try provider.directory(for: firstAccount, kind: .analysisQueue)
            .appendingPathComponent("local-semantic-index-v1.json")
        let secondURL = try provider.directory(for: secondAccount, kind: .analysisQueue)
            .appendingPathComponent("local-semantic-index-v1.json")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)

        do {
            _ = try await secondStore.status(for: secondAccount)
            XCTFail("A copied semantic index must not be readable by another account")
        } catch let error as PhotoSemanticIndexError {
            XCTAssertEqual(error, .accountIdentityMismatch)
        }
    }

    func testParentConsentRevocationRemovesSemanticIndex() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let profile = try makeProfile()
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: profile)
        _ = try await store.synchronize(
            assets: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [try output("photo-a", values: [1, 0, 0])],
            modelProfile: profile,
            for: account
        )
        let indexURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("local-semantic-index-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        _ = try await pixelConsent.disableAndDelete(for: account)
        let statusAfterParentRevoke = try await store.status(for: account)
        XCTAssertEqual(statusAfterParentRevoke, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
    }

    func testParentConsentRevocationDeletesOCRAndSemanticArtifactsTogether() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let semanticStore = PhotoSemanticIndexStore(
            directories: provider,
            pixelAnalysisConsent: pixelConsent
        )
        let textStore = PhotoTextIndexStore(
            directories: provider,
            pixelAnalysisConsent: pixelConsent
        )
        let profile = try makeProfile()

        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await semanticStore.enable(for: account, modelProfile: profile)
        _ = try await semanticStore.synchronize(
            assets: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [try output("photo-a", values: [1, 0, 0])],
            modelProfile: profile,
            for: account
        )
        _ = try await textStore.enable(for: account)
        _ = try await textStore.synchronize(
            assets: [makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)],
            outputs: [
                PhotoTextRecognitionOutput(
                    assetID: "photo-a",
                    recognizedText: "本地文字"
                ),
            ],
            for: account
        )

        let directory = try provider.directory(for: account, kind: .analysisQueue)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("vision-ocr-index-v1.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("local-semantic-index-v1.json").path
            )
        )

        _ = try await pixelConsent.disableAndDelete(for: account)

        let textStatus = try await textStore.status(for: account)
        let semanticStatus = try await semanticStore.status(for: account)
        XCTAssertEqual(textStatus, .disabled)
        XCTAssertEqual(semanticStatus, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInvalidOutputsAndCorruptIndexFailClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount(id: "account-a", userID: "user-a")
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let profile = try makeProfile()
        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await store.enable(for: account, modelProfile: profile)
        let photo = makeAsset(id: "photo-a", date: date(2026, 8, 5), kind: .photo)

        do {
            _ = try await store.synchronize(
                assets: [photo],
                outputs: [try output("unknown", values: [1, 0, 0])],
                modelProfile: profile,
                for: account
            )
            XCTFail("Outputs for unavailable assets must not enter the index")
        } catch let error as PhotoSemanticIndexError {
            XCTAssertEqual(error, .invalidEmbeddingOutput)
        }

        let indexURL = try provider.directory(for: account, kind: .analysisQueue)
            .appendingPathComponent("local-semantic-index-v1.json")
        try Data("not-json".utf8).write(to: indexURL)
        do {
            _ = try await store.status(for: account)
            XCTFail("Corrupt vector bytes must fail closed")
        } catch let error as PhotoSemanticIndexError {
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

    private func makeProfile(revision: String = "r1") throws -> LocalEmbeddingModelProfile {
        try LocalEmbeddingModelProfile(
            modelIdentifier: "Qwen3-VL-Embedding-2B",
            modelRevision: revision,
            dimension: 3,
            quantization: "int8"
        )
    }

    private func output(_ assetID: String, values: [Float]) throws -> LocalSemanticEmbeddingOutput {
        LocalSemanticEmbeddingOutput(assetID: assetID, embedding: try vector(values))
    }

    private func vector(_ values: [Float]) throws -> LocalEmbeddingVector {
        try LocalEmbeddingVector(normalizing: values)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
