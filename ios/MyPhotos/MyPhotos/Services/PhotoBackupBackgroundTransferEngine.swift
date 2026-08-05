import Combine
import Foundation

/// Owns the G2 background URLSession protocol. iOS, not a foreground Swift
/// task, owns each file-backed request after it is resumed. The journal is
/// always updated before `resume()` so a later process launch can safely match
/// the callback to its original MyNAS account and volume.
@MainActor
final class PhotoBackupBackgroundTransferEngine: NSObject {
    static let shared = PhotoBackupBackgroundTransferEngine()

    static let sessionIdentifierPrefix = "com.ethanzhou.MyPhotos.photo-backup-v1"

    /// Keep the user-selected Low Power boundary inside G2 itself instead of
    /// relying only on the foreground coordinator. A PhotoKit export can span
    /// the moment Low Power Mode changes; the engine is the final gate before
    /// it stages files or resumes a system-owned protocol request.
    nonisolated static func permitsCurrentPower(
        policy: PhotoBackupAutomationPolicy,
        isLowPowerModeEnabled: Bool
    ) -> Bool {
        !policy.pausesInLowPowerMode || !isLowPowerModeEnabled
    }

    private let journal: PhotoBackupBackgroundTransferJournal
    private let stager: PhotoBackupBackgroundTransferStager
    private let materializer: PhotoBackupBackgroundTransferPartMaterializer
    private let accountPersistence: AccountPersistenceStore
    private let policyPersistence: PhotoBackupAutomationPolicyStore
    private let fileManager: FileManager
    private let isLowPowerModeEnabled: () -> Bool
    private let decoder = JSONDecoder()
    /// The journal is the source of truth for system-owned transfers. A small
    /// revision lets a visible SwiftUI card reconcile promptly after callbacks.
    @Published private(set) var stateRevision: UInt = 0
    /// This revision carries non-durable upload-byte reports from URLSession.
    /// It never changes the server-confirmed journal offsets.
    @Published private(set) var transferProgressRevision: UInt = 0
    private var backgroundEventCompletionHandlers: [String: () -> Void] = [:]

    private struct InFlightUploadProgress {
        let recordID: UUID
        let bytesSent: Int64
    }

    private var inFlightUploadProgress: [PhotoBackupBackgroundTransferTaskIdentity: InFlightUploadProgress] = [:]
    private var sessions: [PhotoBackupAutomaticNetworkPolicy: URLSession] = [:]

    private func session(for networkPolicy: PhotoBackupAutomaticNetworkPolicy) -> URLSession {
        if let session = sessions[networkPolicy] { return session }
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "\(Self.sessionIdentifierPrefix).\(networkPolicy.rawValue)"
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        // iOS may defer a discretionary transfer for power, thermal or network
        // reasons. That is intentional: G2 is an opportunity-based service,
        // never a promise of immediate background execution.
        configuration.isDiscretionary = true
        // This property belongs to URLSessionConfiguration, not an individual
        // upload task. Keep separate system sessions so a Wi-Fi-only task can
        // never inherit a later account policy that permits cellular data.
        configuration.allowsCellularAccess = networkPolicy == .anyNetwork
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        // Keep standard TLS validation, but do not send private tailnet traffic
        // through a PAC/loopback proxy when iOS relaunches the transfer session.
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessions[networkPolicy] = session
        return session
    }

    @MainActor
    init(
        journal: PhotoBackupBackgroundTransferJournal = PhotoBackupBackgroundTransferJournal(),
        stager: PhotoBackupBackgroundTransferStager? = nil,
        materializer: PhotoBackupBackgroundTransferPartMaterializer? = nil,
        accountPersistence: AccountPersistenceStore? = nil,
        policyPersistence: PhotoBackupAutomationPolicyStore? = nil,
        fileManager: FileManager = .default,
        isLowPowerModeEnabled: @escaping () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.journal = journal
        self.stager = stager ?? PhotoBackupBackgroundTransferStager(journal: journal, fileManager: fileManager)
        self.materializer = materializer ?? PhotoBackupBackgroundTransferPartMaterializer(journal: journal, fileManager: fileManager)
        self.accountPersistence = accountPersistence ?? AccountPersistenceStore()
        self.policyPersistence = policyPersistence ?? PhotoBackupAutomationPolicyStore()
        self.fileManager = fileManager
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        super.init()
    }

