import Foundation

/// I3's account-scoped, deletable OCR index. This actor never receives an
/// image, `PHAsset`, thumbnail, file URL or Vision result object. The UI-side
/// processor supplies only value-only metadata and recognised text after the
/// user has explicitly opted in.
actor PhotoTextIndexStore {
    nonisolated static let schemaVersion = 1
    nonisolated static let processorRevision = "vision-text-recognition-accurate-v1"
    nonisolated static let consentRevision = "local-ocr-consent-v1"
    nonisolated static let maximumRecognizedTextCharacterCount = 24_000

    private let directories: CacheDirectoryProvider
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let pixelAnalysisConsent: PhotoAnalysisQueueStore

    init(
        directories: CacheDirectoryProvider = CacheDirectoryProvider(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        pixelAnalysisConsent: PhotoAnalysisQueueStore? = nil
    ) {
        self.directories = directories
        self.fileManager = fileManager
        self.now = now
        self.pixelAnalysisConsent = pixelAnalysisConsent ?? PhotoAnalysisQueueStore(
            directories: directories,
            fileManager: fileManager,
            now: now
        )
    }

    func status(for account: AccountContext) async throws -> PhotoTextIndexStatus {
        guard try await hasPixelAnalysisConsent(for: account) else {
            try removeIndexFile(for: account)
            return .disabled
        }
        guard let snapshot = try loadSnapshot(for: account) else {
            return .disabled
        }
        return status(for: snapshot)
    }

    /// This is an independent I3 consent. I2's permission is necessary but
    /// insufficient: a user must separately choose to retain searchable text.
    @discardableResult
    func enable(for account: AccountContext) async throws -> PhotoTextIndexStatus {
        try await requirePixelAnalysisConsent(for: account)
        if let snapshot = try loadSnapshot(for: account) {
            return status(for: snapshot)
        }
        let snapshot = PhotoTextIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            processorRevision: Self.processorRevision,
            consentRevision: Self.consentRevision,
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
    func clear(for account: AccountContext) async throws -> PhotoTextIndexStatus {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            return .disabled
        }
        let cleared = PhotoTextIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            processorRevision: Self.processorRevision,
            consentRevision: Self.consentRevision,
            accountID: snapshot.accountID,
            serverID: snapshot.serverID,
            userID: snapshot.userID,
            lastSynchronizedAt: nil,
            records: []
        )
        try save(cleared, for: account)
        return status(for: cleared)
    }

    /// Revokes I3 only. I2's broader pixel-analysis permission and queue stay
    /// available for a later explicitly enabled analysis stage.
    @discardableResult
    func disableAndDelete(for account: AccountContext) throws -> PhotoTextIndexStatus {
        try removeIndexFile(for: account)
        return .disabled
    }

    @discardableResult
    func resetCorruptedIndex(for account: AccountContext) throws -> PhotoTextIndexStatus {
        try removeIndexFile(for: account)
        return .disabled
    }

    func synchronize(
        assets: [LocalPhotoAsset],
        outputs: [PhotoTextRecognitionOutput],
        for account: AccountContext
    ) async throws -> PhotoTextIndexSyncResult {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoTextIndexError.notEnabled
        }

        let staticImages = Self.uniqueStaticImages(from: assets)
        let staticImageIDs = Set(staticImages.keys)
        let outputByID = try Self.outputsByID(outputs, allowedAssetIDs: staticImageIDs)
        let existing = snapshot.processorRevision == Self.processorRevision
            ? Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.assetID, $0) })
            : [:]
        let indexedAt = now()
        var records: [PhotoTextIndexRecord] = []
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
            let recognisedText = try Self.canonicalText(output.recognizedText)
            records.append(
                PhotoTextIndexRecord(
                    assetID: asset.localIdentifier,
                    sourceVersion: sourceVersion,
                    processorRevision: Self.processorRevision,
                    recognizedText: recognisedText,
                    indexedAt: indexedAt
                )
            )
            if existing[asset.localIdentifier] == nil {
                insertedCount += 1
            } else {
                updatedCount += 1
            }
        }

        let removedFromScope = existing.keys.filter { !staticImageIDs.contains($0) }.count
        let synchronized = PhotoTextIndexSnapshot(
            schemaVersion: Self.schemaVersion,
            processorRevision: Self.processorRevision,
            consentRevision: Self.consentRevision,
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            lastSynchronizedAt: indexedAt,
            records: records
        )
        try save(synchronized, for: account)
        return PhotoTextIndexSyncResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            removedCount: removedFromScope + invalidatedRecordCount,
            unchangedCount: unchangedCount,
            deferredAssetCount: deferredAssetCount,
            status: status(for: synchronized)
        )
    }

    /// Returns only static images whose current metadata-derived source version
    /// has no current OCR record. The Vision layer uses this plan to avoid
    /// requesting pixels for unchanged local images.
    func assetsNeedingRecognition(
        from assets: [LocalPhotoAsset],
        for account: AccountContext
    ) async throws -> [LocalPhotoAsset] {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoTextIndexError.notEnabled
        }
        let existing = snapshot.processorRevision == Self.processorRevision
            ? Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.assetID, $0) })
            : [:]
        return Self.uniqueStaticImages(from: assets)
            .values
            .filter { asset in
                existing[asset.localIdentifier]?.sourceVersion != Self.sourceVersion(for: asset)
            }
            .sorted(by: { $0.localIdentifier < $1.localIdentifier })
    }

    func search(_ query: String, for account: AccountContext) async throws -> [PhotoTextIndexRecord] {
        try await requirePixelAnalysisConsent(for: account)
        guard let snapshot = try loadSnapshot(for: account) else {
            throw PhotoTextIndexError.notEnabled
        }
        guard snapshot.processorRevision == Self.processorRevision else { return [] }
        let queryTerms = Self.normalizedQueryTerms(query)
        guard !queryTerms.isEmpty else { return [] }

        return snapshot.records
            .filter { record in
                let text = Self.normalize(record.recognizedText)
                return queryTerms.allSatisfy(text.contains)
            }
            .sorted { left, right in
                if left.indexedAt != right.indexedAt { return left.indexedAt > right.indexedAt }
                return left.assetID < right.assetID
            }
    }

    private func hasPixelAnalysisConsent(for account: AccountContext) async throws -> Bool {
        try await pixelAnalysisConsent.status(for: account).isPixelAnalysisAllowed
    }

    private func requirePixelAnalysisConsent(for account: AccountContext) async throws {
        guard try await hasPixelAnalysisConsent(for: account) else {
            throw PhotoTextIndexError.pixelAnalysisNotAllowed
        }
    }

    private func loadSnapshot(for account: AccountContext) throws -> PhotoTextIndexSnapshot? {
        guard let url = try existingStorageURL(for: account) else { return nil }
        try rejectSymbolicLink(at: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotoTextIndexError.corruptedIndex
        }
        let snapshot: PhotoTextIndexSnapshot
        do {
            snapshot = try JSONDecoder().decode(PhotoTextIndexSnapshot.self, from: data)
        } catch {
            throw PhotoTextIndexError.corruptedIndex
        }
        guard snapshot.schemaVersion == Self.schemaVersion else {
            throw PhotoTextIndexError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.consentRevision == Self.consentRevision else {
            throw PhotoTextIndexError.unsupportedConsentRevision(snapshot.consentRevision)
        }
        guard snapshot.accountID == account.accountID,
              snapshot.serverID == account.serverID,
              snapshot.userID == account.userID else {
            throw PhotoTextIndexError.accountIdentityMismatch
        }
        let recordIDs = snapshot.records.map(\.assetID)
        guard !snapshot.processorRevision.isEmpty,
              recordIDs.allSatisfy({ !$0.isEmpty }),
              Set(recordIDs).count == recordIDs.count,
              snapshot.records.allSatisfy({ record in
                  !record.sourceVersion.isEmpty
                      && record.processorRevision == snapshot.processorRevision
                      && record.recognizedText.count <= Self.maximumRecognizedTextCharacterCount
              }) else {
            throw PhotoTextIndexError.corruptedIndex
        }
        return snapshot
    }

    private func save(_ snapshot: PhotoTextIndexSnapshot, for account: AccountContext) throws {
        let directory = try directories.directory(for: account, kind: .analysisQueue)
        try rejectSymbolicLink(at: directory.deletingLastPathComponent())
        try rejectSymbolicLink(at: directory)
        let url = directory.appendingPathComponent("vision-ocr-index-v1.json", isDirectory: false)
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
        let url = directory.appendingPathComponent("vision-ocr-index-v1.json", isDirectory: false)
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
            throw PhotoTextIndexError.unsafeStoragePath
        }
    }

    private func status(for snapshot: PhotoTextIndexSnapshot) -> PhotoTextIndexStatus {
        PhotoTextIndexStatus(
            isEnabled: true,
            indexedAssetCount: snapshot.records.count,
            lastSynchronizedAt: snapshot.lastSynchronizedAt,
            needsRebuild: snapshot.processorRevision != Self.processorRevision
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
        _ outputs: [PhotoTextRecognitionOutput],
        allowedAssetIDs: Set<String>
    ) throws -> [String: PhotoTextRecognitionOutput] {
        guard outputs.allSatisfy({ !$0.assetID.isEmpty && allowedAssetIDs.contains($0.assetID) }),
              Set(outputs.map(\.assetID)).count == outputs.count else {
            throw PhotoTextIndexError.invalidRecognitionOutput
        }
        return Dictionary(uniqueKeysWithValues: outputs.map { ($0.assetID, $0) })
    }

    private static func canonicalText(_ value: String) throws -> String {
        let canonical = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonical.count <= maximumRecognizedTextCharacterCount else {
            throw PhotoTextIndexError.recognizedTextTooLarge
        }
        return canonical
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
