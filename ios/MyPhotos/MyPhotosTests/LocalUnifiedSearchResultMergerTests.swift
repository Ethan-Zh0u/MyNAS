import Foundation
import XCTest
@testable import MyPhotos

final class LocalUnifiedSearchResultMergerTests: XCTestCase {
    func testMergeKeepsMetadataOrderAndShowsAnAssetOnlyOnceAcrossSources() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = [
            metadataRecord(id: "shared-photo", kind: .photo, now: now),
            metadataRecord(id: "video-only", kind: .video, now: now),
        ]
        let recognizedText = [
            textRecord(id: "shared-photo", now: now),
            textRecord(id: "ocr-only", now: now),
        ]

        let results = LocalUnifiedSearchResultMerger.merge(
            metadata: metadata,
            recognizedText: recognizedText
        )

        XCTAssertEqual(results.map(\.assetID), ["shared-photo", "video-only", "ocr-only"])
        XCTAssertEqual(results.map(\.mediaKind), [.photo, .video, .photo])
    }

    private func metadataRecord(
        id: String,
        kind: LocalMediaKind,
        now: Date
    ) -> PhotoSearchIndexRecord {
        PhotoSearchIndexRecord(
            assetID: id,
            sourceVersion: "source-v1",
            modelRevision: PhotoSearchIndexStore.modelRevision,
            mediaKind: kind,
            creationDate: now,
            isFavorite: false,
            isRAW: false,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            searchTerms: ["test"],
            indexedAt: now
        )
    }

    private func textRecord(id: String, now: Date) -> PhotoTextIndexRecord {
        PhotoTextIndexRecord(
            assetID: id,
            sourceVersion: "source-v1",
            processorRevision: PhotoTextIndexStore.processorRevision,
            recognizedText: "test",
            indexedAt: now
        )
    }
}