    /// Stages and schedules only an already-authorized automatic resource
    /// group. Manual uploads deliberately keep using the proven foreground
    /// uploader until their separate product policy says otherwise.
    func beginAutomaticTransfer(
        preparedAsset: PreparedPhotoAsset,
        account: AccountContext,
        policy: PhotoBackupAutomationPolicy,
        deviceID: String
    ) async throws -> PhotoBackupBackgroundTransferRecord {
        guard account.serverCapabilities.supportsBackgroundTransfers,
              policy.applies(to: account), policy.isEnabled else {
            throw PhotoBackupBackgroundTransferEngineError.backgroundTransferUnavailable
        }
        guard Self.permitsCurrentPower(
            policy: policy,
            isLowPowerModeEnabled: isLowPowerModeEnabled()
        ) else {
            throw PhotoBackupBackgroundTransferEngineError.pausedForLowPower
        }
        let record = try await stager.stage(
            preparedAsset: preparedAsset,
            account: account,
            deviceID: deviceID
        )
        try scheduleCreateSession(for: record, account: account, policy: policy)
        return try currentRecord(id: record.id)
    }

    /// Re-validates this exact account, volume and user consent before moving a
    /// previously staged record. This method may be called on normal app entry
    /// as well as after a background URLSession relaunch callback.
    func continueTransfers(
        for account: AccountContext,
        policy: PhotoBackupAutomationPolicy
    ) async {
        guard account.serverCapabilities.supportsBackgroundTransfers,
              policy.applies(to: account), policy.isEnabled,
              Self.permitsCurrentPower(
                  policy: policy,
                  isLowPowerModeEnabled: isLowPowerModeEnabled()
              ),
              !account.isLocalOnly else {
            return
        }
        reconnectActiveSystemSessions(for: account)
        await continueFirstEligibleTransfer(account: account, policy: policy)
    }

    /// A normal foreground launch is not guaranteed to enter UIKit's
    /// `handleEventsForBackgroundURLSession` path. Recreate only the fixed
    /// session namespaces that already own a durable, in-progress task for
    /// this exact account, so iOS can resume delivering delegate callbacks to
    /// this process. This attaches no new request and does not reinterpret an
    /// unconfirmed transport offset as server progress.
    private func reconnectActiveSystemSessions(for account: AccountContext) {
        guard let records = try? journal.load() else { return }
        for networkPolicy in Self.activeSystemTaskNetworkPolicies(
            in: records,
            for: account
        ) {
            _ = session(for: networkPolicy)
        }
    }

    /// Pure selection logic kept separate from session creation so the
    /// account/state boundary can be regression-tested without attaching a
    /// XCTest host to a real background URLSession.
    static func activeSystemTaskNetworkPolicies(
        in records: [PhotoBackupBackgroundTransferRecord],
        for account: AccountContext
    ) -> [PhotoBackupAutomaticNetworkPolicy] {
        records.reduce(into: [PhotoBackupAutomaticNetworkPolicy]()) { policies, record in
            guard record.applies(to: account),
                  record.state == .transferring,
                  let networkPolicy = record.pendingSystemTask?.networkPolicy,
                  !policies.contains(networkPolicy) else {
                return
            }
            policies.append(networkPolicy)
        }
    }

    func hasActiveTransfer(for account: AccountContext) -> Bool {
        guard let records = try? journal.load() else { return false }
        return records.contains { record in
            record.applies(to: account)
                && record.state != .completed
                && record.state != .failed
        }
    }

    func completedTransfers(for account: AccountContext) -> [PhotoBackupBackgroundTransferRecord] {
        guard let records = try? journal.load() else { return [] }
        return records.filter { $0.applies(to: account) && $0.state == .completed && $0.outcome != nil }
    }

    /// Returns an active display overlay. Reported bytes can be ahead of
    /// confirmed bytes only within the current file-backed part.
    func activeTransferProgress(for account: AccountContext) -> [PhotoBackupBackgroundTransferProgress] {
        guard let records = try? journal.load() else { return [] }
        return records.compactMap { record in
            guard record.applies(to: account),
                  record.state != .completed,
                  record.state != .failed else {
                return nil
            }
            let confirmedBytes = record.resources.reduce(Int64(0)) {
                $0 + max(0, min($1.receivedBytes, $1.byteSize))
            }
            let totalBytes = record.resources.reduce(Int64(0)) { $0 + max(0, $1.byteSize) }
            guard totalBytes > 0 else { return nil }

            var reportedBytes = confirmedBytes
            if let pendingTask = record.pendingSystemTask,
               pendingTask.kind == .uploadPart,
               let callbackIdentity = pendingTask.callbackIdentity,
               let partByteCount = pendingTask.byteCount,
               let progress = inFlightUploadProgress[callbackIdentity],
               progress.recordID == record.id {
                let boundedPartBytes = min(max(0, progress.bytesSent), max(0, partByteCount))
                reportedBytes = min(totalBytes, confirmedBytes + boundedPartBytes)
            }

            return PhotoBackupBackgroundTransferProgress(
                recordID: record.id,
                accountID: record.accountID,
                localIdentifier: record.localIdentifier,
                sourceModificationDate: record.sourceModificationDate,
                confirmedBytes: confirmedBytes,
                reportedBytes: reportedBytes,
                totalBytes: totalBytes
            )
        }
    }

