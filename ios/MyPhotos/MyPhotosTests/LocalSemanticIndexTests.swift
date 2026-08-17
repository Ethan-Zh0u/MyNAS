import Foundation
import XCTest
@testable import MyPhotos

final class LocalSemanticIndexTests: XCTestCase {
    private let profile = try! LocalEmbeddingModelProfile(
        modelIdentifier: "qwen3-vl-embedding-2b",
        modelRevision: "feasibility-v1",
        dimension: 3,
        quantization: "int4"
    )

    func testEmbeddingNormalizesAndSemanticRankerReturnsBestPhotos() throws {
        let query = try LocalEmbeddingVector(normalizing: [2, 0, 0])
        let records = [
            record(id: "distant", values: [0, 1, 0]),
            record(id: "closest", values: [10, 1, 0]),
            record(id: "opposite", values: [-1, 0, 0]),
        ]

        XCTAssertEqual(query.values, [1, 0, 0])
        let hits = try LocalSemanticSearchRanker.rank(
            query: query,
            records: records,
            profile: profile,
            limit: 2,
            minimumScore: 0
        )
        XCTAssertEqual(hits.map(\.assetID), ["closest", "distant"])
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func testMalformedOrIncompatibleEmbeddingsFailClosed() throws {
        XCTAssertThrowsError(try LocalEmbeddingVector(normalizing: []))
        XCTAssertThrowsError(try LocalEmbeddingVector(normalizing: [0, 0, 0]))
        XCTAssertThrowsError(try LocalEmbeddingVector(normalizing: [.infinity, 0, 0]))

        let query = try LocalEmbeddingVector(normalizing: [1, 0, 0])
        let otherProfile = try LocalEmbeddingModelProfile(
            modelIdentifier: profile.modelIdentifier,
            modelRevision: "different",
            dimension: 3,
            quantization: profile.quantization
        )
        let incompatible = LocalPhotoEmbeddingRecord(
            assetID: "photo",
            sourceVersion: "source",
            modelProfile: otherProfile,
            embedding: query,
            indexedAt: Date()
        )
        XCTAssertThrowsError(
            try LocalSemanticSearchRanker.rank(
                query: query,
                records: [incompatible],
                profile: profile,
                limit: 10
            )
        )
    }

    func testStoredProfileIsRevalidatedWhenDecoded() {
        let invalidProfile = """
        {
          "modelIdentifier": "qwen3-vl-embedding-2b",
          "modelRevision": "feasibility-v1",
          "dimension": 0,
          "quantization": "int4"
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LocalEmbeddingModelProfile.self,
                from: Data(invalidProfile.utf8)
            )
        )
    }

    func testSemanticResultsJoinUnifiedSearchWithoutDuplicateTiles() {
        let metadata = PhotoSearchIndexRecord(
            assetID: "metadata-and-semantic",
            sourceVersion: "source-a",
            modelRevision: PhotoSearchIndexStore.modelRevision,
            mediaKind: .photo,
            creationDate: Date(timeIntervalSince1970: 1_800_000_000),
            isFavorite: false,
            isRAW: false,
            pixelWidth: 100,
            pixelHeight: 100,
            searchTerms: ["photo"],
            indexedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let merged = LocalUnifiedSearchResultMerger.merge(
            metadata: [metadata],
            recognizedText: [],
            semantic: [
                LocalSemanticSearchHit(assetID: "metadata-and-semantic", score: 0.99),
                LocalSemanticSearchHit(assetID: "semantic-only", score: 0.95),
            ]
        )

        XCTAssertEqual(merged.map(\.assetID), ["metadata-and-semantic", "semantic-only"])
    }

    private func record(id: String, values: [Float]) -> LocalPhotoEmbeddingRecord {
        LocalPhotoEmbeddingRecord(
            assetID: id,
            sourceVersion: "source-\(id)",
            modelProfile: profile,
            embedding: try! LocalEmbeddingVector(normalizing: values),
            indexedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
