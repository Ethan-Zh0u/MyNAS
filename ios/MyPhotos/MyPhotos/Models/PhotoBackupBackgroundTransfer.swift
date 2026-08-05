import Foundation

/// The durable state needed to reconnect a system-owned background upload to
/// its MyNAS account after iOS relaunches the app. This model deliberately does
/// not schedule work by itself: G2 must not turn a persisted intent into an
/// upload until its background URLSession engine and system-policy gates exist.
nonisolated enum PhotoBackupBackgroundTransferState: String, Codable, Sendable {
    /// The foreground process exported the complete PhotoKit resource group to
    /// an account-isolated staging directory, but no system task exists yet.
    case prepared
    /// MyNAS accepted the manifest and supplied opaque resource IDs.
    case sessionCreated
    /// One or more file-backed URLSession upload tasks are owned by iOS.
    case transferring
    /// A system task completed and the next protocol action requires an app
    /// callback (for example, parsing a response or submitting completion).
    case awaitingAppCallback
    /// The transfer stopped safely; it can only be resumed after the G2 policy
    /// engine validates this same account and volume again.
    case paused
    case completed
    case failed
}

/// The three requests that make up the existing MyNAS upload-session protocol.
/// A background URLSession can finish one request while the app is suspended,
/// so the request phase must be stored with the system task identifier rather
/// than inferred from whatever account happens to be selected after relaunch.
nonisolated enum PhotoBackupBackgroundTransferTaskKind: String, Codable, Sendable {
    case createSession
    case uploadPart
    case completeSession
}

/// A single file-backed request owned by iOS. `bodyFilename` and
/// `responseFilename` are both record-relative safe path components; neither
/// may contain an app-container path, a server storage path, or credentials.
nonisolated struct PhotoBackupBackgroundTransferTask: Codable, Equatable, Sendable {
    let taskIdentifier: Int
    /// iOS task IDs are only unique inside one background URLSession. Persist
    /// the policy/session namespace so an old Wi-Fi callback can never be
    /// matched to an equal-numbered cellular task (or vice versa).
    /// Optional only to decode a task journal written before session-scoped
    /// callback identities existed. The engine fills it only when the callback
    /// is the sole safe candidate for that task ID; new tasks always set it.
    var networkPolicy: PhotoBackupAutomaticNetworkPolicy?
    let kind: PhotoBackupBackgroundTransferTaskKind
    let clientResourceID: String?
    let remoteResourceID: String?
    let partNumber: Int64?
    let offset: Int64?
    let byteCount: Int64?
    let bodyFilename: String
    let responseFilename: String
    var responseStatusCode: Int?
    var responseByteCount: Int64?

    init(
        taskIdentifier: Int,
        networkPolicy: PhotoBackupAutomaticNetworkPolicy,
        kind: PhotoBackupBackgroundTransferTaskKind,
        clientResourceID: String? = nil,
        remoteResourceID: String? = nil,
        partNumber: Int64? = nil,
        offset: Int64? = nil,
        byteCount: Int64? = nil,
        bodyFilename: String,
        responseFilename: String
    ) {
        self.taskIdentifier = taskIdentifier
        self.networkPolicy = networkPolicy
        self.kind = kind
        self.clientResourceID = clientResourceID
        self.remoteResourceID = remoteResourceID
        self.partNumber = partNumber
        self.offset = offset
        self.byteCount = byteCount
        self.bodyFilename = bodyFilename
        self.responseFilename = responseFilename
        responseStatusCode = nil
        responseByteCount = nil
    }

    var callbackIdentity: PhotoBackupBackgroundTransferTaskIdentity? {
        guard let networkPolicy else { return nil }
        return PhotoBackupBackgroundTransferTaskIdentity(
            taskIdentifier: taskIdentifier,
            networkPolicy: networkPolicy
        )
    }
}

/// URLSession task IDs repeat across different session identifiers. This is
/// the durable lookup key used for callbacks and cancellation, never a bare
/// task ID.
nonisolated struct PhotoBackupBackgroundTransferTaskIdentity: Hashable, Sendable {
    let taskIdentifier: Int
    let networkPolicy: PhotoBackupAutomaticNetworkPolicy
}