    /// Receives URLSession's current transport counter for one pending part.
    /// This stays outside the journal because only MyNAS can advance received
    /// offsets across a relaunch or retry.
    @discardableResult
    func recordUploadProgress(
        taskIdentifier: Int,
        networkPolicy: PhotoBackupAutomaticNetworkPolicy,
        totalBytesSent: Int64
    ) -> Bool {
        guard let record = try? record(
            withTaskIdentifier: taskIdentifier,
            networkPolicy: networkPolicy
        ),
        let pendingTask = record.pendingSystemTask,
        pendingTask.kind == .uploadPart,
        let callbackIdentity = pendingTask.callbackIdentity,
        let partByteCount = pendingTask.byteCount else {
            return false
        }

        let boundedBytes = min(max(0, totalBytesSent), max(0, partByteCount))
        if let existing = inFlightUploadProgress[callbackIdentity],
           existing.recordID == record.id,
           existing.bytesSent >= boundedBytes {
            return false
        }
        inFlightUploadProgress[callbackIdentity] = InFlightUploadProgress(
            recordID: record.id,
            bytesSent: boundedBytes
        )
        transferProgressRevision &+= 1
        return true
    }

    /// The foreground queue calls this only after it has persisted the same
    /// server-confirmed completion. A failure leaves both the protected staged
    /// files and their journal record intact for a later safe retry.
    @discardableResult
    func discardCompletedTransfer(
        _ record: PhotoBackupBackgroundTransferRecord,
        for account: AccountContext
    ) -> Bool {
        guard record.applies(to: account),
              record.state == .completed,
              record.outcome != nil else {
            return false
        }
        do {
            try journal.removeCompletedTransfer(record)
            _ = clearInFlightUploadProgress(for: record.id)
            stateRevision &+= 1
            return true
        } catch {
            return false
        }
    }

    /// A BGProcessingTask must never be used to discover PhotoKit changes. It
    /// may only be requested when a durable, already-staged record can still
    /// be matched to the currently selected persisted account and its enabled
    /// policy. A task that iOS already owns needs no separate processing task.
    func hasEligiblePersistedTransferForBackgroundProcessing() -> Bool {
        guard let records = try? journal.load() else { return false }
        return records.contains { record in
            canContinueInBackgroundProcessing(record)
                && persistedEligibility(for: record, requiresAllowedPower: false) != nil
        }
    }

    /// Called only from the UIKit BGProcessingTask handler. It deliberately
    /// reopens no PhotoKit object and sends no request if the user has changed
    /// account, volume, consent, server capability or Low Power policy since
    /// the record was staged.
    func continueOnePersistedTransferFromBackgroundProcessing() async -> PhotoBackupBackgroundProcessingDisposition {
        guard !Task.isCancelled else { return .cancelled }
        guard let records = try? journal.load() else { return .noEligibleTransfer }
        guard let record = records.first(where: canContinueInBackgroundProcessing),
              let eligibility = persistedEligibility(for: record, requiresAllowedPower: false) else {
            return .noEligibleTransfer
        }
        guard !Task.isCancelled else { return .cancelled }
        if eligibility.policy.pausesInLowPowerMode, isLowPowerModeEnabled() {
            return .deferredForLowPower
        }
        await continueFirstEligibleTransfer(account: eligibility.account, policy: eligibility.policy)
        return Task.isCancelled ? .cancelled : .continued
    }

