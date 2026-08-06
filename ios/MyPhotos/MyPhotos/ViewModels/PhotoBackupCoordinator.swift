import Foundation
import Combine
import Security

/// Describes what happened to the matching local Photos item after MyNAS
/// accepted a remote deletion. This stays outside the persisted job schema:
/// it explains the current user action, while the persisted failure remains a
/// durable signal that automatic backup must not recreate the removed copy.
enum PhotoBackupRemoteDeletionLocalDisposition: Sendable {
    case retained
    case movedToRecentlyDeleted

    var jobMessage: String {
        switch self {
        case .retained:
            "MyNAS 副本已删除；本机照片仍保留"
        case .movedToRecentlyDeleted:
            "MyNAS 副本已删除；本机照片已移入“最近删除”"
        }
    }

    var failureDetail: String {
        switch self {
        case .retained:
            "用户已从 MyNAS 图库永久删除该项目，本机照片未被删除。"
        case .movedToRecentlyDeleted:
            "用户已从 MyNAS 图库永久删除该项目，本机照片已由 iOS 移入“最近删除”。"
        }
    }
}

/// The result of registering a local resource group that the user has already
/// proved byte-for-byte equal to a visible MyNAS item. The coordinator still
/// asks MyNAS to create its normal, device-scoped mapping; this result never
/// treats a client-side comparison as permission for paired deletion.
enum PhotoBackupVerifiedLocalAssociationResult: Equatable, Sendable {
    case started
    case alreadyAssociated
    case unavailable(String)
}

private enum PhotoBackupVerifiedAssociationError: LocalizedError {
    case unexpectedRemoteAsset(expected: String, received: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedRemoteAsset(let expected, let received):
            "MyNAS 返回了不同的原件标识（预期 \(expected)，收到 \(received)），已拒绝建立关联。"
        }
    }
}