/// A process-local view of a background upload. Reported bytes may include
/// bytes iOS has handed to the transport for the current part, while confirmed
/// bytes contain only the offsets MyNAS has returned in its protocol response.
/// This is intentionally not Codable: a process relaunch must fall back to the
/// server-confirmed journal state instead of restoring an unacknowledged count.
nonisolated struct PhotoBackupBackgroundTransferProgress: Equatable, Sendable {
    let recordID: UUID
    let accountID: String
    let localIdentifier: String
    let sourceModificationDate: Date?
    let confirmedBytes: Int64
    let reportedBytes: Int64
    let totalBytes: Int64
}

/// This is stored only after MyNAS has integrity-confirmed the complete
/// resource group. Keeping it on the G2 record lets the foreground queue
/// reconcile a system callback after a relaunch without treating transport
/// completion as a backup result.
nonisolated struct PhotoBackupBackgroundTransferOutcome: Codable, Equatable, Sendable {
    let assetID: String
    let wasDuplicate: Bool
    let sourceState: PhotoSourceState
    let derivativeState: PhotoDerivativeState
    let browseReady: Bool
}

/// A resource is named by its canonical manifest ID, never by a user-provided
/// path. `stagedFilename` is relative to the record's private staging folder.
/// Keeping it relative avoids storing an app-container path that could become
/// invalid after an iOS restore or reinstall.
nonisolated struct PhotoBackupBackgroundTransferResource: Codable, Equatable, Sendable {
    let clientResourceID: String
    let role: String
    let originalFilename: String
    let contentType: String
    let byteSize: Int64
    let sha256: String
    let stagedFilename: String
    var remoteResourceID: String?
    var receivedBytes: Int64
    /// MyNAS remains the authority for this value; it arrives in the accepted
    /// create-session response and is never guessed from a local file size.
    var chunkSize: Int64? = nil
    var systemTaskIdentifier: Int?
}