    /// Stopping an automatic policy or switching away from its account cancels
    /// only that account's system-owned tasks. The task→record map is cleared
    /// before cancellation so a delayed cancellation callback cannot revive an
    /// old account's work under whichever account becomes current next.
    func pauseTransfers(for account: AccountContext, reason: String) {
        guard var records = try? journal.load() else { return }
        var taskIdentifiers: [PhotoBackupAutomaticNetworkPolicy: Set<Int>] = [:]
        var changed = false
        for index in records.indices where records[index].applies(to: account) {
            guard records[index].state != .completed, records[index].state != .failed else { continue }
            let failure = PhotoBackupFailure(
                kind: .configuration,
                detail: reason,
                occurredAt: Date()
            )
            if let taskIdentifier = records[index].pendingSystemTask?.taskIdentifier {
                let networkPolicy = records[index].pendingSystemTask?.networkPolicy
                if let networkPolicy {
                    taskIdentifiers[networkPolicy, default: []].insert(taskIdentifier)
                }
                try? records[index].pausePendingSystemTask(
                    taskIdentifier: taskIdentifier,
                    error: failure
                )
            } else {
                records[index].pauseForValidatedResumption(error: failure)
            }
            changed = true
        }
        if changed {
            do {
                try journal.save(records)
                records.filter { $0.applies(to: account) }.forEach {
                    _ = clearInFlightUploadProgress(for: $0.id)
                }
                stateRevision &+= 1
            } catch {
                // Do not publish a pause which was not durably persisted.
            }
        }
        guard !taskIdentifiers.isEmpty else { return }
        for policy in PhotoBackupAutomaticNetworkPolicy.allCases {
            guard let identifiers = taskIdentifiers[policy], !identifiers.isEmpty else { continue }
            session(for: policy).getAllTasks { tasks in
                tasks.lazy
                    .filter { identifiers.contains($0.taskIdentifier) }
                    .forEach { $0.cancel() }
            }
        }
    }

