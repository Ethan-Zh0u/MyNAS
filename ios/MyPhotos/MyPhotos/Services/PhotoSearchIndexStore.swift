import Foundation

/// A deletable, account-scoped local index. I1 intentionally accepts PhotoKit
/// metadata only; pixel analysis and model output arrive in later Phase I work.
actor PhotoSearchIndexStore {
    nonisolated static let schemaVersion = 1
    nonisolated static let modelRevision = "local-metadata-v1"

    private let directories: CacheDirectoryProvider
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        directories: CacheDirectoryProvider = CacheDirectoryProvider(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directories = directories
        self.fileManager = fileManager
        self.now = now
    }

    func status(for account: AccountContext) throws -> PhotoSearchIndexStatus {
        guard let snapshot = try loadSnapshot(for: account) else {
            return .disabled
        }
        return status(for: snapshot)
    }

    @discardableResult
    func enable(for account: AccountContext) throws -> PhotoSearchIndexStatus {
        if let snapshot = try loadSnapshot(for: account) {
            return status(for: snapshot)
        }
        let snapshot = PhotoSearchIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            modelRevision: Self.modelRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastSynchronizedAt: nil,
            records: []
        )
        try save(snapshot, for: account)
        return status(for: snapshot)
    }

    @discardableResult
    func disableAndDelete(for account: AccountContext) throws -> PhotoSearchIndexStatus {
        try removeIndexFile(for: account)
        return .disabled
    }

    @discardableResult
    func clear(for account: AccountContext) throws -> PhotoSearchIndexStatus {
        guard let snapshot = try loadSnapshot(for: account) else {
            return .disabled
        }
        let cleared = PhotoSearchIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            modelRevision: Self.modelRevision,
            accountID: snapshot.accountID,
            serverID: snapshot.serverID,
            userID: snapshot.userID,
            lastSynchronizedAt: nil,
            records: []
        )
        try save(cleared, for: account)
        return status(for: cleared)
    }

    /// Removes an unreadable index without trusting any data inside it. The
    /// exact account path is still resolved by CacheDirectoryProvider.
    @discardableResult
    func resetCorruptedIndex(for account: AccountContext) throws -> PhotoSearchIndexStatus {
        try removeIndexFile(for: account)
        return .disabled
    }

    func synchronize(
        assets: [LocalPhotoAsset],
        for account: AccountContext
    ) throws -> PhotoSearchIndexSyncResult {
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSearchIndexError.notEnabled
        }

        let canReuseExistingRecords = snapshot.modelRevision == Self.modelRevision
        let existing = canReuseExistingRecords
            ? Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.assetID, $0) })
            : [:]
        let uniqueAssets = Dictionary(
            assets.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        var insertedCount = 0
        var updatedCount = 0
        var unchangedCount = 0
        let indexedAt = now()
        var records: [PhotoSearchIndexRecord] = []
        records.reserveCapacity(uniqueAssets.count)

        for asset in uniqueAssets.values.sorted(by: { $0.localIdentifier < $1.localIdentifier }) {
            let sourceVersion = Self.sourceVersion(for: asset)
            if let record = existing[asset.localIdentifier],
               record.sourceVersion == sourceVersion {
                records.append(record)
                unchangedCount += 1
            } else {
                records.append(Self.record(for: asset, indexedAt: indexedAt))
                if existing[asset.localIdentifier] == nil {
                    insertedCount += 1
                } else {
                    updatedCount += 1
                }
            }
        }

        let currentAssetIDs = Set(uniqueAssets.keys)
        let removedCount = existing.keys.filter { !currentAssetIDs.contains($0) }.count
        let synchronized = PhotoSearchIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            modelRevision: Self.modelRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastSynchronizedAt: indexedAt,
            records: records
        )
        try save(synchronized, for: account)
        return PhotoSearchIndexSyncResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            removedCount: removedCount,
            unchangedCount: unchangedCount,
            status: status(for: synchronized)
        )
    }

    func search(
        _ query: String,
        for account: AccountContext
    ) throws -> [PhotoSearchIndexRecord] {
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSearchIndexError.notEnabled
        }
        guard snapshot.modelRevision == Self.modelRevision else {
            return []
        }
        let queryTerms = Self.normalizedQueryTerms(query)
        guard !queryTerms.isEmpty else { return [] }

        return snapshot.records
            .filter { record in
                queryTerms.allSatisfy { queryTerm in
                    record.searchTerms.contains { $0.contains(queryTerm) }
                }
            }
            .sorted {
                switch ($0.creationDate, $1.creationDate) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return $0.assetID < $1.assetID
                }
            }
    }

    private func loadSnapshot(for account: AccountContext) throws -> PhotoSearchIndexSnapshot? {
        guard let url = try existingStorageURL(for: account) else { return nil }
        try rejectSymbolicLink(at: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotoSearchIndexError.corruptedIndex
        }
        let snapshot: PhotoSearchIndexSnapshot
        do {
            snapshot = try JSONDecoder().decode(PhotoSearchIndexSnapshot.self, from: data)
        } catch {
            throw PhotoSearchIndexError.corruptedIndex
        }
        guard snapshot.schemaVersion == Self.schemaVersion else {
            throw PhotoSearchIndexError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.accountID == account.accountID,
              snapshot.serverID == account.serverID,
              snapshot.userID == account.userID else {
            throw PhotoSearchIndexError.accountIdentityMismatch
        }
        let recordIDs = snapshot.records.map(\.assetID)
        guard recordIDs.allSatisfy({ !$0.isEmpty }),
              Set(recordIDs).count == recordIDs.count,
              snapshot.records.allSatisfy({ record in
                  !record.sourceVersion.isEmpty
                      && record.modelRevision == snapshot.modelRevision
                      && record.pixelWidth >= 0
                      && record.pixelHeight >= 0
              }) else {
            throw PhotoSearchIndexError.corruptedIndex
        }
        return snapshot
    }

    private func save(
        _ snapshot: PhotoSearchIndexSnapshot,
        for account: AccountContext
    ) throws {
        let directory = try directories.directory(for: account, kind: .searchIndex)
        try rejectSymbolicLink(at: directory.deletingLastPathComponent())
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent("local-index-v1.json", isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try rejectSymbolicLink(at: url)
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func existingStorageURL(for account: AccountContext) throws -> URL? {
        guard let root = try directories.existingRootDirectory(for: account) else {
            return nil
        }
        try rejectSymbolicLink(at: root)
        let directory = root.appendingPathComponent(CacheDirectoryKind.searchIndex.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent("local-index-v1.json", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func removeIndexFile(for account: AccountContext) throws {
        guard let url = try existingStorageURL(for: account) else { return }
        try rejectSymbolicLink(at: url)
        try fileManager.removeItem(at: url)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw PhotoSearchIndexError.unsafeStoragePath
        }
    }

    private func status(for snapshot: PhotoSearchIndexSnapshot) -> PhotoSearchIndexStatus {
        PhotoSearchIndexStatus(
            isEnabled: true,
            indexedAssetCount: snapshot.records.count,
            lastSynchronizedAt: snapshot.lastSynchronizedAt,
            needsRebuild: snapshot.modelRevision != Self.modelRevision
        )
    }

    private static func record(
        for asset: LocalPhotoAsset,
        indexedAt: Date
    ) -> PhotoSearchIndexRecord {
        PhotoSearchIndexRecord(
            assetID: asset.localIdentifier,
            sourceVersion: sourceVersion(for: asset),
            modelRevision: modelRevision,
            mediaKind: asset.mediaKind,
            creationDate: asset.creationDate,
            isFavorite: asset.isFavorite,
            isRAW: asset.isRAW,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            searchTerms: searchTerms(for: asset),
            indexedAt: indexedAt
        )
    }

    private static func sourceVersion(for asset: LocalPhotoAsset) -> String {
        [
            asset.localIdentifier,
            dateBits(asset.creationDate),
            dateBits(asset.modificationDate),
            asset.mediaKind.rawValue,
            asset.isRAW ? "raw" : "standard",
            String(asset.pixelWidth),
            String(asset.pixelHeight),
            String(asset.duration.bitPattern, radix: 16),
            asset.isFavorite ? "favorite" : "regular",
            TimeZone.autoupdatingCurrent.identifier,
        ].joined(separator: "|")
    }

    private static func dateBits(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    private static func searchTerms(for asset: LocalPhotoAsset) -> [String] {
        var terms = [
            asset.mediaKind.rawValue,
            asset.mediaKind.displayName,
            "\(asset.pixelWidth)x\(asset.pixelHeight)",
            "\(asset.pixelWidth)×\(asset.pixelHeight)",
        ]
        switch asset.mediaKind {
        case .photo:
            terms.append(contentsOf: ["photo", "image", "图片", "相片"])
        case .video:
            terms.append(contentsOf: ["video", "影片"])
        case .livePhoto:
            terms.append(contentsOf: ["live photo", "live", "实况"])
        }
        if asset.isRAW {
            terms.append(contentsOf: ["raw", "proraw", "原始格式"])
        }
        if asset.isFavorite {
            terms.append(contentsOf: ["favorite", "favourite", "收藏", "已收藏"])
        }
        if let creationDate = asset.creationDate {
            let calendar = Calendar.autoupdatingCurrent
            let components = calendar.dateComponents([.year, .month, .day], from: creationDate)
            if let year = components.year {
                terms.append("\(year)")
                terms.append("\(year)年")
            }
            if let year = components.year, let month = components.month {
                terms.append(String(format: "%04d-%02d", year, month))
                terms.append("\(year)年\(month)月")
                terms.append("\(month)月")
            }
            if let year = components.year, let month = components.month, let day = components.day {
                terms.append(String(format: "%04d-%02d-%02d", year, month, day))
                terms.append("\(year)年\(month)月\(day)日")
                terms.append("\(month)月\(day)日")
            }
        }
        return Array(Set(terms.map(normalize))).sorted()
    }

    private static func normalizedQueryTerms(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