/// A G2 transfer is always scoped more narrowly than a queue job: it carries
/// the exact server/user pair, selected volume and current PhotoKit source
/// version. A callback that cannot prove all four belongs to the active account
/// must be retained as paused rather than sent to a different destination.
nonisolated struct PhotoBackupBackgroundTransferRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let accountID: String
    let serverID: String
    let userID: String
    let volumeID: String
    let localIdentifier: String
    let sourceModificationDate: Date?
    let fingerprint: String
    let stagingDirectoryName: String
    let manifestFilename: String
    let completionFilename: String
    let createdAt: Date
    var updatedAt: Date
    var state: PhotoBackupBackgroundTransferState
    var uploadSessionID: String?
    var resources: [PhotoBackupBackgroundTransferResource]
    /// At most one protocol request is allowed to be system-owned at a time.
    /// This serialises the create → parts → complete protocol and makes a
    /// relaunch callback unambiguous without persisting response bodies in JSON.
    var pendingSystemTask: PhotoBackupBackgroundTransferTask?
    var outcome: PhotoBackupBackgroundTransferOutcome?
    var lastError: PhotoBackupFailure?

    init(
        id: UUID = UUID(),
        account: AccountContext,
        localAsset: LocalPhotoAsset,
        fingerprint: String,
        resources: [PhotoBackupBackgroundTransferResource],
        createdAt: Date = Date()
    ) throws {
        guard !account.isLocalOnly, let volumeID = account.selectedVolumeID else {
            throw PhotoBackupBackgroundTransferRecordError.missingAccountOrVolume
        }
        guard !fingerprint.isEmpty,
              !resources.isEmpty,
              resources.allSatisfy({ Self.isSafePathComponent($0.stagedFilename) }),
              Set(resources.map(\.stagedFilename)).count == resources.count else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }
        self.id = id
        accountID = account.accountID
        serverID = account.serverID
        userID = account.userID
        self.volumeID = volumeID
        localIdentifier = localAsset.localIdentifier
        sourceModificationDate = localAsset.modificationDate
        self.fingerprint = fingerprint
        stagingDirectoryName = id.uuidString
        manifestFilename = "create-session"
        completionFilename = "complete-session"
        self.resources = resources
        self.createdAt = createdAt
        updatedAt = createdAt
        state = .prepared
        uploadSessionID = nil
        pendingSystemTask = nil
        outcome = nil
        lastError = nil
    }

    func applies(to account: AccountContext) -> Bool {
        accountID == account.accountID
            && serverID == account.serverID
            && userID == account.userID
            && volumeID == account.selectedVolumeID
            && !account.isLocalOnly
    }

    mutating func transition(
        to nextState: PhotoBackupBackgroundTransferState,
        error: PhotoBackupFailure? = nil,
        updatedAt: Date = Date()
    ) {
        state = nextState
        lastError = error
        self.updatedAt = updatedAt
    }

    /// Registers a task before it is resumed. If the app dies after `resume()`,
    /// iOS can still report the task identifier and this record proves which
    /// account, volume and exact request body it belongs to.
    mutating func registerPendingSystemTask(
        _ task: PhotoBackupBackgroundTransferTask,
        updatedAt: Date = Date()
    ) throws {
        guard pendingSystemTask == nil,
              isValid(task: task) else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }

        pendingSystemTask = task
        if task.kind == .uploadPart,
           let clientResourceID = task.clientResourceID,
           let resourceIndex = resources.firstIndex(where: {
               $0.clientResourceID == clientResourceID
           }) {
            resources[resourceIndex].systemTaskIdentifier = task.taskIdentifier
        }
        state = .transferring
        lastError = nil
        self.updatedAt = updatedAt
    }

    /// A transport failure is not an upload failure: the server may already
    /// have accepted a whole part. Drop only the no-longer-live system task and
    /// let the next validated resume obtain MyNAS's authoritative offset.
    mutating func pausePendingSystemTask(
        taskIdentifier: Int,
        error: PhotoBackupFailure,
        updatedAt: Date = Date()
    ) throws {
        guard let task = pendingSystemTask,
              task.taskIdentifier == taskIdentifier else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }
        if task.kind == .uploadPart,
           let clientResourceID = task.clientResourceID,
           let resourceIndex = resources.firstIndex(where: {
               $0.clientResourceID == clientResourceID
           }) {
            resources[resourceIndex].systemTaskIdentifier = nil
        }
        pendingSystemTask = nil
        uploadSessionID = nil
        state = .paused
        lastError = error
        self.updatedAt = updatedAt
    }

    /// The next attempt must begin with MyNAS's idempotent create-session
    /// request, because a cancelled system task may have reached the server
    /// after the last callback. Reusing a locally remembered offset would risk
    /// submitting the wrong range.
    mutating func pauseForValidatedResumption(
        error: PhotoBackupFailure,
        updatedAt: Date = Date()
    ) {
        pendingSystemTask = nil
        uploadSessionID = nil
        for index in resources.indices {
            resources[index].remoteResourceID = nil
            resources[index].chunkSize = nil
            resources[index].systemTaskIdentifier = nil
        }
        state = .paused
        lastError = error
        self.updatedAt = updatedAt
    }

    mutating func clearPendingSystemTask(
        nextState: PhotoBackupBackgroundTransferState,
        updatedAt: Date = Date()
    ) {
        if pendingSystemTask?.kind == .uploadPart,
           let clientResourceID = pendingSystemTask?.clientResourceID,
           let resourceIndex = resources.firstIndex(where: {
               $0.clientResourceID == clientResourceID
           }) {
            resources[resourceIndex].systemTaskIdentifier = nil
        }
        pendingSystemTask = nil
        state = nextState
        lastError = nil
        self.updatedAt = updatedAt
    }

    /// The delegate writes the received response to the protected staging
    /// file, then records only its size/status here. Parsing is intentionally a
    /// later, explicit app callback so a suspended process cannot guess a
    /// successful upload from a transport completion alone.
    mutating func markPendingSystemTaskAwaitingCallback(
        taskIdentifier: Int,
        responseStatusCode: Int?,
        responseByteCount: Int64,
        updatedAt: Date = Date()
    ) throws {
        guard responseByteCount >= 0,
              var task = pendingSystemTask,
              task.taskIdentifier == taskIdentifier else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }

        task.responseStatusCode = responseStatusCode
        task.responseByteCount = responseByteCount
        pendingSystemTask = task
        state = .awaitingAppCallback
        lastError = nil
        self.updatedAt = updatedAt
    }

    /// The protocol shape is checked at the persistence boundary as well as at
    /// scheduling time. A corrupt journal must fail closed before any callback
    /// can be associated with a current account.
    fileprivate func hasValidPendingSystemTask() -> Bool {
        guard let pendingSystemTask else { return true }
        return isValid(task: pendingSystemTask)
    }

    private func isValid(task: PhotoBackupBackgroundTransferTask) -> Bool {
        guard task.taskIdentifier > 0,
              Self.isSafePathComponent(task.bodyFilename),
              Self.isSafePathComponent(task.responseFilename),
              task.responseStatusCode.map({ (100...599).contains($0) }) ?? true,
              task.responseByteCount.map({ $0 >= 0 }) ?? true else {
            return false
        }

        switch task.kind {
        case .createSession:
            return task.clientResourceID == nil
                && task.remoteResourceID == nil
                && task.partNumber == nil
                && task.offset == nil
                && task.byteCount == nil
                && task.bodyFilename == manifestFilename
                && uploadSessionID == nil
                && (state == .prepared || state == .paused || state == .transferring || state == .awaitingAppCallback)
        case .uploadPart:
            guard let clientResourceID = task.clientResourceID,
                  let remoteResourceID = task.remoteResourceID,
                  let partNumber = task.partNumber,
                  let offset = task.offset,
                  let byteCount = task.byteCount,
                  partNumber >= 0,
                  offset >= 0,
                  byteCount > 0,
                  let resource = resources.first(where: {
                      $0.clientResourceID == clientResourceID
                  }),
                  resource.remoteResourceID == remoteResourceID,
                  offset <= resource.byteSize,
                  byteCount <= resource.byteSize - offset,
                  uploadSessionID != nil else {
                return false
            }
            return state == .sessionCreated || state == .paused || state == .transferring || state == .awaitingAppCallback
        case .completeSession:
            return task.clientResourceID == nil
                && task.remoteResourceID == nil
                && task.partNumber == nil
                && task.offset == nil
                && task.byteCount == nil
                && task.bodyFilename == completionFilename
                && uploadSessionID != nil
                && (state == .sessionCreated || state == .paused || state == .transferring || state == .awaitingAppCallback)
        }
    }

    nonisolated fileprivate static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