    /// Reconnects iOS background events to the matching session after a launch.
    /// Apple requires retaining this completion handler *before* recreating the
    /// named session: session creation can immediately deliver its retained
    /// callbacks. The whole hand-off stays on the main actor, so a
    /// `urlSessionDidFinishEvents` callback can never arrive in the gap between
    /// recreation and handler storage.
    @discardableResult
    func reconnectForBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard let networkPolicy = networkPolicy(forSessionIdentifier: identifier) else {
            return false
        }
        backgroundEventCompletionHandlers[identifier] = completionHandler
        _ = session(for: networkPolicy)
        return true
    }

    private func continueFirstEligibleTransfer(
        account: AccountContext,
        policy: PhotoBackupAutomationPolicy
    ) async {
        guard let records = try? journal.load() else { return }
        guard let record = records.first(where: {
            $0.applies(to: account)
                && ($0.state == .prepared || $0.state == .sessionCreated || $0.state == .paused || $0.state == .awaitingAppCallback)
        }) else {
            return
        }

        do {
            switch record.state {
            case .awaitingAppCallback:
                try await processCallback(for: record, account: account, policy: policy)
            case .prepared, .paused:
                guard record.pendingSystemTask == nil else { return }
                if record.uploadSessionID == nil {
                    try scheduleCreateSession(for: record, account: account, policy: policy)
                } else {
                    try await scheduleNextProtocolRequest(for: record, account: account, policy: policy)
                }
            case .sessionCreated:
                guard record.pendingSystemTask == nil else { return }
                try await scheduleNextProtocolRequest(for: record, account: account, policy: policy)
            case .transferring, .completed, .failed:
                break
            }
        } catch {
            pause(recordID: record.id, taskIdentifier: record.pendingSystemTask?.taskIdentifier, error: failure(from: error))
        }
    }

    private func scheduleCreateSession(
        for originalRecord: PhotoBackupBackgroundTransferRecord,
        account: AccountContext,
        policy: PhotoBackupAutomationPolicy
    ) throws {
        guard originalRecord.applies(to: account),
              originalRecord.pendingSystemTask == nil,
              originalRecord.uploadSessionID == nil,
              let baseURL = account.serverURL else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }
        let directory = try journal.stagingDirectory(for: originalRecord)
        let bodyURL = directory.appendingPathComponent(originalRecord.manifestFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: bodyURL.path) else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }

        var request = URLRequest(url: baseURL.appending(path: "api/v1/photos/upload-sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-MyNAS-Request")
        let task = session(for: policy.networkPolicy).uploadTask(with: request, fromFile: bodyURL)

        var record = originalRecord
        try record.registerPendingSystemTask(
            PhotoBackupBackgroundTransferTask(
                taskIdentifier: task.taskIdentifier,
                networkPolicy: policy.networkPolicy,
                kind: .createSession,
                bodyFilename: record.manifestFilename,
                responseFilename: responseFilename(for: task.taskIdentifier)
            )
        )
        try replace(record)
        task.resume()
    }

    private func scheduleNextProtocolRequest(
        for originalRecord: PhotoBackupBackgroundTransferRecord,
        account: AccountContext,
        policy: PhotoBackupAutomationPolicy
    ) async throws {
        guard originalRecord.applies(to: account),
              originalRecord.pendingSystemTask == nil,
              let baseURL = account.serverURL,
              let sessionID = originalRecord.uploadSessionID else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }

        if let resource = originalRecord.resources.first(where: {
            $0.receivedBytes < $0.byteSize
        }) {
            guard let remoteResourceID = resource.remoteResourceID,
                  let chunkSize = resource.chunkSize,
                  chunkSize > 0 else {
                throw PhotoBackupBackgroundTransferEngineError.invalidRecord
            }
            let offset = resource.receivedBytes
            let byteCount = min(chunkSize, resource.byteSize - offset)
            let partNumber = offset / chunkSize
            let part = try await materializer.materializePart(
                record: originalRecord,
                clientResourceID: resource.clientResourceID,
                offset: offset,
                byteCount: byteCount
            )
            let directory = try journal.stagingDirectory(for: originalRecord)
            let bodyURL = directory.appendingPathComponent(part.filename, isDirectory: false)
            var request = URLRequest(url: baseURL.appending(
                path: "api/v1/photos/upload-sessions/\(sessionID)/resources/\(remoteResourceID)/parts/\(partNumber)"
            ))
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "X-MyNAS-Request")
            request.setValue(String(offset), forHTTPHeaderField: "X-Upload-Offset")
            request.setValue(part.sha256, forHTTPHeaderField: "X-Chunk-SHA256")
            let task = session(for: policy.networkPolicy).uploadTask(with: request, fromFile: bodyURL)

            var record = originalRecord
            try record.registerPendingSystemTask(
                PhotoBackupBackgroundTransferTask(
                    taskIdentifier: task.taskIdentifier,
                    networkPolicy: policy.networkPolicy,
                    kind: .uploadPart,
                    clientResourceID: resource.clientResourceID,
                    remoteResourceID: remoteResourceID,
                    partNumber: partNumber,
                    offset: offset,
                    byteCount: byteCount,
                    bodyFilename: part.filename,
                    responseFilename: responseFilename(for: task.taskIdentifier)
                )
            )
            try replace(record)
            task.resume()
            return
        }

        let directory = try journal.stagingDirectory(for: originalRecord)
        let bodyURL = directory.appendingPathComponent(originalRecord.completionFilename, isDirectory: false)
        var request = URLRequest(url: baseURL.appending(
            path: "api/v1/photos/upload-sessions/\(sessionID)/complete"
        ))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-MyNAS-Request")
        let task = session(for: policy.networkPolicy).uploadTask(with: request, fromFile: bodyURL)

        var record = originalRecord
        try record.registerPendingSystemTask(
            PhotoBackupBackgroundTransferTask(
                taskIdentifier: task.taskIdentifier,
                networkPolicy: policy.networkPolicy,
                kind: .completeSession,
                bodyFilename: record.completionFilename,
                responseFilename: responseFilename(for: task.taskIdentifier)
            )
        )
        try replace(record)
        task.resume()
    }

    private func processCallback(
        for originalRecord: PhotoBackupBackgroundTransferRecord,
        account: AccountContext,
        policy: PhotoBackupAutomationPolicy
    ) async throws {
        guard originalRecord.applies(to: account),
              let task = originalRecord.pendingSystemTask,
              let statusCode = task.responseStatusCode,
              let responseByteCount = task.responseByteCount,
              (200..<300).contains(statusCode) else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }
        let directory = try journal.stagingDirectory(for: originalRecord)
        let responseURL = directory.appendingPathComponent(task.responseFilename, isDirectory: false)
        let responseData = try Data(contentsOf: responseURL)
        guard Int64(responseData.count) == responseByteCount else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }

        var record = originalRecord
        switch task.kind {
        case .createSession:
            let response = try decoder.decode(PhotoUploadSessionEnvelope.self, from: responseData)
            try applyCreateSession(response, to: &record)
        case .uploadPart:
            let response = try decoder.decode(PhotoUploadPartEnvelope.self, from: responseData)
            try applyPart(response, to: &record)
        case .completeSession:
            let response = try decoder.decode(PhotoUploadSessionEnvelope.self, from: responseData)
            try applyCompletion(response, to: &record)
        }
        try replace(record)

        if record.state != .completed {
            try await scheduleNextProtocolRequest(for: record, account: account, policy: policy)
        }
    }

    private func applyCreateSession(
        _ response: PhotoUploadSessionEnvelope,
        to record: inout PhotoBackupBackgroundTransferRecord
    ) throws {
        guard response.fingerprint == record.fingerprint,
              record.pendingSystemTask?.kind == .createSession else {
            throw PhotoBackupBackgroundTransferEngineError.invalidResponse
        }
        if response.status == "duplicate" || response.status == "completed" {
            let outcome = try PhotoBackupUploader.outcome(
                from: response,
                wasDuplicate: response.status == "duplicate"
            )
            record.outcome = PhotoBackupBackgroundTransferOutcome(
                assetID: outcome.assetID,
                wasDuplicate: outcome.wasDuplicate,
                sourceState: outcome.sourceState,
                derivativeState: outcome.derivativeState,
                browseReady: outcome.browseReady
            )
            record.clearPendingSystemTask(nextState: .completed)
            return
        }

        guard let uploadSessionID = response.id,
              response.resources.count == record.resources.count else {
            throw PhotoBackupBackgroundTransferEngineError.invalidResponse
        }
        let remoteResources = Dictionary(uniqueKeysWithValues: response.resources.map {
            ($0.clientResourceID, $0)
        })
        guard remoteResources.count == record.resources.count else {
            throw PhotoBackupBackgroundTransferEngineError.invalidResponse
        }
        for index in record.resources.indices {
            let resource = record.resources[index]
            guard let remote = remoteResources[resource.clientResourceID],
                  remote.byteSize == resource.byteSize,
                  remote.sha256 == resource.sha256,
                  remote.resourceRole == resource.role,
                  remote.chunkSize > 0,
                  remote.receivedBytes >= 0,
                  remote.receivedBytes <= resource.byteSize else {
                throw PhotoBackupBackgroundTransferEngineError.invalidResponse
            }
            record.resources[index].remoteResourceID = remote.id
            record.resources[index].receivedBytes = remote.receivedBytes
            record.resources[index].chunkSize = remote.chunkSize
        }
        record.uploadSessionID = uploadSessionID
        record.clearPendingSystemTask(nextState: .sessionCreated)
    }

    private func applyPart(
        _ response: PhotoUploadPartEnvelope,
        to record: inout PhotoBackupBackgroundTransferRecord
    ) throws {
        guard let task = record.pendingSystemTask,
              task.kind == .uploadPart,
              let clientResourceID = task.clientResourceID,
              let remoteResourceID = task.remoteResourceID,
              let previousOffset = task.offset,
              let resourceIndex = record.resources.firstIndex(where: {
                  $0.clientResourceID == clientResourceID
              }),
              record.resources[resourceIndex].remoteResourceID == remoteResourceID,
              response.resourceID == remoteResourceID,
              response.receivedBytes >= previousOffset,
              response.receivedBytes <= record.resources[resourceIndex].byteSize else {
            throw PhotoBackupBackgroundTransferEngineError.invalidResponse
        }
        record.resources[resourceIndex].receivedBytes = response.receivedBytes
        record.clearPendingSystemTask(nextState: .sessionCreated)
    }

    private func applyCompletion(
        _ response: PhotoUploadSessionEnvelope,
        to record: inout PhotoBackupBackgroundTransferRecord
    ) throws {
        guard response.status == "completed",
              response.fingerprint == record.fingerprint,
              record.pendingSystemTask?.kind == .completeSession else {
            throw PhotoBackupBackgroundTransferEngineError.invalidResponse
        }
        let outcome = try PhotoBackupUploader.outcome(from: response, wasDuplicate: false)
        record.outcome = PhotoBackupBackgroundTransferOutcome(
            assetID: outcome.assetID,
            wasDuplicate: outcome.wasDuplicate,
            sourceState: outcome.sourceState,
            derivativeState: outcome.derivativeState,
            browseReady: outcome.browseReady
        )
        record.clearPendingSystemTask(nextState: .completed)
    }

    private func handleResponseData(
        taskIdentifier: Int,
        networkPolicy: PhotoBackupAutomaticNetworkPolicy,
        data: Data
    ) {
        guard var record = try? record(
            withTaskIdentifier: taskIdentifier,
            networkPolicy: networkPolicy
        ),
              let task = record.pendingSystemTask else {
            return
        }
        do {
            let directory = try journal.stagingDirectory(for: record)
            let responseURL = directory.appendingPathComponent(task.responseFilename, isDirectory: false)
            if fileManager.fileExists(atPath: responseURL.path) {
                let handle = try FileHandle(forWritingTo: responseURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(
                    to: responseURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: responseURL.path
                )
            }
            // The journal's timestamp makes a partially received response
            // observable without turning it into a protocol result.
            record.updatedAt = Date()
            try replace(record)
        } catch {
            pause(recordID: record.id, taskIdentifier: taskIdentifier, error: failure(from: error))
        }
    }

    private func handleCompletion(
        session: URLSession,
        task: URLSessionTask,
        error: Error?
    ) {
        guard let networkPolicy = networkPolicy(for: session),
              var record = try? record(
                  withTaskIdentifier: task.taskIdentifier,
                  networkPolicy: networkPolicy
              ) else {
            return
        }
        do {
            if let error {
                try record.pausePendingSystemTask(
                    taskIdentifier: task.taskIdentifier,
                    error: failure(from: error)
                )
                try replace(record)
                scheduleBackgroundProcessingIfEligible()
                return
            }
            let pendingTask = try requiredPendingTask(
                taskIdentifier: task.taskIdentifier,
                networkPolicy: networkPolicy,
                record: record
            )
            let directory = try journal.stagingDirectory(for: record)
            let responseURL = directory.appendingPathComponent(pendingTask.responseFilename, isDirectory: false)
            if !fileManager.fileExists(atPath: responseURL.path) {
                try Data().write(
                    to: responseURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: responseURL.path
                )
            }
            let responseBytes = try fileManager.attributesOfItem(atPath: responseURL.path)[.size] as? NSNumber
            try record.markPendingSystemTaskAwaitingCallback(
                taskIdentifier: task.taskIdentifier,
                responseStatusCode: (task.response as? HTTPURLResponse)?.statusCode,
                responseByteCount: responseBytes?.int64Value ?? 0
            )
            try replace(record)
            continuePersistedTransfer(recordID: record.id)
        } catch {
            pause(recordID: record.id, taskIdentifier: task.taskIdentifier, error: failure(from: error))
        }
    }

    private func continuePersistedTransfer(recordID: UUID) {
        Task { @MainActor [weak self] in
            guard let self,
                  let record = try? self.currentRecord(id: recordID),
                  let eligibility = self.persistedEligibility(for: record) else {
                return
            }
            await self.continueFirstEligibleTransfer(
                account: eligibility.account,
                policy: eligibility.policy
            )
        }
    }

    private func canContinueInBackgroundProcessing(
        _ record: PhotoBackupBackgroundTransferRecord
    ) -> Bool {
        switch record.state {
        case .prepared, .sessionCreated, .paused, .awaitingAppCallback:
            return true
        case .transferring, .completed, .failed:
            return false
        }
    }

    private func persistedEligibility(
        for record: PhotoBackupBackgroundTransferRecord,
        requiresAllowedPower: Bool = true
    ) -> (account: AccountContext, policy: PhotoBackupAutomationPolicy)? {
        guard let snapshot = try? accountPersistence.load(),
              snapshot.currentAccountID == record.accountID,
              let account = snapshot.accounts.first(where: {
                  $0.accountID == record.accountID && record.applies(to: $0)
              }),
              account.serverCapabilities.supportsBackgroundTransfers,
              let policy = try? policyPersistence.load().first(where: {
                  $0.applies(to: account) && $0.isEnabled
              }),
              !requiresAllowedPower || !policy.pausesInLowPowerMode || !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return nil
        }
        return (account, policy)
    }

    private func currentRecord(id: UUID) throws -> PhotoBackupBackgroundTransferRecord {
        guard let record = try journal.load().first(where: { $0.id == id }) else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }
        return record
    }

    private func record(
        withTaskIdentifier taskIdentifier: Int,
        networkPolicy: PhotoBackupAutomaticNetworkPolicy
    ) throws -> PhotoBackupBackgroundTransferRecord {
        let candidates = try journal.load().filter { record in
            guard let pendingTask = record.pendingSystemTask,
                  pendingTask.taskIdentifier == taskIdentifier else {
                return false
            }
            return pendingTask.networkPolicy == networkPolicy || pendingTask.networkPolicy == nil
        }
        guard candidates.count == 1, var record = candidates.first else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }
        // Pre-session-identity journals can be migrated only after the callback
        // itself proves which of the two fixed sessions owns this one task. If
        // more than one legacy record uses the same ID, the guard above leaves
        // all of them untouched rather than guessing an account association.
        if record.pendingSystemTask?.networkPolicy == nil {
            record.pendingSystemTask?.networkPolicy = networkPolicy
            try replace(record)
        }
        return record
    }

    private func requiredPendingTask(
        taskIdentifier: Int,
        networkPolicy: PhotoBackupAutomaticNetworkPolicy,
        record: PhotoBackupBackgroundTransferRecord
    ) throws -> PhotoBackupBackgroundTransferTask {
        guard let task = record.pendingSystemTask,
              task.taskIdentifier == taskIdentifier,
              task.networkPolicy == networkPolicy else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }
        return task
    }

    private func replace(_ record: PhotoBackupBackgroundTransferRecord) throws {
        var records = try journal.load()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            throw PhotoBackupBackgroundTransferEngineError.invalidRecord
        }
        records[index] = record
        try journal.save(records)
        if record.pendingSystemTask?.kind != .uploadPart {
            _ = clearInFlightUploadProgress(for: record.id)
        }
        stateRevision &+= 1
    }

    @discardableResult
    private func clearInFlightUploadProgress(for recordID: UUID) -> Bool {
        let identities = inFlightUploadProgress.compactMap { identity, progress in
            progress.recordID == recordID ? identity : nil
        }
        guard !identities.isEmpty else { return false }
        identities.forEach { inFlightUploadProgress.removeValue(forKey: $0) }
        transferProgressRevision &+= 1
        return true
    }

    private func pause(
        recordID: UUID,
        taskIdentifier: Int?,
        error: PhotoBackupFailure
    ) {
        guard var record = try? currentRecord(id: recordID) else { return }
        if let taskIdentifier,
           record.pendingSystemTask?.taskIdentifier == taskIdentifier {
            try? record.pausePendingSystemTask(taskIdentifier: taskIdentifier, error: error)
        } else {
            record.pauseForValidatedResumption(error: error)
        }
        try? replace(record)
        scheduleBackgroundProcessingIfEligible()
    }

    /// Network and callback failures leave a verified staged record paused.
    /// Ask iOS for one constrained recovery opportunity while this process is
    /// still alive; the scheduler rechecks account, capability, policy and
    /// Low Power state before it can resume anything.
    private func scheduleBackgroundProcessingIfEligible() {
        PhotoBackupBackgroundProcessingScheduler.shared.scheduleIfEligible(engine: self)
    }

    private func responseFilename(for taskIdentifier: Int) -> String {
        "response-\(taskIdentifier)"
    }

    private func networkPolicy(for session: URLSession) -> PhotoBackupAutomaticNetworkPolicy? {
        guard let identifier = session.configuration.identifier else { return nil }
        return networkPolicy(forSessionIdentifier: identifier)
    }

    private func networkPolicy(
        forSessionIdentifier identifier: String
    ) -> PhotoBackupAutomaticNetworkPolicy? {
        switch identifier {
        case "\(Self.sessionIdentifierPrefix).\(PhotoBackupAutomaticNetworkPolicy.wifiOnly.rawValue)":
            .wifiOnly
        case "\(Self.sessionIdentifierPrefix).\(PhotoBackupAutomaticNetworkPolicy.anyNetwork.rawValue)":
            .anyNetwork
        default:
            nil
        }
    }

    private func failure(from error: Error) -> PhotoBackupFailure {
        let kind: PhotoBackupFailureKind
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                kind = .network
            default:
                kind = .unknown
            }
        } else if let uploadError = error as? PhotoBackupUploadError,
                  case .server(let status, _) = uploadError {
            kind = (500...599).contains(status) ? .server : .configuration
        } else {
            kind = .unknown
        }
        return PhotoBackupFailure(kind: kind, detail: error.localizedDescription, occurredAt: Date())
    }
}

