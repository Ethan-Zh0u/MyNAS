import Foundation
import UIKit
import XCTest
@testable import MyPhotos

@MainActor
final class LocalSemanticIndexCoordinatorTests: XCTestCase {
    func testCoordinatorUsesBoundedImageSourceAndPersistsOnlyVectors() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount()
        let profile = try LocalEmbeddingModelProfile(
            modelIdentifier: "Qwen3-VL-Embedding-2B",
            modelRevision: "test-r1",
            dimension: 3,
            quantization: "int8"
        )
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let engine = try StubEmbeddingEngine(
            profile: profile,
            textEmbedding: [1, 0, 0],
            imageEmbedding: [1, 0, 0]
        )
        let source = StubImageSource(availableAssetIDs: ["photo-a"])
        let coordinator = LocalSemanticIndexCoordinator(store: store, engine: engine)
        let assets = [
            makeAsset(id: "photo-a", kind: .photo),
            makeAsset(id: "video-b", kind: .video),
            makeAsset(id: "live-c", kind: .livePhoto),
        ]

        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await coordinator.enable(for: account)
        let synchronization = try await coordinator.synchronize(
            assets: assets,
            for: account,
            imageSource: source
        )

        XCTAssertEqual(synchronization.insertedCount, 1)
        XCTAssertEqual(source.requestedAssetIDs, ["photo-a"])
        XCTAssertEqual(engine.imageCallCount, 1)
        let results = try await coordinator.search("狐狸", minimumScore: 0, for: account)
        XCTAssertEqual(results.map(\.assetID), ["photo-a"])
        XCTAssertEqual(engine.textCallCount, 1)
    }

    func testEmptySearchDoesNotInvokeModel() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let profile = try LocalEmbeddingModelProfile(
            modelIdentifier: "Qwen3-VL-Embedding-2B",
            modelRevision: "test-r1",
            dimension: 3,
            quantization: "int8"
        )
        let engine = try StubEmbeddingEngine(
            profile: profile,
            textEmbedding: [1, 0, 0],
            imageEmbedding: [1, 0, 0]
        )
        let coordinator = LocalSemanticIndexCoordinator(
            store: PhotoSemanticIndexStore(directories: provider),
            engine: engine
        )

        let results = try await coordinator.search("  \n", for: makeAccount())
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(engine.textCallCount, 0)
    }

    func testInferenceFailurePreservesExistingVectorsAndPropagatesTheRuntimeError() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CacheDirectoryProvider(applicationSupportRootOverride: root)
        let account = makeAccount()
        let profile = try LocalEmbeddingModelProfile(
            modelIdentifier: "Qwen3-VL-Embedding-2B",
            modelRevision: "test-r1",
            dimension: 3,
            quantization: "int8"
        )
        let pixelConsent = PhotoAnalysisQueueStore(directories: provider)
        let store = PhotoSemanticIndexStore(directories: provider, pixelAnalysisConsent: pixelConsent)
        let source = StubImageSource(availableAssetIDs: ["photo-a"])
        let workingEngine = try StubEmbeddingEngine(
            profile: profile,
            textEmbedding: [1, 0, 0],
            imageEmbedding: [1, 0, 0]
        )
        let workingCoordinator = LocalSemanticIndexCoordinator(store: store, engine: workingEngine)
        let originalAsset = makeAsset(id: "photo-a", kind: .photo)

        _ = try await pixelConsent.enablePixelAnalysis(for: account)
        _ = try await workingCoordinator.enable(for: account)
        _ = try await workingCoordinator.synchronize(
            assets: [originalAsset],
            for: account,
            imageSource: source
        )
        let recordsBeforeFailure = try await store.currentRecords(
            modelProfile: profile,
            for: account
        )

        let failingEngine = try StubEmbeddingEngine(
            profile: profile,
            textEmbedding: [1, 0, 0],
            imageEmbedding: [1, 0, 0],
            imageError: .inferenceFailed
        )
        let failingCoordinator = LocalSemanticIndexCoordinator(store: store, engine: failingEngine)
        let changedAsset = makeAsset(
            id: "photo-a",
            kind: .photo,
            modificationDate: Date(timeIntervalSince1970: 1_800_000_001)
        )

        do {
            _ = try await failingCoordinator.synchronize(
                assets: [changedAsset],
                for: account,
                imageSource: source
            )
            XCTFail("A model inference error must not be converted to a deferred image")
        } catch let error as LocalSemanticEmbeddingRuntimeError {
            XCTAssertEqual(error, .inferenceFailed)
        }

        let recordsAfterFailure = try await store.currentRecords(
            modelProfile: profile,
            for: account
        )
        XCTAssertEqual(recordsAfterFailure, recordsBeforeFailure)
    }

    private func makeTemporaryRoot() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    private func makeAccount() -> AccountContext {
        AccountContext(
            accountID: "account-a",
            serverID: "server-1",
            serverURL: URL(string: "https://mynas.example.invalid"),
            userID: "user-a",
            authenticationIdentity: "user-a",
            displayName: "user-a",
            avatarVersion: nil,
            selectedVolumeID: nil,
            serverCapabilities: .localOnly,
            availableVolumes: [],
            encryptionNamespace: nil
        )
    }

    private func makeAsset(
        id: String,
        kind: LocalMediaKind,
        modificationDate: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> LocalPhotoAsset {
        LocalPhotoAsset(
            localIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 1_800_000_000),
            modificationDate: modificationDate,
            mediaKind: kind,
            isRAW: false,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: kind == .video ? 12 : 0,
            isFavorite: false
        )
    }
}

@MainActor
private final class StubImageSource: LocalSemanticImageSource {
    private let availableAssetIDs: Set<String>
    private(set) var requestedAssetIDs: [String] = []

    init(availableAssetIDs: Set<String>) {
        self.availableAssetIDs = availableAssetIDs
    }

    func semanticIndexImage(for localIdentifier: String) async -> PhotoImageResult {
        requestedAssetIDs.append(localIdentifier)
        return PhotoImageResult(
            image: availableAssetIDs.contains(localIdentifier) ? UIImage() : nil,
            isCloudOnly: false
        )
    }
}

@MainActor
private final class StubEmbeddingEngine: LocalSemanticEmbeddingEngine {
    let modelProfile: LocalEmbeddingModelProfile
    private let textEmbedding: LocalEmbeddingVector
    private let imageEmbedding: LocalEmbeddingVector
    private let imageError: LocalSemanticEmbeddingRuntimeError?
    private(set) var textCallCount = 0
    private(set) var imageCallCount = 0

    init(
        profile: LocalEmbeddingModelProfile,
        textEmbedding: [Float],
        imageEmbedding: [Float],
        imageError: LocalSemanticEmbeddingRuntimeError? = nil
    ) throws {
        modelProfile = profile
        self.textEmbedding = try LocalEmbeddingVector(normalizing: textEmbedding)
        self.imageEmbedding = try LocalEmbeddingVector(normalizing: imageEmbedding)
        self.imageError = imageError
    }

    func embed(text: String) async throws -> LocalEmbeddingVector {
        textCallCount += 1
        return textEmbedding
    }

    func embed(image: UIImage) async throws -> LocalEmbeddingVector {
        imageCallCount += 1
        if let imageError { throw imageError }
        return imageEmbedding
    }
}
