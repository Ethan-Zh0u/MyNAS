import Foundation
import UIKit

/// The Photos boundary used by semantic indexing. It intentionally yields a
/// short-lived, bounded image rather than exposing PhotoKit or a file URL to
/// the model/store pipeline.
@MainActor
protocol LocalSemanticImageSource: AnyObject {
    func semanticIndexImage(for localIdentifier: String) async -> PhotoImageResult
}

/// The foreground lifecycle needs the same constrained image boundary plus a
/// value-only snapshot of the currently accessible library. It must not expose
/// PhotoKit objects, URLs, or an iCloud-download control to semantic indexing.
@MainActor
protocol LocalSemanticLibrarySource: LocalSemanticImageSource {
    func allAccessibleAssets() async -> [LocalPhotoAsset]
}

extension PhotoLibraryClient: LocalSemanticLibrarySource {}

/// Contract for the downloaded, on-device embedding runtime. The first
/// production implementation will adapt the selected Qwen/MNN runtime; no
/// network API or system-intelligence dependency belongs in this protocol.
@MainActor
protocol LocalSemanticEmbeddingEngine: AnyObject {
    var modelProfile: LocalEmbeddingModelProfile { get }

    func embed(text: String) async throws -> LocalEmbeddingVector
    func embed(image: UIImage) async throws -> LocalEmbeddingVector
}

/// Owns the short-lived image-to-vector flow. Its persistence dependency only
/// receives value outputs, so neither PhotoKit objects nor image bytes can be
/// retained by the semantic index.
@MainActor
final class LocalSemanticIndexCoordinator {
    private let store: PhotoSemanticIndexStore
    private let engine: any LocalSemanticEmbeddingEngine

    init(
        store: PhotoSemanticIndexStore = PhotoSemanticIndexStore(),
        engine: any LocalSemanticEmbeddingEngine
    ) {
        self.store = store
        self.engine = engine
    }

    func status(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try await store.status(for: account)
    }

    @discardableResult
    func enable(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try await store.enable(for: account, modelProfile: engine.modelProfile)
    }

    @discardableResult
    func synchronize(
        assets: [LocalPhotoAsset],
        for account: AccountContext,
        imageSource: any LocalSemanticImageSource
    ) async throws -> PhotoSemanticIndexSyncResult {
        let modelProfile = engine.modelProfile
        let candidates = try await store.assetsNeedingEmbedding(
            from: assets,
            modelProfile: modelProfile,
            for: account
        )
        var outputs: [LocalSemanticEmbeddingOutput] = []
        outputs.reserveCapacity(candidates.count)

        for asset in candidates {
            try Task.checkCancellation()
            let imageResult = await imageSource.semanticIndexImage(for: asset.localIdentifier)
            guard let image = imageResult.image else { continue }
            // Keep each input image scoped to this iteration. Only the
            // validated vector may survive in `outputs`. An inference error is
            // not equivalent to an iCloud-only or otherwise unavailable image:
            // aborting preserves the prior index and lets the UI explain the
            // actual model/runtime failure.
            let embedding = try await engine.embed(image: image)
            outputs.append(
                LocalSemanticEmbeddingOutput(
                    assetID: asset.localIdentifier,
                    embedding: embedding
                )
            )
        }

        return try await store.synchronize(
            assets: assets,
            outputs: outputs,
            modelProfile: modelProfile,
            for: account
        )
    }

    func search(
        _ query: String,
        limit: Int = 120,
        minimumScore: Float = 0.2,
        for account: AccountContext
    ) async throws -> [LocalSemanticSearchHit] {
        let canonicalQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalQuery.isEmpty else { return [] }
        let modelProfile = engine.modelProfile
        let embedding = try await engine.embed(text: canonicalQuery)
        return try await store.search(
            query: embedding,
            modelProfile: modelProfile,
            limit: limit,
            minimumScore: minimumScore,
            for: account
        )
    }

    @discardableResult
    func clear(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try await store.clear(for: account)
    }

    @discardableResult
    func disableAndDelete(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try await store.disableAndDelete(for: account)
    }
}