nonisolated enum PhotoBackupBackgroundProcessingDisposition: Equatable, Sendable {
    case noEligibleTransfer
    case deferredForLowPower
    case continued
    case cancelled
}

extension PhotoBackupBackgroundTransferEngine: URLSessionDataDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let networkPolicy = self?.networkPolicy(for: session) else { return }
            _ = self?.recordUploadProgress(
                taskIdentifier: task.taskIdentifier,
                networkPolicy: networkPolicy,
                totalBytesSent: totalBytesSent
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        Task { @MainActor [weak self] in
            guard let networkPolicy = self?.networkPolicy(for: session) else { return }
            self?.handleResponseData(
                taskIdentifier: dataTask.taskIdentifier,
                networkPolicy: networkPolicy,
                data: data
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleCompletion(session: session, task: task, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handler = self.backgroundEventCompletionHandlers.removeValue(forKey: session.configuration.identifier ?? "")
            handler?()
        }
    }
}

nonisolated enum PhotoBackupBackgroundTransferEngineError: LocalizedError {
    case backgroundTransferUnavailable
    case pausedForLowPower
    case invalidRecord
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .backgroundTransferUnavailable:
            "当前 MyNAS 或自动备份策略尚未允许系统后台传输。"
        case .pausedForLowPower:
            "iPhone 当前处于低电量模式，自动备份策略要求暂停。"
        case .invalidRecord:
            "后台传输记录与当前 MyNAS 账号或资源组不匹配。"
        case .invalidResponse:
            "MyNAS 返回了无法安全恢复的后台上传响应。"
        }
    }
}
