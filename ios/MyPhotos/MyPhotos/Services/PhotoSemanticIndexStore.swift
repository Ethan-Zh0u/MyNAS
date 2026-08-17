import Foundation

/// Account-scoped semantic-vector storage. This actor never receives image
/// bytes, UIImage, PHAsset, thumbnails, model handles or file URLs. A UI-side
/// coordinator owns the short-lived image/model boundary and supplies only
/// validated value outputs after explicit consent.
actor PhotoSemanticIndexStore {
    nonisolated static let schemaVersion = 1
    nonisolated static let consentRevision = "local-semantic-index-consent-v1"
    private static let filename = "local-semantic-index-v1.json"
    private static let retiredCharacterCatalogFilename = "local-character-identities-v1.json"

    private let directories: CacheDirectoryProvider
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let pixelAnalysisConsent: PhotoAnalysisQueueStore

    init(
        directories: CacheDirectoryProvider = CacheDirectoryProvider(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        pixelAnalysisConsent: PhotoAnalysisQueueStore = PhotoAnalysisQueueStore()
    ) {
        self.directories = directories
        self.fileManager = fileManager
        self.now = now
        self.pixelAnalysisConsent = pixelAnalysisConsent
    }

    func status(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        guard try await hasPixelAnalysisConsent(for: account) else {
            try removeIndexFile(for: account)
            try removeRetiredCharacterCatalog(for: account)
            return .disabled
        }
        try removeRetiredCharacterCatalog(for: account)
        guard let snapshot = try loadSnapshot(for: account) else { return .disabled }
        return status(for: snapshot)
    }

    /// Records the separate semantic-index opt-in. Changing model profile
    /// replaces the old vector space rather than mixing incomparable vectors.
    @discardableResult
    func enable(
        for account: AccountContext,
        modelProfile: LocalEmbeddingModelProfile
    ) async throws -> PhotoSemanticIndexStatus {
        try await requirePixelAnalysisConsent(for: account)
        try removeRetiredCharacterCatalog(for: account)
        if let snapshot = try loadSnapshot(for: account) {
            if snapshot.modelProfile == modelProfile {
                return status(for: snapshot)
            }
        }

        let enabled = PhotoSemanticIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            consentRevision: Self.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            modelProfile: modelProfile,
            lastSynchronizedAt: nil,
            records: []
        )
        try save(enabled, for: account)
        return status(for: enabled)
    }

    @discardableResult
    func clear(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            try removeRetiredCharacterCatalog(for: account)
            return .disabled
        }
        try removeRetiredCharacterCatalog(for: account)
        let cleared = PhotoSemanticIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            consentRevision: Self.consentRevision,
            accountID: snapshot.accountID,
            serverID: snapshot.serverID,
            userID: snapshot.userID,
            modelProfile: snapshot.modelProfile,
            lastSynchronizedAt: nil,
            records: []
        )
        try save(cleared, for: account)
        return status(for: cleared)
    }

    /// Revokes semantic storage. I2's parent consent and its other indexes
    /// remain independently controlled.
    @discardableResult
    func disableAndDelete(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try removeRetiredCharacterCatalog(for: account)
        try removeIndexFile(for: account)
        return .disabled
    }

    @discardableResult
    func resetCorruptedIndex(for account: AccountContext) async throws -> PhotoSemanticIndexStatus {
        try removeRetiredCharacterCatalog(for: account)
        try removeIndexFile(for: account)
        return .disabled
    }

    func synchronize(
        assets: [LocalPhotoAsset],
        outputs: [LocalSemanticEmbeddingOutput],
        modelProfile: LocalEmbeddingModelProfile,
        for account: AccountContext
    ) async throws -> PhotoSemanticIndexSyncResult {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSemanticIndexError.notEnabled
        }
        guard snapshot.modelProfile == modelProfile else {
            throw PhotoSemanticIndexError.modelProfileMismatch
        }

        let staticImages = Self.uniqueStaticImages(from: assets)
        let outputByID = try Self.outputsByID(
            outputs,
            allowedAssetIDs: Set(staticImages.keys),
            modelProfile: modelProfile
        )
        let existing = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.assetID, $0) })
        let indexedAt = now()
        var records: [LocalPhotoEmbeddingRecord] = []
        records.reserveCapacity(staticImages.count)
        var insertedCount = 0
        var updatedCount = 0
        var unchangedCount = 0
        var deferredAssetCount = 0
        var invalidatedRecordCount = 0

        for asset in staticImages.values.sorted(by: { $0.localIdentifier < $1.localIdentifier }) {
            let sourceVersion = Self.sourceVersion(for: asset)
            if let existingRecord = existing[asset.localIdentifier],
               existingRecord.sourceVersion == sourceVersion {
                records.append(existingRecord)
                unchangedCount += 1
                continue
            }

            guard let output = outputByID[asset.localIdentifier] else {
                if existing[asset.localIdentifier] != nil {
                    invalidatedRecordCount += 1
                }
                deferredAssetCount += 1
                continue
            }
            records.append(
                LocalPhotoEmbeddingRecord(
                    assetID: asset.localIdentifier,
                    sourceVersion: sourceVersion,
                    modelProfile: modelProfile,
                    embedding: output.embedding,
                    indexedAt: indexedAt
                )
            )
            if existing[asset.localIdentifier] == nil {
                insertedCount += 1
            } else {
                updatedCount += 1
            }
        }

        let removedFromScope = existing.keys.filter { !staticImages.keys.contains($0) }.count
        let synchronized = PhotoSemanticIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            consentRevision: Self.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            modelProfile: modelProfile,
            lastSynchronizedAt: indexedAt,
            records: records
        )
        try save(synchronized, for: account)
        return PhotoSemanticIndexSyncResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            removedCount: removedFromScope + invalidatedRecordCount,
            unchangedCount: unchangedCount,
            deferredAssetCount: deferredAssetCount,
            status: status(for: synchronized)
        )
    }

    /// Returns only current static images without a current vector in this
    /// exact model space, so the model never sees pixels for unchanged photos.
    func assetsNeedingEmbedding(
        from assets: [LocalPhotoAsset],
        modelProfile: LocalEmbeddingModelProfile,
        for account: AccountContext
    ) async throws -> [LocalPhotoAsset] {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSemanticIndexError.notEnabled
        }
        guard snapshot.modelProfile == modelProfile else {
            throw PhotoSemanticIndexError.modelProfileMismatch
        }
        let existing = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.assetID, $0) })
        return Self.uniqueStaticImages(from: assets)
            .values
            .filter { existing[$0.localIdentifier]?.sourceVersion != Self.sourceVersion(for: $0) }
            .sorted { $0.localIdentifier < $1.localIdentifier }
    }

    /// Checks whether the persisted vector snapshot differs from the current
    /// accessible static-image snapshot without loading an image or a model.
    /// Foreground lifecycle notifications use this to avoid repeatedly
    /// validating and opening the large local package when no photo changed.
    func needsSynchronization(
        from assets: [LocalPhotoAsset],
        modelProfile: LocalEmbeddingModelProfile,
        for account: AccountContext
    ) async throws -> Bool {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSemanticIndexError.notEnabled
        }
        guard snapshot.modelProfile == modelProfile else {
            throw PhotoSemanticIndexError.modelProfileMismatch
        }

        let staticImages = Self.uniqueStaticImages(from: assets)
        let existing = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.assetID, $0) })
        guard Set(existing.keys) == Set(staticImages.keys) else { return true }
        return staticImages.values.contains {
            existing[$0.localIdentifier]?.sourceVersion != Self.sourceVersion(for: $0)
        }
    }

    func search(
        query: LocalEmbeddingVector,
        modelProfile: LocalEmbeddingModelProfile,
        limit: Int = 120,
        minimumScore: Float = 0.2,
        for account: AccountContext
    ) async throws -> [LocalSemanticSearchHit] {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSemanticIndexError.notEnabled
        }
        guard snapshot.modelProfile == modelProfile else {
            throw PhotoSemanticIndexError.modelProfileMismatch
        }
        return try LocalSemanticSearchRanker.rank(
            query: query,
            records: snapshot.records,
            profile: modelProfile,
            limit: limit,
            minimumScore: minimumScore
        )
    }

    /// Reads only the current account's already validated, value-only vectors.
    /// It does not request PhotoKit images, load a model, or expose the storage
    /// URL.
    func currentRecords(
        modelProfile: LocalEmbeddingModelProfile,
        for account: AccountContext
    ) async throws -> [LocalPhotoEmbeddingRecord] {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoSemanticIndexError.notEnabled
        }
        guard snapshot.modelProfile == modelProfile else {
            throw PhotoSemanticIndexError.modelProfileMismatch
        }
        return snapshot.records.sorted { $0.assetID < $1.assetID }
    }

    private func hasPixelAnalysisConsent(for account: AccountContext) async throws -> Bool {
        try await pixelAnalysisConsent.status(for: account).isPixelAnalysisAllowed
    }

    private func requirePixelAnalysisConsent(for account: AccountContext) async throws {
        guard try await hasPixelAnalysisConsent(for: account) else {
            throw PhotoSemanticIndexError.pixelAnalysisNotAllowed
        }
    }

    private func loadSnapshot(for account: AccountContext) throws -> PhotoSemanticIndexSnapshot? {
        guard let url = try existingStorageURL(for: account) else { return nil }
        try rejectSymbolicLink(at: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotoSemanticIndexError.corruptedIndex
        }
        let snapshot: PhotoSemanticIndexSnapshot
        do {
            snapshot = try JSONDecoder().decode(PhotoSemanticIndexSnapshot.self, from: data)
        } catch {
            throw PhotoSemanticIndexError.corruptedIndex
        }
        guard snapshot.schemaVersion == Self.schemaVersion else {
            throw PhotoSemanticIndexError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.consentRevision == Self.consentRevision else {
            throw PhotoSemanticIndexError.unsupportedConsentRevision(snapshot.consentRevision)
        }
        guard snapshot.accountID == account.accountID,
              snapshot.serverID == account.serverID,
              snapshot.userID == account.userID else {
            throw PhotoSemanticIndexError.accountIdentityMismatch
        }
        let recordIDs = snapshot.records.map(\.assetID)
        guard recordIDs.allSatisfy({ !$0.isEmpty }),
              Set(recordIDs).count == recordIDs.count,
              snapshot.records.allSatisfy({
                  !$0.sourceVersion.isEmpty
                      && $0.modelProfile == snapshot.modelProfile
                      && $0.embedding.dimension == snapshot.modelProfile.dimension
              }) else {
            throw PhotoSemanticIndexError.corruptedIndex
        }
        return snapshot
    }

    private func save(_ snapshot: PhotoSemanticIndexSnapshot, for account: AccountContext) throws {
        let directory = try directories.directory(for: account, kind: .analysisQueue)
        try rejectSymbolicLink(at: directory.deletingLastPathComponent())
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent(Self.filename, isDirectory: false)
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
        guard let root = try directories.existingRootDirectory(for: account) else { return nil }
        try rejectSymbolicLink(at: root)
        let directory = root.appendingPathComponent(CacheDirectoryKind.analysisQueue.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent(Self.filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func removeIndexFile(for account: AccountContext) throws {
        guard let url = try existingStorageURL(for: account) else { return }
        try rejectSymbolicLink(at: url)
        try fileManager.removeItem(at: url)
    }

    /// A one-way privacy cleanup for builds that previously offered local
    /// character grouping. The retired data remains account-scoped and this
    /// release removes it without loading or exporting it.
    private func removeRetiredCharacterCatalog(for account: AccountContext) throws {
        guard let root = try directories.existingRootDirectory(for: account) else { return }
        try rejectSymbolicLink(at: root)
        let directory = root.appendingPathComponent(CacheDirectoryKind.analysisQueue.rawValue, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        try rejectSymbolicLink(at: directory)
        let retiredCatalog = directory.appendingPathComponent(
            Self.retiredCharacterCatalogFilename,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: retiredCatalog.path) else { return }
        try rejectSymbolicLink(at: retiredCatalog)
        try fileManager.removeItem(at: retiredCatalog)
    }

    private func status(for snapshot: PhotoSemanticIndexSnapshot) -> PhotoSemanticIndexStatus {
        PhotoSemanticIndexStatus(
            isEnabled: true,
            indexedAssetCount: snapshot.records.count,
            lastSynchronizedAt: snapshot.lastSynchronizedAt,
            modelProfile: snapshot.modelProfile
        )
    }

    private static func uniqueStaticImages(from assets: [LocalPhotoAsset]) -> [String: LocalPhotoAsset] {
        Dictionary(
            assets.filter { $0.mediaKind == .photo }
                .map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private static func outputsByID(
        _ outputs: [LocalSemanticEmbeddingOutput],
        allowedAssetIDs: Set<String>,
        modelProfile: LocalEmbeddingModelProfile
    ) throws -> [String: LocalSemanticEmbeddingOutput] {
        guard outputs.allSatisfy({
                  !$0.assetID.isEmpty
                      && allowedAssetIDs.contains($0.assetID)
                      && $0.embedding.dimension == modelProfile.dimension
              }),
              Set(outputs.map(\.assetID)).count == outputs.count else {
            throw PhotoSemanticIndexError.invalidEmbeddingOutput
        }
        return Dictionary(uniqueKeysWithValues: outputs.map { ($0.assetID, $0) })
    }

    private static func sourceVersion(for asset: LocalPhotoAsset) -> String {
        [
            asset.localIdentifier,
            dateBits(asset.creationDate),
            dateBits(asset.modificationDate),
            asset.mediaKind.rawValue,
            String(asset.pixelWidth),
            String(asset.pixelHeight),
        ].joined(separator: "|")
    }

    private static func dateBits(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "none"
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw PhotoSemanticIndexError.unsafeStoragePath
        }
    }
}
