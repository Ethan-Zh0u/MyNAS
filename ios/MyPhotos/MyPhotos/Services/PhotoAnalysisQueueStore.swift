import Foundation

/// I2's explicit, account-scoped pixel-analysis consent and work queue.
///
/// This actor intentionally has no PhotoKit image-manager, AVFoundation,
/// Vision, Core ML, networking or file-export dependency. It only receives
/// value-only `LocalPhotoAsset` metadata and persists identifiers plus source
/// versions. A later phase must add its own processor and tests before any
/// photo or video byte can be requested.
actor PhotoAnalysisQueueStore {
    nonisolated static let schemaVersion = 1
    nonisolated static let consentRevision = "local-pixel-analysis-consent-v1"

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

    func status(for account: AccountContext) throws -> PhotoAnalysisQueueStatus {
        guard let snapshot = try loadSnapshot(for: account) else {
            return .disabled
        }
        return status(for: snapshot)
    }

    /// Records the user's current-account permission. Enabling creates an
    /// empty queue only; it does not fetch PhotoKit assets or request pixels.
    @discardableResult
    func enablePixelAnalysis(for account: AccountContext) throws -> PhotoAnalysisQueueStatus {
        if let snapshot = try loadSnapshot(for: account) {
            return status(for: snapshot)
        }
        let snapshot = PhotoAnalysisQueueSnapshot(
            schemaVersion: Self.schemaVersion,
            consentRevision: Self.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastPreparedAt: nil,
            items: []
        )
        try save(snapshot, for: account)
        return status(for: snapshot)
    }

    /// Revoking consent removes every account-local artefact below this
    /// consent namespace, including dependent OCR and semantic-vector data.
    /// It never reaches into the system photo library, MyNAS storage, or the
    /// separately installed shared model package.
    @discardableResult
    func disableAndDelete(for account: AccountContext) throws -> PhotoAnalysisQueueStatus {
        try removeAnalysisArtifacts(for: account)
        return .disabled
    }

    /// Removes unreadable consent state and every dependent pixel-derived
    /// artefact without trusting any data in it.
    @discardableResult
    func resetCorruptedQueue(for account: AccountContext) throws -> PhotoAnalysisQueueStatus {
        try removeAnalysisArtifacts(for: account)
        return .disabled
    }

    /// Reconciles the queue from a value-only PhotoKit metadata snapshot. No
    /// image/video data is accepted by this API, which makes I2 unable to read
    /// pixels even after the user grants the separate permission.
    func prepare(
        assets: [LocalPhotoAsset],
        for account: AccountContext
    ) throws -> PhotoAnalysisQueueSyncResult {
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoAnalysisQueueError.pixelAnalysisNotAllowed
        }

        let existing = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.assetID, $0) })
        let uniqueAssets = Dictionary(
            assets.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let preparedAt = now()
        var insertedCount = 0
        var updatedCount = 0
        var unchangedCount = 0
        var items: [PhotoAnalysisQueueItem] = []
        items.reserveCapacity(uniqueAssets.count)

        for asset in uniqueAssets.values.sorted(by: { $0.localIdentifier < $1.localIdentifier }) {
            let sourceVersion = Self.sourceVersion(for: asset)
            let priorItem = existing[asset.localIdentifier]
            if let priorItem, priorItem.sourceVersion == sourceVersion {
                items.append(priorItem)
                unchangedCount += 1
            } else {
                items.append(
                    PhotoAnalysisQueueItem(
                        assetID: asset.localIdentifier,
                        sourceVersion: sourceVersion,
                        queuedAt: preparedAt
                    )
                )
                if priorItem == nil {
                    insertedCount += 1
                } else {
                    updatedCount += 1
                }
            }
        }

        let accessibleAssetIDs = Set(uniqueAssets.keys)
        let removedCount = existing.keys.filter { !accessibleAssetIDs.contains($0) }.count
        let prepared = PhotoAnalysisQueueSnapshot(
            schemaVersion: Self.schemaVersion,
            consentRevision: Self.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastPreparedAt: preparedAt,
            items: items
        )
        try save(prepared, for: account)
        return PhotoAnalysisQueueSyncResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            removedCount: removedCount,
            unchangedCount: unchangedCount,
            status: status(for: prepared)
        )
    }

    private func loadSnapshot(for account: AccountContext) throws -> PhotoAnalysisQueueSnapshot? {
        guard let url = try existingStorageURL(for: account) else { return nil }
        try rejectSymbolicLink(at: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotoAnalysisQueueError.corruptedQueue
        }
        let snapshot: PhotoAnalysisQueueSnapshot
        do {
            snapshot = try JSONDecoder().decode(PhotoAnalysisQueueSnapshot.self, from: data)
        } catch {
            throw PhotoAnalysisQueueError.corruptedQueue
        }
        guard snapshot.schemaVersion == Self.schemaVersion else {
            throw PhotoAnalysisQueueError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.consentRevision == Self.consentRevision else {
            throw PhotoAnalysisQueueError.unsupportedConsentRevision(snapshot.consentRevision)
        }
        guard snapshot.accountID == account.accountID,
              snapshot.serverID == account.serverID,
              snapshot.userID == account.userID else {
            throw PhotoAnalysisQueueError.accountIdentityMismatch
        }
        let itemIDs = snapshot.items.map(\.assetID)
        guard itemIDs.allSatisfy({ !$0.isEmpty }),
              Set(itemIDs).count == itemIDs.count,
              snapshot.items.allSatisfy({ !$0.sourceVersion.isEmpty }) else {
            throw PhotoAnalysisQueueError.corruptedQueue
        }
        return snapshot
    }

    private func save(
        _ snapshot: PhotoAnalysisQueueSnapshot,
        for account: AccountContext
    ) throws {
        let directory = try directories.directory(for: account, kind: .analysisQueue)
        try rejectSymbolicLink(at: directory.deletingLastPathComponent())
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent("pixel-analysis-consent-v1.json", isDirectory: false)
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
        let directory = root.appendingPathComponent(CacheDirectoryKind.analysisQueue.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent("pixel-analysis-consent-v1.json", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func removeAnalysisArtifacts(for account: AccountContext) throws {
        guard let root = try directories.existingRootDirectory(for: account) else { return }
        try rejectSymbolicLink(at: root)
        let directory = root.appendingPathComponent(
            CacheDirectoryKind.analysisQueue.rawValue,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else {
            throw PhotoAnalysisQueueError.unsafeStoragePath
        }
        try rejectSymbolicLink(at: directory)
        try fileManager.removeItem(at: directory)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw PhotoAnalysisQueueError.unsafeStoragePath
        }
    }

    private func status(for snapshot: PhotoAnalysisQueueSnapshot) -> PhotoAnalysisQueueStatus {
        PhotoAnalysisQueueStatus(
            isPixelAnalysisAllowed: true,
            pendingAssetCount: snapshot.items.count,
            lastPreparedAt: snapshot.lastPreparedAt
        )
    }

    private static func sourceVersion(for asset: LocalPhotoAsset) -> String {
        [
            asset.localIdentifier,
            dateBits(asset.creationDate),
            dateBits(asset.modificationDate),
            asset.mediaKind.rawValue,
            String(asset.pixelWidth),
            String(asset.pixelHeight),
            String(asset.duration.bitPattern),
        ].joined(separator: "|")
    }

    private static func dateBits(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "none"
    }
}
