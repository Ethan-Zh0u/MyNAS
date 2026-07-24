import Foundation
import Combine

@MainActor
final class PhotoBackupCoordinator: ObservableObject {
    @Published private(set) var jobs: [PhotoBackupJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var headline = "尚未开始备份"

    private let uploader: PhotoBackupUploader
    private let persistence: PhotoBackupPersistenceStore
    private let deviceID: String
    private var runTask: Task<Void, Never>?
    private var automaticBackupRequests: [String: AutomaticBackupRequest] = [:]

    private struct AutomaticBackupRequest {
        let assets: [LocalPhotoAsset]
        let account: AccountContext
        let client: PhotoLibraryClient
    }

    init(
        uploader: PhotoBackupUploader = PhotoBackupUploader(),
        persistence: PhotoBackupPersistenceStore = PhotoBackupPersistenceStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.uploader = uploader
        self.persistence = persistence
        self.deviceID = Self.persistentDeviceID(userDefaults: userDefaults)
        self.jobs = (try? persistence.load()) ?? []
        normalizeInterruptedJobs()
    }

    deinit {
        runTask?.cancel()
    }

    func jobs(for accountID: String) -> [PhotoBackupJob] {
        jobs
            .filter { $0.accountID == accountID }
            .sorted { $0.updatedAt > $1.updatedAt }
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
                  job.sourceModificationDate == asset.modificationDate else {
                return nil
            }
            return job
        }
        let uploadedBytes = currentJobs.reduce(Int64(0)) {
            $0 + max(0, min($1.uploadedBytes, $1.totalBytes))
        }
        let totalBytes = currentJobs.reduce(Int64(0)) {
            $0 + max(0, $1.totalBytes)
        }
        let sizePendingCount = assets.count - currentJobs.filter { $0.totalBytes > 0 }.count
        return PhotoBackupProgressSnapshot(
            completedCount: currentJobs.filter { $0.status == .completed }.count,
            failedCount: currentJobs.filter { $0.status == .failed }.count,
            totalCount: assets.count,
            isRunning: isRunning && accountJobs.contains {
                $0.status == .preparing || $0.status == .uploading || $0.status == .waiting
            },
            uploadedBytes: uploadedBytes,
            totalBytes: totalBytes,
            sizePendingCount: sizePendingCount
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
                  job.sourceModificationDate == asset.modificationDate else {
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

    func synchronizeLibrary(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        guard !account.isLocalOnly else { return }
        automaticBackupRequests[account.accountID] = AutomaticBackupRequest(
            assets: assets,
            account: account,
            client: client
        )
        enqueue(
            assets: assets,
            accountID: account.accountID,
            retryFailed: false
        )
        startAutomaticBackupIfNeeded(accountID: account.accountID)
    }

    func startManualBackup(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        guard !isRunning else { return }
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
            retryFailed: true
        )
        run(account: account, assets: assets, client: client)
    }

    func resumeInterruptedBackupIfNeeded(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        refreshHeadline(accountID: account.accountID)
        guard !isRunning, !account.isLocalOnly else { return }
        let interrupted = jobs.contains {
            $0.accountID == account.accountID && ($0.status == .waiting || $0.status == .uploading || $0.status == .preparing)
        }
        guard interrupted else { return }
        run(account: account, assets: assets, client: client)
    }

    func retryFailed(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
        guard !isRunning else { return }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        var retryCount = 0
        for index in jobs.indices where
            jobs[index].accountID == account.accountID && jobs[index].status == .failed {
            guard let asset = assetsByID[jobs[index].localIdentifier] else { continue }
            if jobs[index].sourceModificationDate != asset.modificationDate {
                jobs[index].sourceModificationDate = asset.modificationDate
                jobs[index].uploadedBytes = 0
                jobs[index].totalBytes = 0
                jobs[index].resourceCount = 0
                jobs[index].assetID = nil
                jobs[index].sourceState = nil
                jobs[index].derivativeState = nil
            }
            jobs[index].status = .waiting
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
        run(account: account, assets: assets, client: client)
    }

    private func enqueue(
        assets: [LocalPhotoAsset],
        accountID: String,
        retryFailed: Bool
    ) {
        var queuedCount = 0
        var changed = false
        for asset in assets {
            if let index = jobs.firstIndex(where: {
                $0.accountID == accountID && $0.localIdentifier == asset.localIdentifier
            }) {
                let sourceChanged = jobs[index].sourceModificationDate != asset.modificationDate
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
                jobs[index].status = .waiting
                jobs[index].uploadedBytes = 0
                jobs[index].totalBytes = 0
                jobs[index].resourceCount = 0
                jobs[index].assetID = nil
                jobs[index].sourceState = nil
                jobs[index].derivativeState = nil
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
                        status: .waiting,
                        totalBytes: 0,
                        uploadedBytes: 0,
                        resourceCount: 0,
                        assetID: nil,
                        sourceState: nil,
                        derivativeState: nil,
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

    private func run(
        account: AccountContext,
        assets: [LocalPhotoAsset],
        client: PhotoLibraryClient
    ) {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        headline = "正在备份"
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.runTask = nil
                self.refreshHeadline(accountID: account.accountID)
                self.startAutomaticBackupIfNeeded(accountID: account.accountID)
            }

            let jobIDs = self.jobs.filter {
                $0.accountID == account.accountID
                    && $0.status == .waiting
                    && assetsByID[$0.localIdentifier] != nil
            }.map(\.id)

            for jobID in jobIDs {
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

    private func startAutomaticBackupIfNeeded(accountID: String) {
        guard !isRunning,
              let request = automaticBackupRequests[accountID],
              !request.account.isLocalOnly,
              request.account.selectedVolumeID != nil else {
            return
        }
        let availableIdentifiers = Set(request.assets.map(\.localIdentifier))
        let hasWaitingJob = jobs.contains {
            $0.accountID == accountID
                && $0.status == .waiting
                && availableIdentifiers.contains($0.localIdentifier)
        }
        guard hasWaitingJob else { return }
        run(
            account: request.account,
            assets: request.assets,
            client: request.client
        )
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

            let outcome = try await uploadWithConnectionRecovery(
                preparedAsset: prepared,
                account: account,
                jobID: jobID
            )
            update(jobID) {
                $0.status = .completed
                $0.uploadedBytes = $0.totalBytes
                $0.assetID = outcome.assetID
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

    private func persist() {
        try? persistence.save(jobs)
    }

    private static func persistentDeviceID(userDefaults: UserDefaults) -> String {
        let key = "photoBackupDeviceID"
        if let existing = userDefaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = "ios-" + UUID().uuidString.lowercased()
        userDefaults.set(value, forKey: key)
        return value
    }

    private static func failure(from error: Error) -> PhotoBackupFailure {
        let detail = error.localizedDescription
        let kind: PhotoBackupFailureKind

        if error is URLError {
            kind = .network
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