nonisolated enum PhotoBackupBackgroundTransferRecordError: LocalizedError {
    case missingAccountOrVolume
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .missingAccountOrVolume:
            "后台传输必须绑定已连接的 MyNAS 账号和已选择的备份硬盘。"
        case .invalidRecord:
            "后台传输记录缺少完整的资源组信息。"
        }
    }
}

/// G2's durable task-to-account map. It contains no credentials or server
/// storage paths. The store is separate from the foreground queue so a failed
/// write cannot make an existing G1 job appear system-scheduled.
nonisolated struct PhotoBackupBackgroundTransferJournal {
    private let fileManager: FileManager
    private let explicitURL: URL?
    private let explicitStagingRootURL: URL?

    init(
        fileManager: FileManager = .default,
        explicitURL: URL? = nil,
        explicitStagingRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.explicitURL = explicitURL
        self.explicitStagingRootURL = explicitStagingRootURL
    }

    func load() throws -> [PhotoBackupBackgroundTransferRecord] {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(
            [PhotoBackupBackgroundTransferRecord].self,
            from: Data(contentsOf: url)
        )
    }

    func save(_ records: [PhotoBackupBackgroundTransferRecord]) throws {
        let taskIdentities = records.compactMap { $0.pendingSystemTask?.callbackIdentity }
        guard Set(taskIdentities).count == taskIdentities.count else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }
        let url = try storageURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(records)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func stagingDirectory(
        for record: PhotoBackupBackgroundTransferRecord
    ) throws -> URL {
        let directory = try validatedStagingDirectory(for: record)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory
    }

    /// Remove an acknowledged record only after its foreground queue has
    /// durably recorded the same terminal outcome. This deliberately resolves
    /// the directory without creating it, so a late cleanup can never turn a
    /// missing staged copy into a new empty directory.
    func removeCompletedTransfer(
        _ record: PhotoBackupBackgroundTransferRecord
    ) throws {
        guard record.state == .completed,
              record.outcome != nil,
              record.pendingSystemTask == nil else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }
        var records = try load()
        guard let persistedRecord = records.first(where: { $0.id == record.id }),
              persistedRecord == record,
              persistedRecord.state == .completed,
              persistedRecord.outcome != nil,
              persistedRecord.pendingSystemTask == nil else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }

        let directory = try validatedStagingDirectory(for: persistedRecord)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw PhotoBackupBackgroundTransferRecordError.invalidRecord
            }
            try fileManager.removeItem(at: directory)
        }

        records.removeAll { $0.id == persistedRecord.id }
        try save(records)
    }

    private func validatedStagingDirectory(
        for record: PhotoBackupBackgroundTransferRecord
    ) throws -> URL {
        guard record.stagingDirectoryName == record.id.uuidString,
              PhotoBackupBackgroundTransferRecord.isSafePathComponent(record.manifestFilename),
              PhotoBackupBackgroundTransferRecord.isSafePathComponent(record.completionFilename),
              record.resources.allSatisfy({
                  PhotoBackupBackgroundTransferRecord.isSafePathComponent($0.stagedFilename)
              }),
              Set(record.resources.map(\.stagedFilename)).count == record.resources.count,
              record.hasValidPendingSystemTask() else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }
        let root = try stagingRootURL()
        return root
            .appendingPathComponent(pathComponent(for: record.serverID), isDirectory: true)
            .appendingPathComponent(pathComponent(for: record.userID), isDirectory: true)
            .appendingPathComponent(record.stagingDirectoryName, isDirectory: true)
    }

    private func storageURL() throws -> URL {
        if let explicitURL { return explicitURL }
        return try applicationSupportRoot()
            .appendingPathComponent("BackgroundTransferJournal", isDirectory: true)
            .appendingPathComponent("records.json", isDirectory: false)
    }

    private func stagingRootURL() throws -> URL {
        if let explicitStagingRootURL { return explicitStagingRootURL }
        return try applicationSupportRoot()
            .appendingPathComponent("BackgroundTransferStaging", isDirectory: true)
    }

    private func applicationSupportRoot() throws -> URL {
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    private func pathComponent(for value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = value.unicodeScalars.map {
            allowed.contains($0) ? String($0) : "-"
        }.joined()
        return encoded.isEmpty ? "unknown" : encoded
    }
}

