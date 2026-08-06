import Foundation

/// A source-neutral local search hit. Search sources retain their own consent
/// and storage lifecycle; this value only decides how one photo appears once in
/// the Photos-home search grid.
nonisolated struct LocalUnifiedSearchResult: Identifiable, Equatable, Sendable {
    let assetID: String
    let mediaKind: LocalMediaKind

    var id: String { assetID }
}

nonisolated enum LocalUnifiedSearchResultMerger {
    /// Keep the metadata search order, then append OCR-only matches. An asset
    /// that matches both sources is deliberately one grid tile and one detail
    /// destination, never a duplicate result.
    static func merge(
        metadata: [PhotoSearchIndexRecord],
        recognizedText: [PhotoTextIndexRecord]
    ) -> [LocalUnifiedSearchResult] {
        var seenAssetIDs = Set<String>()
        var merged: [LocalUnifiedSearchResult] = []

        for record in metadata where seenAssetIDs.insert(record.assetID).inserted {
            merged.append(
                LocalUnifiedSearchResult(
                    assetID: record.assetID,
                    mediaKind: record.mediaKind
                )
            )
        }

        for record in recognizedText where seenAssetIDs.insert(record.assetID).inserted {
            merged.append(
                LocalUnifiedSearchResult(assetID: record.assetID, mediaKind: .photo)
            )
        }

        return merged
    }
}