@MainActor
final class PhotoBackupCoordinator: ObservableObject {
    @Published private(set) var jobs: [PhotoBackupJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var headline = "尚未开始备份"
    @Published private(set) var automationPolicies: [PhotoBackupAutomationPolicy] = []
    @Published private(set) var automationStatuses: [String: PhotoBackupAutomationStatus] = [:]

    private let uploader: PhotoBackupUploader
    private let mappingClient: RemotePhotoLibraryClient
    private let backgroundTransferEngine: PhotoBackupBackgroundTransferEngine
    private let persistence: PhotoBackupPersistenceStore
    private let automationPersistence: PhotoBackupAutomationPolicyStore
    private let deviceID: String
    let automationConditions: PhotoBackupAutomationConditions
    private var runTask: Task<Void, Never>?
    private var activeRunAccountID: String?
    private var activeRunIntent: BackupRunIntent?
    private var automationConditionObservation: AnyCancellable?
    private var backgroundTransferObservation: AnyCancellable?
    private var backgroundTransferProgressObservation: AnyCancellable?
    /// iOS transport counters are display-only. The persisted queue remains
    /// based on MyNAS-confirmed offsets and outcomes.
    @Published private var backgroundTransferProgress: [UUID: PhotoBackupBackgroundTransferProgress] = [:]
    private var mappingRecoveryRequests: [String: MappingRecoveryRequest] = [:]
    private var mappingRecoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveredMappingsByAccountID: [String: [ServerDeviceAssetMapping]] = [:]
    private var automaticRequests: [String: AutomaticBackupRequest] = [:]
    private var isAppInForeground = false
    private var activeAutomaticAccountID: String?
    private var remoteCopyReconciliationTask: Task<Void, Never>?
    private var activeRemoteCopyReconciliationAccountID: String?
    private var pendingRemoteCopyReconciliation: RemoteCopyReconciliationRequest?
    private var checkedRemoteCopyPairs: Set<RemoteCopyVerificationPair> = []
    /// Exact association requests are never discarded merely because another
    /// backup or mapping recovery is active. Their target is persisted on the
    /// job; this in-memory snapshot only starts the foreground upload as soon
    /// as the current coordinator work becomes idle.
    private var pendingVerifiedAssociationRuns: [String: VerifiedAssociationRunRequest] = [:]

    private struct RemoteCopyReconciliationRequest {
        let remoteAssets: [ServerPhotoAsset]
        let localAssets: [LocalPhotoAsset]
        let account: AccountContext
        let client: PhotoLibraryClient
    }

    private struct RemoteCopyVerificationPair: Hashable {
        let accountID: String
        let remoteAssetID: String
        let remoteVersion: String
        let localIdentifier: String
        let localModificationDate: Date?
    }

    private struct VerifiedAssociationRunRequest {
        let assets: [LocalPhotoAsset]
        let account: AccountContext
        let client: PhotoLibraryClient
    }

    /// Keeps only the local snapshot needed to reconcile previously verified
    /// mappings after an account becomes available. It is deliberately not an
    /// upload request: Stage G background/automatic backup has not shipped.
    private struct MappingRecoveryRequest {
        let assets: [LocalPhotoAsset]
        let account: AccountContext
    }

    /// This snapshot exists only while the process is alive. It supplies the
    /// latest foreground PhotoKit values to a policy re-check after Wi-Fi or
    /// power state changes; it is not a persisted background-upload request.
    private struct AutomaticBackupRequest {
        let assets: [LocalPhotoAsset]
        let account: AccountContext
        let client: PhotoLibraryClient
    }

    private struct PhotoBackupBackgroundTransferSourceKey: Hashable {
        let localIdentifier: String
        let sourceModificationDate: Date?
    }

    private enum BackupRunIntent: Equatable {
        case manual
        case automatic
    }

    init(
        uploader: PhotoBackupUploader = PhotoBackupUploader(),
        mappingClient: RemotePhotoLibraryClient = RemotePhotoLibraryClient(),
        backgroundTransferEngine: PhotoBackupBackgroundTransferEngine? = nil,
        persistence: PhotoBackupPersistenceStore = PhotoBackupPersistenceStore(),
        automationPersistence: PhotoBackupAutomationPolicyStore = PhotoBackupAutomationPolicyStore(),
        automationConditions: PhotoBackupAutomationConditions? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        let resolvedAutomationConditions = automationConditions ?? PhotoBackupAutomationConditions()
        self.uploader = uploader
        self.mappingClient = mappingClient
        self.backgroundTransferEngine = backgroundTransferEngine ?? .shared
        self.persistence = persistence
        self.automationPersistence = automationPersistence
        self.automationConditions = resolvedAutomationConditions
        self.deviceID = Self.persistentDeviceID(userDefaults: userDefaults)
        self.jobs = (try? persistence.load()) ?? []
        self.automationPolicies = (try? automationPersistence.load()) ?? []
        normalizeInterruptedJobs()
        self.automationConditionObservation = resolvedAutomationConditions.$snapshot.sink { [weak self] _ in
            self?.reevaluateAutomaticBackupRequests()
        }
        self.backgroundTransferObservation = self.backgroundTransferEngine.$stateRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.reconcileBackgroundTransferJournalChanges()
            }
        self.backgroundTransferProgressObservation = self.backgroundTransferEngine.$transferProgressRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.reconcileBackgroundTransferJournalChanges()
            }
    }

    deinit {
        runTask?.cancel()
        mappingRecoveryTasks.values.forEach { $0.cancel() }
        automationConditionObservation?.cancel()
        backgroundTransferObservation?.cancel()
        backgroundTransferProgressObservation?.cancel()
    }

    func jobs(for accountID: String) -> [PhotoBackupJob] {
        jobs
            .filter { $0.accountID == accountID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// UI summaries must be derived from the account and the current PhotoKit
    /// source versions being viewed. The legacy `headline` is updated by
    /// asynchronous queue and mapping work, while the persisted queue can also
    /// contain historical jobs for assets that are no longer accessible. This
    /// keeps the displayed count aligned with the current progress snapshot.
    func headline(for accountID: String, assets: [LocalPhotoAsset]) -> String {
        if isRunning, activeRunAccountID == accountID {
            return "正在备份"
        }
        if mappingRecoveryTasks[accountID] != nil {
            return "正在向 MyNAS 核验已有备份…"
        }

        return progress(for: accountID, assets: assets).statusSummary
    }

    func progress(
        for accountID: String,
        assets: [LocalPhotoAsset]
    ) -> PhotoBackupProgressSnapshot {
        let accountJobs = jobs.filter { $0.accountID == accountID }
        let jobsByIdentifier = Dictionary(
            uniqueKeysWithValues: accountJobs.map { ($0.localIdentifier, $0) }
        )
        let currentJobs = assets.compactMap { asset -> PhotoBackupJob? in
            guard let job = jobsByIdentifier[asset.localIdentifier],
                  job.matchesCurrentLocalAsset(asset) else {
                return nil
            }
            return job
        }
        let activeProgressBySource: [PhotoBackupBackgroundTransferSourceKey: PhotoBackupBackgroundTransferProgress] = Dictionary(
            backgroundTransferProgress.values.compactMap { progress in
                guard progress.accountID == accountID else { return nil }
                return (PhotoBackupBackgroundTransferSourceKey(
                    localIdentifier: progress.localIdentifier,
                    sourceModificationDate: progress.sourceModificationDate
                ), progress)
            },
            uniquingKeysWith: { existing, latest in
                latest.reportedBytes >= existing.reportedBytes ? latest : existing
            }
        )
        var provisionalBytes: Int64 = 0
        let uploadedBytes = currentJobs.reduce(Int64(0)) { total, job in
            let persistedBytes = max(0, min(job.uploadedBytes, job.totalBytes))
            let key = PhotoBackupBackgroundTransferSourceKey(
                localIdentifier: job.localIdentifier,
                sourceModificationDate: job.sourceModificationDate
            )
            guard let progress = activeProgressBySource[key] else {
                return total + persistedBytes
            }
            let displayedBytes = max(
                persistedBytes,
                min(max(0, progress.reportedBytes), max(job.totalBytes, progress.totalBytes))
            )
            provisionalBytes += max(0, displayedBytes - persistedBytes)
            return total + displayedBytes
        }
        let totalBytes = currentJobs.reduce(Int64(0)) { total, job in
            let key = PhotoBackupBackgroundTransferSourceKey(
                localIdentifier: job.localIdentifier,
                sourceModificationDate: job.sourceModificationDate
            )
            return total + max(job.totalBytes, activeProgressBySource[key]?.totalBytes ?? 0)
        }
        let sizePendingCount = assets.count - currentJobs.filter { $0.totalBytes > 0 }.count
        return PhotoBackupProgressSnapshot(
            completedCount: currentJobs.filter { $0.status == .completed }.count,
            failedCount: currentJobs.filter { $0.status == .failed }.count,
            totalCount: assets.count,
            isRunning: (isRunning && accountJobs.contains {
                $0.status == .preparing || $0.status == .uploading || $0.status == .waiting
            }) || !activeProgressBySource.isEmpty,
            uploadedBytes: uploadedBytes,
            totalBytes: totalBytes,
            sizePendingCount: sizePendingCount,
            provisionalBytes: provisionalBytes
        )
    }

    func pendingCount(
        for assets: [LocalPhotoAsset],
        accountID: String
    ) -> Int {
        let accountJobs = jobs.filter { $0.accountID == accountID }
        let jobsByIdentifier = Dictionary(
            uniqueKeysWithValues: accountJobs.map { ($0.localIdentifier, $0) }
        )
        return assets.reduce(into: 0) { count, asset in
            guard let job = jobsByIdentifier[asset.localIdentifier],
                  job.status == .completed,
                  job.matchesCurrentLocalAsset(asset) else {
                count += 1
                return
            }
        }
    }

    func retryableFailedCount(
        for assets: [LocalPhotoAsset],
        accountID: String
    ) -> Int {
        let availableIdentifiers = Set(assets.map(\.localIdentifier))
        return jobs.filter {
            $0.accountID == accountID
                && $0.status == .failed
                && availableIdentifiers.contains($0.localIdentifier)
        }.count
    }

    func automationPolicy(for account: AccountContext) -> PhotoBackupAutomationPolicy {
        guard let policy = automationPolicies.first(where: { $0.applies(to: account) }) else {
            return .disabled(for: account)
        }
        return policy
    }

    func automationStatus(for account: AccountContext) -> PhotoBackupAutomationStatus {
        automationStatuses[account.accountID] ?? .disabled
    }

    /// The scene phase is an explicit gate: G1 can observe and upload only
    /// while this SwiftUI scene is active. No background task is registered.
    func setAppIsForeground(_ isForeground: Bool) {
        guard isAppInForeground != isForeground else { return }
        isAppInForeground = isForeground
        reevaluateAutomaticBackupRequests()
    }

    func setAutomaticBackupEnabled(_ isEnabled: Bool, for account: AccountContext) {
        updateAutomationPolicy(for: account) { policy in
            policy.isEnabled = isEnabled
        }
    }

    func setAutomaticNetworkPolicy(
        _ networkPolicy: PhotoBackupAutomaticNetworkPolicy,
        for account: AccountContext
    ) {
        updateAutomationPolicy(for: account) { policy in
            policy.networkPolicy = networkPolicy
        }
    }

    func setAutomaticLowPowerPause(_ pausesInLowPowerMode: Bool, for account: AccountContext) {
        updateAutomationPolicy(for: account) { policy in
            policy.pausesInLowPowerMode = pausesInLowPowerMode
        }
    }

    /// G1's automatic discovery entry point. It runs only when the local
    /// library changed or the active scene returned to the foreground.
    func discoverAndAutomaticallyBackUp(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        selectAutomaticBackupAccount(account)
        guard !account.isLocalOnly else { return }
        // This call owns its prerequisite rather than relying on a SwiftUI
        // caller to have reconciled first. A failed mapping fetch must fail
        // closed for automatic work, so existing verified items are never
        // mistaken for newly discovered uploads.
        synchronizeLibrary(assets: assets, account: account)
        automaticRequests[account.accountID] = AutomaticBackupRequest(
            assets: assets,
            account: account,
            client: client
        )
        evaluateAutomaticBackup(for: account.accountID)
    }

    /// A green backup check is meaningful only for the current PhotoKit source
    /// version and a server-confirmed, committed resource group. This is shared
    /// by the grid and the deletion flow so an edited photo cannot inherit the
    /// old version's backup state.
    func hasCurrentVerifiedBackup(
        for asset: LocalPhotoAsset,
        accountID: String
    ) -> Bool {
        guard let job = jobs.first(where: {
            $0.accountID == accountID && $0.localIdentifier == asset.localIdentifier
        }) else {
            return false
        }
        return job.status == .completed
            && job.sourceState == .committed
            && job.matchesCurrentLocalAsset(asset)
            && job.assetID?.isEmpty == false
    }

    /// Produces deletion candidates only for current, integrity-verified
    /// source versions. The MyNAS endpoint still repeats every check because
    /// the local job store can be stale while the user is viewing the sheet.
    func deletionCandidates(
        for assets: [LocalPhotoAsset],
        accountID: String
    ) -> [PhotoBackupDeletionCandidate] {
        assets.compactMap { asset in
            guard let job = jobs.first(where: {
                $0.accountID == accountID && $0.localIdentifier == asset.localIdentifier
            }),
            job.status == .completed,
            job.sourceState == .committed,
            job.matchesCurrentLocalAsset(asset),
            let assetID = job.assetID,
            !assetID.isEmpty,
            let sourceModificationDate = job.sourceModificationDate else {
                return nil
            }
            return PhotoBackupDeletionCandidate(
                assetID: assetID,
                deviceID: deviceID,
                localIdentifier: asset.localIdentifier,
                sourceModificationDate: PhotoBackupSourceVersion.string(from: sourceModificationDate)
            )
        }
    }

    /// A successful H1 remote deletion invalidates any local completed-job
    /// proof for that remote asset. Keeping the job failed (rather than
    /// immediately waiting) prevents an enabled automatic policy from silently
    /// recreating a backup the user just chose to remove; a later manual retry
    /// reuses the normal, fully verified upload path.
    func markRemoteBackupDeleted(
        assetID: String,
        accountID: String,
        localDisposition: PhotoBackupRemoteDeletionLocalDisposition = .retained
    ) {
        let normalizedAssetID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAssetID.isEmpty else { return }
        var changed = false
        for index in jobs.indices where
            jobs[index].accountID == accountID
                && (jobs[index].assetID == normalizedAssetID
                    || jobs[index].pendingVerifiedRemoteAssetID == normalizedAssetID) {
            jobs[index].status = .failed
            jobs[index].uploadedBytes = 0
            jobs[index].totalBytes = 0
            jobs[index].resourceCount = 0
            jobs[index].assetID = nil
            jobs[index].pendingVerifiedRemoteAssetID = nil
            jobs[index].sourceState = nil
            jobs[index].derivativeState = nil
            jobs[index].origin = .manual
            jobs[index].message = localDisposition.jobMessage
            jobs[index].failure = PhotoBackupFailure(
                kind: .remoteDeleted,
                detail: localDisposition.failureDetail,
                occurredAt: Date()
            )
            jobs[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        persist()
        refreshHeadline(accountID: accountID)
    }

    func synchronizeLibrary(
        assets: [LocalPhotoAsset],
        account: AccountContext
    ) {
        guard !account.isLocalOnly else { return }
        // Mapping recovery is separate from automatic-upload consent. G1
        // waits for a successful recovery when the server supports it.
        mappingRecoveryRequests[account.accountID] = MappingRecoveryRequest(
            assets: assets,
            account: account
        )
        if shouldRecoverDeviceMappings(for: account) {
            recoverDeviceMappingsIfNeeded(for: account)
            return
        }
        let recoveredCount = restoreDeviceMappings(
            for: assets,
            account: account
        )
        if recoveredCount > 0 {
            headline = "已从 MyNAS 验证记录恢复 \(recoveredCount) 项备份状态"
        }
    }

    /// Accepts a PhotoKit revision only when its own change detail proved that
    /// image/video bytes did not change. This keeps a committed MyNAS resource
    /// group linked across favourite, album or other metadata edits while the
    /// stored `sourceModificationDate` remains the server-side deletion proof.
    /// Any identifier omitted from this set stays on the existing fail-closed
    /// path and must be backed up again when its modification date differs.
    func reconcileMetadataOnlyLibraryChanges(
        assetIdentifiers: Set<String>,
        assets: [LocalPhotoAsset],
        accountID: String,
        client: PhotoLibraryClient? = nil
    ) {
        guard !assetIdentifiers.isEmpty else { return }
        var assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) }
        )
        // The timeline is paged, so a changed item can sit outside the loaded
        // grid slice. Resolve only the PhotoKit-proven identifiers rather than
        // forcing another full-library metadata fetch on the UI actor.
        for identifier in assetIdentifiers {
            if assetsByIdentifier[identifier] == nil,
               let asset = client?.accessibleAsset(localIdentifier: identifier) {
                assetsByIdentifier[identifier] = asset
            }
        }
        var changed = false

        for index in jobs.indices where
            jobs[index].accountID == accountID &&
                assetIdentifiers.contains(jobs[index].localIdentifier) {
            guard let asset = assetsByIdentifier[jobs[index].localIdentifier],
                  jobs[index].status == .completed,
                  jobs[index].sourceState == .committed,
                  jobs[index].assetID?.isEmpty == false,
                  !jobs[index].matchesCurrentLocalAsset(asset) else {
                continue
            }
            jobs[index].lastKnownLocalModificationDate = asset.modificationDate
            jobs[index].updatedAt = Date()
            changed = true
        }

        guard changed else { return }
        persist()
        refreshHeadline(accountID: accountID)
    }

    func startManualBackup(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        guard !isRunning else { return }
        if mappingRecoveryTasks[account.accountID] != nil {
            headline = "正在向 MyNAS 核验已有备份…"
            return
        }
        guard !account.isLocalOnly else {
            headline = "请先连接 MyNAS"
            return
        }
        guard account.selectedVolumeID != nil else {
            headline = "请先选择备份硬盘"
            return
        }
        enqueue(
            assets: assets,
            accountID: account.accountID,
            retryFailed: true,
            origin: .manual
        )
        run(account: account, assets: assets, client: client, intent: .manual)
    }

    /// Registers a current Photos identifier against the MyNAS item the user
    /// just verified with `RemotePhotoLocalCopyVerification`. It deliberately
    /// goes through the normal upload-session protocol: MyNAS remains the
    /// authority for the device mapping and answers with a duplicate session
    /// only when its stored complete resource group is identical.
    func registerVerifiedLocalCopy(
        _ localAsset: LocalPhotoAsset,
        expectedRemoteAssetID: String,
        account: AccountContext,
        client: PhotoLibraryClient
    ) -> PhotoBackupVerifiedLocalAssociationResult {
        registerVerifiedLocalCopies(
            [localAsset],
            expectedRemoteAssetID: expectedRemoteAssetID,
            account: account,
            client: client
        )
    }

    /// Registers every local Photos item that was independently proven to be
    /// the same complete resource group as one visible MyNAS item. This is
    /// particularly important for earlier restore builds, which could have
    /// imported more than one physical Photos copy before their mappings were
    /// registered. The method never removes a Photos asset.
    func registerVerifiedLocalCopies(
        _ localAssets: [LocalPhotoAsset],
        expectedRemoteAssetID: String,
        account: AccountContext,
        client: PhotoLibraryClient
    ) -> PhotoBackupVerifiedLocalAssociationResult {
        let normalizedRemoteID = expectedRemoteAssetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemoteID.isEmpty else {
            return .unavailable("MyNAS 项目无效，请刷新后重试。")
        }
        guard !account.isLocalOnly else {
            return .unavailable("请先连接 MyNAS。")
        }
        guard account.selectedVolumeID != nil else {
            return .unavailable("请先选择备份硬盘。")
        }

        var seenLocalIdentifiers = Set<String>()
        let localCopiesNeedingAssociation = localAssets.filter { localAsset in
            guard seenLocalIdentifiers.insert(localAsset.localIdentifier).inserted else {
                return false
            }
            return !jobs.contains(where: { job in
                job.accountID == account.accountID
                    && job.localIdentifier == localAsset.localIdentifier
                    && job.status == .completed
                    && job.matchesCurrentLocalAsset(localAsset)
                    && job.assetID == normalizedRemoteID
                    && job.sourceState == .committed
            })
        }
        guard !localCopiesNeedingAssociation.isEmpty else {
            return .alreadyAssociated
        }

        localCopiesNeedingAssociation.forEach {
            enqueueVerifiedLocalAssociation(
                $0,
                expectedRemoteAssetID: normalizedRemoteID,
                accountID: account.accountID
            )
        }
        if isRunning || mappingRecoveryTasks[account.accountID] != nil {
            mergePendingVerifiedAssociationRun(
                assets: localCopiesNeedingAssociation,
                account: account,
                client: client
            )
            return .started
        }
        run(
            account: account,
            assets: localCopiesNeedingAssociation,
            client: client,
            intent: .manual
        )
        return .started
    }

    /// Repairs historical physical duplicates and MyNAS downloads whose first
    /// device mapping was lost. No pre-existing mapping is required: a local
    /// item is eligible only after every original resource role, byte count,
    /// and SHA-256 value matches exactly one visible MyNAS item. Ambiguous
    /// server duplicates are left separate instead of being guessed.
    func reconcileVerifiedRemoteCopies(
        remoteAssets: [ServerPhotoAsset],
        localAssets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        guard !account.isLocalOnly,
              account.selectedVolumeID != nil,
              !remoteAssets.isEmpty,
              !localAssets.isEmpty else {
            return
        }

        let request = RemoteCopyReconciliationRequest(
            remoteAssets: remoteAssets,
            localAssets: localAssets,
            account: account,
            client: client
        )
        if remoteCopyReconciliationTask != nil {
            if activeRemoteCopyReconciliationAccountID == account.accountID {
                pendingRemoteCopyReconciliation = request
                return
            }
            remoteCopyReconciliationTask?.cancel()
            remoteCopyReconciliationTask = nil
        }
        startRemoteCopyReconciliation(request)
    }

    private func startRemoteCopyReconciliation(
        _ request: RemoteCopyReconciliationRequest
    ) {
        activeRemoteCopyReconciliationAccountID = request.account.accountID
        remoteCopyReconciliationTask = Task { [weak self] in
            guard let self else { return }
            await self.performVerifiedRemoteCopyReconciliation(
                remoteAssets: request.remoteAssets,
                localAssets: request.localAssets,
                account: request.account,
                client: request.client
            )
            guard !Task.isCancelled else { return }
            self.remoteCopyReconciliationTask = nil
            self.activeRemoteCopyReconciliationAccountID = nil
            if let pending = self.pendingRemoteCopyReconciliation {
                self.pendingRemoteCopyReconciliation = nil
                self.startRemoteCopyReconciliation(pending)
            }
        }
    }

    private func performVerifiedRemoteCopyReconciliation(
        remoteAssets: [ServerPhotoAsset],
        localAssets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) async {
        // The exact target is persisted, while the run request intentionally
        // is not. Rebuild that request from the complete PhotoKit metadata
        // snapshot after an app restart so an older imported copy cannot stay
        // permanently stuck merely because it is outside the paged home grid.
        let interruptedVerifiedAssets = localAssets.filter { asset in
            jobs.contains { job in
                job.accountID == account.accountID
                    && job.localIdentifier == asset.localIdentifier
                    && job.status == .waiting
                    && job.origin != .automatic
                    && job.pendingVerifiedRemoteAssetID?.isEmpty == false
                    && job.matchesCurrentLocalAsset(asset)
            }
        }
        if !interruptedVerifiedAssets.isEmpty {
            mergePendingVerifiedAssociationRun(
                assets: interruptedVerifiedAssets,
                account: account,
                client: client
            )
            startPendingVerifiedAssociationRunIfPossible(
                preferredAccountID: account.accountID
            )
        }

        let verifiableRemoteAssets = remoteAssets.filter { !$0.resources.isEmpty }
        guard !verifiableRemoteAssets.isEmpty else { return }

        var matchesByRemoteID: [String: [LocalPhotoAsset]] = [:]
        for localAsset in localAssets {
            guard !Task.isCancelled else { return }
            let alreadyHasExactAssociation = jobs.contains { job in
                job.accountID == account.accountID
                    && job.localIdentifier == localAsset.localIdentifier
                    && job.matchesCurrentLocalAsset(localAsset)
                    && (job.assetID?.isEmpty == false
                        || job.pendingVerifiedRemoteAssetID?.isEmpty == false)
            }
            guard !alreadyHasExactAssociation else { continue }
            while (isRunning || mappingRecoveryTasks[account.accountID] != nil),
                  !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            let uncheckedRemotes = verifiableRemoteAssets.filter { remoteAsset in
                guard RemotePhotoLocalCopyVerification.isCandidate(
                    localAsset,
                    for: remoteAsset
                ) else {
                    return false
                }
                let isAlreadyAssociated = jobs.contains { job in
                    job.accountID == account.accountID
                        && job.localIdentifier == localAsset.localIdentifier
                        && job.status == .completed
                        && job.sourceState == .committed
                        && job.matchesCurrentLocalAsset(localAsset)
                        && job.assetID == remoteAsset.id
                }
                guard !isAlreadyAssociated else { return false }
                return !checkedRemoteCopyPairs.contains(
                    RemoteCopyVerificationPair(
                        accountID: account.accountID,
                        remoteAssetID: remoteAsset.id,
                        remoteVersion: remoteAsset.version,
                        localIdentifier: localAsset.localIdentifier,
                        localModificationDate: localAsset.modificationDate
                    )
                )
            }
            guard !uncheckedRemotes.isEmpty else { continue }

            do {
                let prepared = try await client.prepareBackupAsset(
                    localAsset,
                    allowsNetworkAccess: false
                )
                defer { prepared.removeTemporaryFiles() }
                guard !Task.isCancelled else { return }
                let evaluatedPairs = uncheckedRemotes.map { remoteAsset in
                    RemoteCopyVerificationPair(
                        accountID: account.accountID,
                        remoteAssetID: remoteAsset.id,
                        remoteVersion: remoteAsset.version,
                        localIdentifier: localAsset.localIdentifier,
                        localModificationDate: localAsset.modificationDate
                    )
                }
                let exactRemoteMatch = RemotePhotoLocalCopyVerification
                    .uniqueCompleteResourceGroupMatch(
                        localResources: prepared.resources,
                        among: uncheckedRemotes
                    )
                checkedRemoteCopyPairs.formUnion(evaluatedPairs)
                // If the server itself exposes multiple logical items with an
                // identical resource group, choosing one ID would be an
                // identity guess. Leave all of them visible for repair.
                if let exactRemote = exactRemoteMatch {
                    matchesByRemoteID[exactRemote.id, default: []].append(localAsset)
                }
            } catch {
                // An iCloud-only or temporarily unavailable original remains
                // unchecked so a later foreground reconciliation can retry it.
                continue
            }
        }

        for remoteAsset in verifiableRemoteAssets {
            guard !Task.isCancelled,
                  let matches = matchesByRemoteID[remoteAsset.id],
                  !matches.isEmpty else {
                continue
            }
            while (isRunning || mappingRecoveryTasks[account.accountID] != nil),
                  !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            let result = registerVerifiedLocalCopies(
                matches,
                expectedRemoteAssetID: remoteAsset.id,
                account: account,
                client: client
            )
            if case .started = result {
                while isRunning, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func resumeInterruptedBackupIfNeeded(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        refreshHeadline(accountID: account.accountID)
        resumeBackgroundTransfersIfAllowed(account: account, assets: assets)
        guard !isRunning, !account.isLocalOnly,
              mappingRecoveryTasks[account.accountID] == nil else { return }
        let interruptedManualJob = jobs.contains {
            $0.accountID == account.accountID
                && ($0.status == .waiting || $0.status == .uploading || $0.status == .preparing)
                && $0.origin != .automatic
        }
        if interruptedManualJob {
            run(account: account, assets: assets, client: client, intent: .manual)
        } else {
            discoverAndAutomaticallyBackUp(assets: assets, account: account, client: client)
        }
    }

    func retryFailed(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        guard !isRunning, mappingRecoveryTasks[account.accountID] == nil else { return }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        var retryCount = 0
        for index in jobs.indices where
            jobs[index].accountID == account.accountID && jobs[index].status == .failed {
            guard let asset = assetsByID[jobs[index].localIdentifier] else { continue }
            if jobs[index].failure?.kind == .remoteDeleted ||
                !jobs[index].matchesCurrentLocalAsset(asset) {
                jobs[index].sourceModificationDate = asset.modificationDate
                jobs[index].lastKnownLocalModificationDate = asset.modificationDate
                jobs[index].uploadedBytes = 0
                jobs[index].totalBytes = 0
                jobs[index].resourceCount = 0
                jobs[index].assetID = nil
                jobs[index].pendingVerifiedRemoteAssetID = nil
                jobs[index].sourceState = nil
                jobs[index].derivativeState = nil
            }
            jobs[index].status = .waiting
            jobs[index].origin = .manual
            jobs[index].message = "等待重试"
            jobs[index].failure = nil
            jobs[index].updatedAt = Date()
            retryCount += 1
        }
        guard retryCount > 0 else {
            headline = "失败项目当前不在可访问的照片库中"
            return
        }
        headline = "仅重试 \(retryCount) 个失败项目"
        persist()
        run(account: account, assets: assets, client: client, intent: .manual)
    }

    private func updateAutomationPolicy(
        for account: AccountContext,
        change: (inout PhotoBackupAutomationPolicy) -> Void
    ) {
        guard !account.isLocalOnly else { return }
        let previousPolicy = automationPolicy(for: account)
        var policy = previousPolicy
        change(&policy)
        policy.updatedAt = Date()

        // Replace any stale policy with the same opaque account ID so it cannot
        // become eligible if a server/user pair is ever recreated differently.
        automationPolicies.removeAll { $0.accountID == account.accountID }
        automationPolicies.append(policy)
        persistAutomationPolicies()
        let hasTightenedNetworkPolicy = previousPolicy.networkPolicy == .anyNetwork
            && policy.networkPolicy == .wifiOnly
        let newlyPausesForLowPower = !previousPolicy.pausesInLowPowerMode
            && policy.pausesInLowPowerMode
            && automationConditions.snapshot.isLowPowerModeEnabled
        if !policy.isEnabled || hasTightenedNetworkPolicy || newlyPausesForLowPower {
            backgroundTransferEngine.pauseTransfers(
                for: account,
                reason: !policy.isEnabled
                    ? "用户已暂停此 MyNAS 账号的自动备份。"
                    : hasTightenedNetworkPolicy
                    ? "此账号已改为仅 Wi‑Fi 自动备份。"
                    : "低电量暂停策略已开启。"
            )
        }
        evaluateAutomaticBackup(for: account.accountID)
    }

    private func reevaluateAutomaticBackupRequests() {
        for accountID in automaticRequests.keys {
            evaluateAutomaticBackup(for: accountID)
        }
    }

    /// G1 follows the account the user is currently viewing. A switch removes
    /// stale automatic requests and makes any old automatic run stop before
    /// its next asset; it never cancels the in-flight PhotoKit export.
    private func selectAutomaticBackupAccount(_ account: AccountContext) {
        let nextAccountID = account.isLocalOnly ? nil : account.accountID
        guard activeAutomaticAccountID != nextAccountID else { return }
        let requestsToPause = automaticRequests.values.filter {
            $0.account.accountID != nextAccountID
        }
        activeAutomaticAccountID = nextAccountID
        for request in requestsToPause {
            backgroundTransferEngine.pauseTransfers(
                for: request.account,
                reason: "已切换到其他 MyNAS 账号，自动备份已暂停。"
            )
        }
        if let nextAccountID {
            automaticRequests = automaticRequests.filter { $0.key == nextAccountID }
        } else {
            automaticRequests.removeAll()
        }
        reevaluateAutomaticBackupRequests()
    }

    private func evaluateAutomaticBackup(for accountID: String) {
        guard let request = automaticRequests[accountID] else { return }

        if let pauseStatus = automaticPauseStatus(for: request.account) {
            if pauseStatus == .pausedForLowPower,
               request.account.serverCapabilities.supportsBackgroundTransfers {
                backgroundTransferEngine.pauseTransfers(
                    for: request.account,
                    reason: "iPhone 已进入低电量模式，自动备份策略要求暂停。"
                )
            }
            updateAutomationStatus(pauseStatus, for: accountID)
            return
        }

        if isRunning {
            let status: PhotoBackupAutomationStatus =
                activeRunAccountID == accountID && activeRunIntent == .automatic
                ? .uploading
                : .waitingForCurrentBackup
            updateAutomationStatus(status, for: accountID)
            return
        }

        if request.account.serverCapabilities.supportsBackgroundTransfers,
           backgroundTransferEngine.hasActiveTransfer(for: request.account) {
            updateAutomationStatus(.backgroundTransferActive, for: accountID)
            return
        }

        let pending = pendingCount(for: request.assets, accountID: accountID)
        guard pending > 0 else {
            updateAutomationStatus(.watchingForeground, for: accountID)
            return
        }

        updateAutomationStatus(.discovering, for: accountID)
        enqueue(
            assets: request.assets,
            accountID: accountID,
            retryFailed: false,
            origin: .automatic
        )
        let hasAutomaticWork = jobs.contains {
            $0.accountID == accountID && $0.status == .waiting && $0.origin == .automatic
        }
        guard hasAutomaticWork else {
            updateAutomationStatus(.watchingForeground, for: accountID)
            return
        }
        run(
            account: request.account,
            assets: request.assets,
            client: request.client,
            intent: .automatic
        )
    }

    /// A condition failure stops an automatic run before its next asset. The
    /// in-flight PhotoKit export is allowed to finish its current safe request;
    /// G1 never cancels a user-started manual upload because power changed.
    private func automaticPauseStatus(for account: AccountContext) -> PhotoBackupAutomationStatus? {
        PhotoBackupAutomaticEligibility.pauseStatus(
            policy: automationPolicy(for: account),
            account: account,
            isAppInForeground: isAppInForeground,
            isSelectedAccount: activeAutomaticAccountID == account.accountID,
            requiresDeviceMappingRecovery: deviceMappingRecoveryIsRequired(for: account),
            isMappingRecoveryInProgress: mappingRecoveryTasks[account.accountID] != nil,
            hasRecoveredMappings: recoveredMappingsByAccountID[account.accountID] != nil,
            conditions: automationConditions.snapshot
        )
    }

    private func updateAutomationStatus(
        _ status: PhotoBackupAutomationStatus,
        for accountID: String
    ) {
        guard automationStatuses[accountID] != status else { return }
        automationStatuses[accountID] = status
    }

    private func shouldRecoverDeviceMappings(for account: AccountContext) -> Bool {
        deviceMappingRecoveryIsRequired(for: account) &&
            recoveredMappingsByAccountID[account.accountID] == nil &&
            mappingRecoveryTasks[account.accountID] == nil
    }

    private func deviceMappingRecoveryIsRequired(for account: AccountContext) -> Bool {
        account.serverCapabilities.supportsDeviceAssetMappingRecovery != false
    }

    private func recoverDeviceMappingsIfNeeded(for account: AccountContext) {
        guard mappingRecoveryTasks[account.accountID] == nil else { return }

        let accountID = account.accountID
        let client = mappingClient
        let currentDeviceID = deviceID
        mappingRecoveryTasks[accountID] = Task { [weak self, account, client, currentDeviceID] in
            do {
                let mappings = try await client.fetchDeviceAssetMappings(
                    account: account,
                    deviceID: currentDeviceID
                )
                guard !Task.isCancelled, let self else { return }
                self.finishDeviceMappingRecovery(
                    mappings,
                    for: accountID
                )
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.failDeviceMappingRecovery(for: accountID)
            }
        }
    }

    private func finishDeviceMappingRecovery(
        _ mappings: [ServerDeviceAssetMapping],
        for accountID: String
    ) {
        mappingRecoveryTasks[accountID] = nil
        recoveredMappingsByAccountID[accountID] = mappings

        if let request = mappingRecoveryRequests[accountID] {
            let recoveredCount = restoreDeviceMappings(
                for: request.assets,
                account: request.account
            )
            if recoveredCount > 0 {
                headline = "已从 MyNAS 验证记录恢复 \(recoveredCount) 项备份状态"
            }
        }
        startPendingVerifiedAssociationRunIfPossible(preferredAccountID: accountID)
        evaluateAutomaticBackup(for: accountID)
    }

    /// A failed fetch is not equivalent to an empty verified mapping list.
    /// Keep the recovery unset so G1 stays paused until a later foreground
    /// reconciliation succeeds. Manual backup remains an explicit choice.
    private func failDeviceMappingRecovery(for accountID: String) {
        mappingRecoveryTasks[accountID] = nil
        recoveredMappingsByAccountID[accountID] = nil
        startPendingVerifiedAssociationRunIfPossible(preferredAccountID: accountID)
        evaluateAutomaticBackup(for: accountID)
    }

    /// Marks an item completed only when MyNAS's mapping is for this device,
    /// has a committed source, and its stored source-version string exactly
    /// matches the current PhotoKit modification date. A date/name/thumbnail
    /// coincidence can never reach this code path.
    private func restoreDeviceMappings(
        for assets: [LocalPhotoAsset],
        account: AccountContext
    ) -> Int {
        guard let mappings = recoveredMappingsByAccountID[account.accountID],
              !mappings.isEmpty else {
            return 0
        }
        let assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) }
        )
        var restoredCount = 0
        var didChange = false

        for mapping in mappings {
            guard let asset = assetsByIdentifier[mapping.localIdentifier],
                  mapping.sourceState == PhotoSourceState.committed.rawValue,
                  PhotoBackupSourceVersion.matches(
                    serverValue: mapping.sourceModificationDate,
                    localDate: asset.modificationDate
                  ) else {
                continue
            }
            let derivativeState = PhotoDerivativeState(rawValue: mapping.derivativeState) ?? .pending
            if let index = jobs.firstIndex(where: {
                $0.accountID == account.accountID &&
                    $0.localIdentifier == mapping.localIdentifier
            }) {
                if let expectedRemoteAssetID = jobs[index].pendingVerifiedRemoteAssetID,
                   expectedRemoteAssetID != mapping.assetID {
                    continue
                }
                let jobIsAlreadyRecovered = jobs[index].status == .completed &&
                    jobs[index].sourceModificationDate == asset.modificationDate &&
                    jobs[index].assetID == mapping.assetID &&
                    jobs[index].sourceState == .committed &&
                    jobs[index].derivativeState == derivativeState &&
                    jobs[index].resourceCount == mapping.resourceCount &&
                    jobs[index].totalBytes == max(0, mapping.sourceBytes)
                guard !jobIsAlreadyRecovered else { continue }

                jobs[index].sourceModificationDate = asset.modificationDate
                jobs[index].lastKnownLocalModificationDate = asset.modificationDate
                jobs[index].status = .completed
                jobs[index].totalBytes = max(0, mapping.sourceBytes)
                jobs[index].uploadedBytes = max(0, mapping.sourceBytes)
                jobs[index].resourceCount = max(0, mapping.resourceCount)
                jobs[index].assetID = mapping.assetID
                jobs[index].pendingVerifiedRemoteAssetID = nil
                jobs[index].sourceState = .committed
                jobs[index].derivativeState = derivativeState
                jobs[index].message = "已从 MyNAS 验证记录恢复"
                jobs[index].failure = nil
                jobs[index].updatedAt = Date()
            } else {
                jobs.append(
                    PhotoBackupJob(
                        id: UUID(),
                        accountID: account.accountID,
                        localIdentifier: asset.localIdentifier,
                        mediaKind: asset.mediaKind,
                        creationDate: asset.creationDate,
                        sourceModificationDate: asset.modificationDate,
                        lastKnownLocalModificationDate: asset.modificationDate,
                        status: .completed,
                        totalBytes: max(0, mapping.sourceBytes),
                        uploadedBytes: max(0, mapping.sourceBytes),
                        resourceCount: max(0, mapping.resourceCount),
                        assetID: mapping.assetID,
                        sourceState: .committed,
                        derivativeState: derivativeState,
                        origin: nil,
                        message: "已从 MyNAS 验证记录恢复",
                        failure: nil,
                        updatedAt: Date()
                    )
                )
            }
            restoredCount += 1
            didChange = true
        }

        if didChange {
            persist()
        }
        return restoredCount
    }

    private func enqueue(
        assets: [LocalPhotoAsset],
        accountID: String,
        retryFailed: Bool,
        origin: PhotoBackupJobOrigin
    ) {
        var queuedCount = 0
        var changed = false
        for asset in assets {
            if let index = jobs.firstIndex(where: {
                $0.accountID == accountID && $0.localIdentifier == asset.localIdentifier
            }) {
                let sourceChanged = !jobs[index].matchesCurrentLocalAsset(asset)
                if jobs[index].status == .completed, !sourceChanged {
                    continue
                }
                if !sourceChanged {
                    if jobs[index].status == .failed, retryFailed {
                        jobs[index].status = .waiting
                        jobs[index].message = "等待重试"
                        jobs[index].failure = nil
                        jobs[index].updatedAt = Date()
                        queuedCount += 1
                        changed = true
                    }
                    continue
                }
                jobs[index].sourceModificationDate = asset.modificationDate
                jobs[index].lastKnownLocalModificationDate = asset.modificationDate
                jobs[index].status = .waiting
                jobs[index].uploadedBytes = 0
                jobs[index].totalBytes = 0
                jobs[index].resourceCount = 0
                jobs[index].assetID = nil
                jobs[index].pendingVerifiedRemoteAssetID = nil
                jobs[index].sourceState = nil
                jobs[index].derivativeState = nil
                jobs[index].origin = origin
                jobs[index].message = sourceChanged ? "源文件已变化，准备重新备份" : "等待上传"
                jobs[index].failure = nil
                jobs[index].updatedAt = Date()
                queuedCount += 1
                changed = true
            } else {
                jobs.append(
                    PhotoBackupJob(
                        id: UUID(),
                        accountID: accountID,
                        localIdentifier: asset.localIdentifier,
                        mediaKind: asset.mediaKind,
                        creationDate: asset.creationDate,
                        sourceModificationDate: asset.modificationDate,
                        lastKnownLocalModificationDate: asset.modificationDate,
                        status: .waiting,
                        totalBytes: 0,
                        uploadedBytes: 0,
                        resourceCount: 0,
                        assetID: nil,
                        sourceState: nil,
                        derivativeState: nil,
                        origin: origin,
                        message: "等待上传",
                        failure: nil,
                        updatedAt: Date()
                    )
                )
                queuedCount += 1
                changed = true
            }
        }
        if queuedCount > 0 {
            headline = queuedCount == 1
                ? "发现 1 个新项目，等待备份"
                : "发现 \(queuedCount) 个新项目，等待备份"
        }
        if changed {
            persist()
        }
    }

    /// Unlike the regular queueing path, this intentionally re-submits an
    /// already completed local asset after the user has compared all source
    /// resource hashes with a particular remote item. The upload session is
    /// still server-authoritative and normally resolves as a duplicate, which
    /// creates the missing current-device mapping without trusting a date or
    /// thumbnail coincidence.
    private func enqueueVerifiedLocalAssociation(
        _ asset: LocalPhotoAsset,
        expectedRemoteAssetID: String,
        accountID: String
    ) {
        if let index = jobs.firstIndex(where: {
            $0.accountID == accountID && $0.localIdentifier == asset.localIdentifier
        }) {
            jobs[index].sourceModificationDate = asset.modificationDate
            jobs[index].lastKnownLocalModificationDate = asset.modificationDate
            jobs[index].status = .waiting
            jobs[index].uploadedBytes = 0
            jobs[index].totalBytes = 0
            jobs[index].resourceCount = 0
            jobs[index].assetID = nil
            jobs[index].pendingVerifiedRemoteAssetID = expectedRemoteAssetID
            jobs[index].sourceState = nil
            jobs[index].derivativeState = nil
            jobs[index].origin = .manual
            jobs[index].message = "已核验同一原件，等待登记当前 iPhone"
            jobs[index].failure = nil
            jobs[index].updatedAt = Date()
        } else {
            jobs.append(
                PhotoBackupJob(
                    id: UUID(),
                    accountID: accountID,
                    localIdentifier: asset.localIdentifier,
                    mediaKind: asset.mediaKind,
                    creationDate: asset.creationDate,
                    sourceModificationDate: asset.modificationDate,
                    lastKnownLocalModificationDate: asset.modificationDate,
                    status: .waiting,
                    totalBytes: 0,
                    uploadedBytes: 0,
                    resourceCount: 0,
                    assetID: nil,
                    pendingVerifiedRemoteAssetID: expectedRemoteAssetID,
                    sourceState: nil,
                    derivativeState: nil,
                    origin: .manual,
                    message: "已核验同一原件，等待登记当前 iPhone",
                    failure: nil,
                    updatedAt: Date()
                )
            )
        }
        headline = "正在登记已核验的本机原件"
        persist()
    }

    private func mergePendingVerifiedAssociationRun(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        let existingAssets = pendingVerifiedAssociationRuns[account.accountID]?.assets ?? []
        let merged = Dictionary(
            (existingAssets + assets).map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        pendingVerifiedAssociationRuns[account.accountID] = VerifiedAssociationRunRequest(
            assets: Array(merged.values),
            account: account,
            client: client
        )
    }

    @discardableResult
    private func startPendingVerifiedAssociationRunIfPossible(
        preferredAccountID: String? = nil
    ) -> Bool {
        guard !isRunning else { return false }
        let accountIDs = pendingVerifiedAssociationRuns.keys.sorted { left, right in
            if left == preferredAccountID { return true }
            if right == preferredAccountID { return false }
            return left < right
        }
        for accountID in accountIDs {
            guard mappingRecoveryTasks[accountID] == nil,
                  let request = pendingVerifiedAssociationRuns.removeValue(forKey: accountID) else {
                continue
            }
            let runnableAssets = request.assets.filter { asset in
                jobs.contains { job in
                    job.accountID == accountID
                        && job.localIdentifier == asset.localIdentifier
                        && job.status == .waiting
                        && job.origin != .automatic
                        && job.pendingVerifiedRemoteAssetID?.isEmpty == false
                        && job.matchesCurrentLocalAsset(asset)
                }
            }
            guard !runnableAssets.isEmpty else { continue }
            run(
                account: request.account,
                assets: runnableAssets,
                client: request.client,
                intent: .manual
            )
            return true
        }
        return false
    }

    private func run(
        account: AccountContext,
        assets: [LocalPhotoAsset],
        client: PhotoLibraryClient,
        intent: BackupRunIntent
    ) {
        guard !isRunning else { return }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        headline = "正在备份"
        if intent == .automatic {
            updateAutomationStatus(.uploading, for: account.accountID)
        }
        isRunning = true
        activeRunAccountID = account.accountID
        activeRunIntent = intent
        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.runTask = nil
                self.activeRunAccountID = nil
                self.activeRunIntent = nil
                self.refreshHeadline(accountID: account.accountID)
                self.startPendingVerifiedAssociationRunIfPossible(
                    preferredAccountID: account.accountID
                )
                self.reevaluateAutomaticBackupRequests()
            }

            let jobIDs = self.jobs.filter {
                $0.accountID == account.accountID
                    && $0.status == .waiting
                    && assetsByID[$0.localIdentifier] != nil
                    && (intent == .manual || $0.origin == .automatic)
            }.map(\.id)

            for jobID in jobIDs {
                if intent == .automatic,
                   self.automaticPauseStatus(for: account) != nil {
                    self.evaluateAutomaticBackup(for: account.accountID)
                    break
                }
                guard !Task.isCancelled,
                      let jobIndex = self.jobs.firstIndex(where: { $0.id == jobID }),
                      let asset = assetsByID[self.jobs[jobIndex].localIdentifier] else {
                    continue
                }
                await self.process(
                    jobID: jobID,
                    asset: asset,
                    account: account,
                    client: client
                )
            }
        }
    }

    private func process(
        jobID: UUID,
        asset: LocalPhotoAsset,
        account: AccountContext,
        client: PhotoLibraryClient
    ) async {
        update(jobID) {
            $0.status = .preparing
            $0.failure = nil
            $0.message = asset.mediaKind == .livePhoto
                ? "读取静态原图、配对视频与编辑资源"
                : "读取 PhotoKit 原始资源"
        }

        var preparedAsset: PreparedPhotoAsset?
        do {
            let prepared = try await client.prepareBackupAsset(asset)
            preparedAsset = prepared
            update(jobID) {
                $0.status = .uploading
                $0.totalBytes = prepared.totalBytes
                $0.uploadedBytes = 0
                $0.resourceCount = prepared.resources.count
                $0.message = "正在上传 \(prepared.resources.count) 个原始资源"
            }

            if jobs.first(where: { $0.id == jobID })?.origin == .automatic,
               account.serverCapabilities.supportsBackgroundTransfers {
                let record = try await backgroundTransferEngine.beginAutomaticTransfer(
                    preparedAsset: prepared,
                    account: account,
                    policy: automationPolicy(for: account),
                    deviceID: deviceID
                )
                update(jobID) {
                    $0.status = .uploading
                    $0.uploadedBytes = record.resources.reduce(0) { $0 + $1.receivedBytes }
                    $0.message = "已交给 iOS 系统传输；MyNAS 确认后会更新完成状态"
                }
                preparedAsset?.removeTemporaryFiles()
                return
            }

            let outcome = try await uploadWithConnectionRecovery(
                preparedAsset: prepared,
                account: account,
                jobID: jobID
            )
            if let expectedRemoteAssetID = jobs.first(where: { $0.id == jobID })?.pendingVerifiedRemoteAssetID,
               outcome.assetID != expectedRemoteAssetID {
                throw PhotoBackupVerifiedAssociationError.unexpectedRemoteAsset(
                    expected: expectedRemoteAssetID,
                    received: outcome.assetID
                )
            }
            update(jobID) {
                $0.status = .completed
                $0.uploadedBytes = $0.totalBytes
                $0.assetID = outcome.assetID
                $0.pendingVerifiedRemoteAssetID = nil
                $0.sourceState = outcome.sourceState
                $0.derivativeState = outcome.derivativeState
                $0.failure = nil
                if outcome.browseReady {
                    $0.message = "原件和浏览预览均已就绪"
                } else if outcome.wasDuplicate {
                    $0.message = "MyNAS 已存在相同原件；浏览预览等待生成"
                } else {
                    $0.message = "原始资源已完整校验；浏览预览等待生成"
                }
            }
        } catch is CancellationError {
            update(jobID) {
                $0.status = .waiting
                $0.failure = nil
                $0.message = "备份已暂停，将在下次打开时继续"
            }
        } catch PhotoBackupBackgroundTransferEngineError.pausedForLowPower {
            // A Low Power change may arrive while PhotoKit is exporting. G2
            // rejects the hand-off before staging; keep this automatic job
            // waiting so the normal policy observer can resume it later.
            update(jobID) {
                $0.status = .waiting
                $0.failure = nil
                $0.message = "低电量模式已暂停，等待恢复自动备份"
            }
        } catch {
            let failure = Self.failure(from: error)
            update(jobID) {
                $0.status = .failed
                $0.message = failure.kind.title
                $0.failure = failure
            }
        }
        preparedAsset?.removeTemporaryFiles()
    }

    private func resumeBackgroundTransfersIfAllowed(
        account: AccountContext,
        assets: [LocalPhotoAsset]
    ) {
        guard account.serverCapabilities.supportsBackgroundTransfers,
              let policy = automationPolicies.first(where: {
                  $0.applies(to: account) && $0.isEnabled
              }) else {
            return
        }
        let engine = backgroundTransferEngine
        Task { @MainActor [weak self, account, assets, policy, engine] in
            await engine.continueTransfers(for: account, policy: policy)
            self?.reconcileCompletedBackgroundTransfers(account: account, assets: assets)
        }
    }

    private func reconcileCompletedBackgroundTransfers(
        account: AccountContext,
        assets: [LocalPhotoAsset]
    ) {
        let assetsByIdentifier = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.localIdentifier, $0)
        })
        var changed = false
        var recordsToDiscard: [PhotoBackupBackgroundTransferRecord] = []
        for record in backgroundTransferEngine.completedTransfers(for: account) {
            guard let outcome = record.outcome,
                  let asset = assetsByIdentifier[record.localIdentifier],
                  let jobIndex = jobs.firstIndex(where: {
                      $0.accountID == account.accountID
                          && $0.localIdentifier == record.localIdentifier
                          && $0.sourceModificationDate == record.sourceModificationDate
                  }),
                  jobs[jobIndex].matchesCurrentLocalAsset(asset) else {
                continue
            }
            jobs[jobIndex].status = .completed
            if let expectedRemoteAssetID = jobs[jobIndex].pendingVerifiedRemoteAssetID,
               outcome.assetID != expectedRemoteAssetID {
                let failure = PhotoBackupFailure(
                    kind: .integrity,
                    detail: PhotoBackupVerifiedAssociationError.unexpectedRemoteAsset(
                        expected: expectedRemoteAssetID,
                        received: outcome.assetID
                    ).localizedDescription,
                    occurredAt: Date()
                )
                jobs[jobIndex].status = .failed
                jobs[jobIndex].failure = failure
                jobs[jobIndex].message = failure.kind.title
                jobs[jobIndex].updatedAt = Date()
                changed = true
                recordsToDiscard.append(record)
                continue
            }
            jobs[jobIndex].uploadedBytes = jobs[jobIndex].totalBytes
            jobs[jobIndex].assetID = outcome.assetID
            jobs[jobIndex].pendingVerifiedRemoteAssetID = nil
            jobs[jobIndex].sourceState = outcome.sourceState
            jobs[jobIndex].derivativeState = outcome.derivativeState
            jobs[jobIndex].failure = nil
            jobs[jobIndex].message = outcome.browseReady
                ? "原件和浏览预览均已就绪"
                : outcome.wasDuplicate
                ? "MyNAS 已存在相同原件；浏览预览等待生成"
                : "原始资源已完整校验；浏览预览等待生成"
            jobs[jobIndex].updatedAt = Date()
            changed = true
            recordsToDiscard.append(record)
        }
        if changed, persist() {
            recordsToDiscard.forEach {
                backgroundTransferEngine.discardCompletedTransfer($0, for: account)
            }
            refreshHeadline(accountID: account.accountID)
        } else if changed {
            refreshHeadline(accountID: account.accountID)
        }
    }

    /// A URLSession callback writes the durable G2 journal, not this
    /// coordinator's published queue. Reconcile active foreground requests as
    /// soon as that journal changes, so the card does not require navigation
    /// away and back before it reflects a paused or completed system transfer.
    private func reconcileBackgroundTransferJournalChanges() {
        for request in automaticRequests.values {
            reconcileInFlightBackgroundTransferProgress(
                account: request.account,
                assets: request.assets
            )
            reconcileCompletedBackgroundTransfers(
                account: request.account,
                assets: request.assets
            )
            evaluateAutomaticBackup(for: request.account.accountID)
        }
    }

    /// Keeps iOS's current task counter out of the persisted queue. On a
    /// relaunch the overlay disappears and the UI falls back to MyNAS's
    /// journal-confirmed offsets until the next callback arrives.
    private func reconcileInFlightBackgroundTransferProgress(
        account: AccountContext,
        assets: [LocalPhotoAsset]
    ) {
        let assetsByIdentifier = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.localIdentifier, $0)
        })
        let next: [UUID: PhotoBackupBackgroundTransferProgress] = Dictionary(
            backgroundTransferEngine.activeTransferProgress(for: account).compactMap { progress in
                guard let asset = assetsByIdentifier[progress.localIdentifier],
                      jobs.contains(where: { job in
                          job.accountID == account.accountID
                              && job.localIdentifier == progress.localIdentifier
                              && job.sourceModificationDate == progress.sourceModificationDate
                              && job.matchesCurrentLocalAsset(asset)
                      }) else {
                    return nil
                }
                return (progress.recordID, progress)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let oldIDs = backgroundTransferProgress.compactMap { id, progress in
            progress.accountID == account.accountID ? id : nil
        }
        var merged = backgroundTransferProgress
        oldIDs.forEach { merged.removeValue(forKey: $0) }
        merged.merge(next) { _, latest in latest }
        if merged != backgroundTransferProgress {
            backgroundTransferProgress = merged
        }
    }

    private func uploadWithConnectionRecovery(
        preparedAsset: PreparedPhotoAsset,
        account: AccountContext,
        jobID: UUID
    ) async throws -> PhotoBackupUploadOutcome {
        var lastError: Error?
        for cycle in 0..<3 {
            let coordinator = self
            let isRecovery = cycle > 0
            do {
                return try await uploader.upload(
                    preparedAsset: preparedAsset,
                    account: account,
                    deviceID: deviceID
                ) { uploaded, total in
                    Task { @MainActor [coordinator] in
                        coordinator.update(jobID) {
                            $0.status = .uploading
                            $0.uploadedBytes = uploaded
                            $0.totalBytes = total
                            $0.message = isRecovery ? "网络恢复后继续上传" : "上传中"
                        }
                    }
                }
            } catch let error where PhotoBackupUploader.isTransient(error) {
                lastError = error
                update(jobID) {
                    $0.status = .waiting
                    $0.message = "网络中断，\(5 * (cycle + 1)) 秒后自动续传"
                }
                try await Task.sleep(for: .seconds(5 * (cycle + 1)))
            }
        }
        throw lastError ?? URLError(.networkConnectionLost)
    }

    private func update(_ jobID: UUID, change: (inout PhotoBackupJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
        jobs[index].updatedAt = Date()
        persist()
    }

    private func normalizeInterruptedJobs() {
        var changed = false
        for index in jobs.indices {
            if jobs[index].status == .preparing || jobs[index].status == .uploading {
                jobs[index].status = .waiting
                jobs[index].message = "等待从 MyNAS 已接收的位置继续"
                jobs[index].failure = nil
                changed = true
            } else if jobs[index].status == .failed, jobs[index].failure == nil {
                jobs[index].failure = PhotoBackupFailure(
                    kind: .unknown,
                    detail: jobs[index].message ?? "旧版本未保存具体错误信息。",
                    occurredAt: jobs[index].updatedAt
                )
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    private func refreshHeadline(accountID: String) {
        let accountJobs = jobs.filter { $0.accountID == accountID }
        let completed = accountJobs.filter { $0.status == .completed }.count
        let failed = accountJobs.filter { $0.status == .failed }.count
        if failed > 0 {
            headline = "原件已上传 \(completed) 项，\(failed) 项需要重试"
        } else if !accountJobs.isEmpty {
            headline = "原件已上传 \(completed) / \(accountJobs.count) 项"
        } else {
            headline = "尚未开始备份"
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try persistence.save(jobs)
            return true
        } catch {
            return false
        }
    }

    private func persistAutomationPolicies() {
        try? automationPersistence.save(automationPolicies)
    }

    private static func persistentDeviceID(userDefaults: UserDefaults) -> String {
        PhotoBackupDeviceIdentity.currentID(userDefaults: userDefaults)
    }

    private static func failure(from error: Error) -> PhotoBackupFailure {
        let detail = error.localizedDescription
        let kind: PhotoBackupFailureKind

        if error is URLError {
            kind = .network
        } else if error is PhotoBackupVerifiedAssociationError {
            kind = .integrity
        } else if let preparationError = error as? PhotoBackupPreparationError {
            switch preparationError {
            case .assetUnavailable, .noResources:
                kind = .sourceUnavailable
            case .invalidResource:
                kind = .integrity
            }
        } else if let uploadError = error as? PhotoBackupUploadError {
            switch uploadError {
            case .accountNotConnected, .volumeNotSelected:
                kind = .configuration
            case .invalidResponse:
                kind = .server
            case .server(let status, let message):
                let normalized = message.lowercased()
                if status == 401 || status == 403 {
                    kind = .authorization
                } else if normalized.contains("insufficient space")
                    || normalized.contains("selected volume is offline")
                    || normalized.contains("selected volume is offline or unavailable") {
                    kind = .myNASStorage
                } else if status == 422
                    || normalized.contains("checksum")
                    || normalized.contains("fingerprint")
                    || normalized.contains("size mismatch")
                    || normalized.contains("not all resources") {
                    kind = .integrity
                } else {
                    kind = .server
                }
            }
        } else {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                kind = .localStorage
            } else if cocoaError.domain == NSCocoaErrorDomain,
                      cocoaError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
                        || cocoaError.code == CocoaError.Code.fileReadNoPermission.rawValue {
                kind = .sourceUnavailable
            } else if cocoaError.domain == "PHPhotosErrorDomain" {
                kind = .sourceUnavailable
            } else if cocoaError.domain == NSURLErrorDomain {
                kind = .network
            } else {
                kind = .unknown
            }
        }

        return PhotoBackupFailure(kind: kind, detail: detail, occurredAt: Date())
    }
}

/// `UserDefaults` is removed when an app is uninstalled, while the Keychain
/// survives an ordinary reinstall. Persisting this opaque per-device ID there
/// lets MyNAS return only this iPhone's mappings without using a hardware ID.
nonisolated enum PhotoBackupDeviceIdentity {
    static func currentID(userDefaults: UserDefaults = .standard) -> String {
        PhotoBackupDeviceIdentityStore.loadOrCreate(userDefaults: userDefaults)
    }
}

private nonisolated enum PhotoBackupDeviceIdentityStore {
    private static let service = "com.ethanzhou.MyPhotos.photoBackup"
    private static let account = "device-id"
    private static let legacyDefaultsKey = "photoBackupDeviceID"

    static func loadOrCreate(userDefaults: UserDefaults) -> String {
        if let existing = loadFromKeychain() {
            userDefaults.set(existing, forKey: legacyDefaultsKey)
            return existing
        }

        if let legacy = userDefaults.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            _ = saveToKeychain(legacy)
            return legacy
        }

        let value = "ios-" + UUID().uuidString.lowercased()
        _ = saveToKeychain(value)
        userDefaults.set(value, forKey: legacyDefaultsKey)
        return value
    }

    private static func loadFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func saveToKeychain(_ value: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let data = Data(value.utf8)
        let update: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

nonisolated struct PhotoBackupPersistenceStore {
    private let fileManager: FileManager
    private let explicitURL: URL?

    init(fileManager: FileManager = .default, explicitURL: URL? = nil) {
        self.fileManager = fileManager
        self.explicitURL = explicitURL
    }

    func load() throws -> [PhotoBackupJob] {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PhotoBackupJob].self, from: Data(contentsOf: url))
    }

    func save(_ jobs: [PhotoBackupJob]) throws {
        let url = try storageURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(jobs)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func storageURL() throws -> URL {
        if let explicitURL {
            return explicitURL
        }
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
            .appendingPathComponent("BackupQueue", isDirectory: true)
            .appendingPathComponent("jobs.json", isDirectory: false)
    }
}