/// Prepares a complete, file-backed resource group for a future background
/// upload. It does not create a URLSession task; its only responsibility is to
/// atomically make a verified local copy and then register that copy.
actor PhotoBackupBackgroundTransferStager {
    private let journal: PhotoBackupBackgroundTransferJournal
    private let fileManager: FileManager

    init(
        journal: PhotoBackupBackgroundTransferJournal = PhotoBackupBackgroundTransferJournal(),
        fileManager: FileManager = .default
    ) {
        self.journal = journal
        self.fileManager = fileManager
    }

    func stage(
        preparedAsset: PreparedPhotoAsset,
        account: AccountContext,
        deviceID: String
    ) throws -> PhotoBackupBackgroundTransferRecord {
        let resources = preparedAsset.resources.map { resource in
            PhotoBackupBackgroundTransferResource(
                clientResourceID: resource.clientResourceID,
                role: resource.role,
                originalFilename: resource.originalFilename,
                contentType: resource.contentType,
                byteSize: resource.byteSize,
                sha256: resource.sha256,
                stagedFilename: resource.clientResourceID,
                remoteResourceID: nil,
                receivedBytes: 0,
                systemTaskIdentifier: nil
            )
        }
        let record = try PhotoBackupBackgroundTransferRecord(
            account: account,
            localAsset: preparedAsset.localAsset,
            fingerprint: preparedAsset.fingerprint,
            resources: resources
        )
        let directory = try journal.stagingDirectory(for: record)

        do {
            for (source, destination) in zip(preparedAsset.resources, record.resources) {
                let destinationURL = directory.appendingPathComponent(
                    destination.stagedFilename,
                    isDirectory: false
                )
                try fileManager.copyItem(at: source.fileURL, to: destinationURL)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destinationURL.path
                )

                let copiedSize = try fileManager.attributesOfItem(atPath: destinationURL.path)[.size]
                    as? NSNumber
                guard copiedSize?.int64Value == destination.byteSize,
                      try FileSHA256.digest(of: destinationURL) == destination.sha256 else {
                    throw PhotoBackupPreparationError.invalidResource
                }
            }

            // Background URLSession upload tasks must own request bodies from
            // files. Staging these two protocol bodies now makes the later
            // session creation deterministic and avoids rebuilding metadata
            // from an unavailable PhotoKit asset after iOS relaunches us.
            let encoder = JSONEncoder()
            try writeProtected(
                encoder.encode(
                    preparedAsset.uploadSessionRequest(
                        volumeID: record.volumeID,
                        deviceID: deviceID
                    )
                ),
                to: directory.appendingPathComponent(record.manifestFilename, isDirectory: false)
            )
            try writeProtected(
                Data(),
                to: directory.appendingPathComponent(record.completionFilename, isDirectory: false)
            )

            var records = try journal.load()
            guard !records.contains(where: { $0.id == record.id }) else {
                throw PhotoBackupBackgroundTransferRecordError.invalidRecord
            }
            records.append(record)
            try journal.save(records)
            return record
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

/// A future transfer engine asks this actor for a file containing exactly one
/// server-sized part. It intentionally creates no URLSession task. The stable
/// filename lets an iOS-owned task continue reading the same body after the app
/// is relaunched, and we never overwrite an existing body that may be in use.
actor PhotoBackupBackgroundTransferPartMaterializer {
    private let journal: PhotoBackupBackgroundTransferJournal
    private let fileManager: FileManager

    init(
        journal: PhotoBackupBackgroundTransferJournal = PhotoBackupBackgroundTransferJournal(),
        fileManager: FileManager = .default
    ) {
        self.journal = journal
        self.fileManager = fileManager
    }

    func materializePart(
        record: PhotoBackupBackgroundTransferRecord,
        clientResourceID: String,
        offset: Int64,
        byteCount: Int64
    ) throws -> PhotoBackupBackgroundTransferPartFile {
        guard let resourceIndex = record.resources.firstIndex(where: {
            $0.clientResourceID == clientResourceID
        }), offset >= 0, byteCount > 0 else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }
        let resource = record.resources[resourceIndex]
        guard offset <= resource.byteSize,
              byteCount <= resource.byteSize - offset else {
            throw PhotoBackupBackgroundTransferRecordError.invalidRecord
        }

        let directory = try journal.stagingDirectory(for: record)
        let source = directory.appendingPathComponent(resource.stagedFilename, isDirectory: false)
        let sourceSize = try fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        guard sourceSize?.int64Value == resource.byteSize else {
            throw PhotoBackupPreparationError.invalidResource
        }

        // This name contains only record-local indexes and numbers. It cannot
        // reflect a source filename or a user-controlled filesystem path.
        let filename = "part-\(resourceIndex)-\(offset)-\(byteCount)-body"
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: Int(byteCount)),
                  data.count == Int(byteCount) else {
                throw PhotoBackupPreparationError.invalidResource
            }
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        }

        let size = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
        guard size?.int64Value == byteCount else {
            throw PhotoBackupPreparationError.invalidResource
        }
        return PhotoBackupBackgroundTransferPartFile(
            filename: filename,
            byteSize: byteCount,
            sha256: try FileSHA256.digest(of: destination)
        )
    }
}

nonisolated struct PhotoBackupBackgroundTransferPartFile: Equatable, Sendable {
    let filename: String
    let byteSize: Int64
    let sha256: String
}
