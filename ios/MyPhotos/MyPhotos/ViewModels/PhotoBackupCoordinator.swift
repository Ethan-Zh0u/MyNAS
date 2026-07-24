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
        fallbackTotalCount: Int = 0
    ) -> PhotoBackupProgressSnapshot {
        let accountJobs = jobs.filter { $0.accountID == accountID }
        let totalCount = accountJobs.isEmpty ? fallbackTotalCount : accountJobs.count
        let uploadedBytes = accountJobs.reduce(Int64(0)) {
            $0 + max(0, min($1.uploadedBytes, $1.totalBytes))
        }
        let totalBytes = accountJobs.reduce(Int64(0)) {
            $0 + max(0, $1.totalBytes)
        }
        let sizePendingCount = accountJobs.isEmpty
            ? fallbackTotalCount
            : accountJobs.filter { $0.totalBytes <= 0 }.count
        return PhotoBackupProgressSnapshot(
            completedCount: accountJobs.filter { $0.status == .completed }.count,
            totalCount: totalCount,
            isRunning: isRunning && accountJobs.contains {
                $0.status == .preparing || $0.status == .uploading || $0.status == .waiting
            },
            uploadedBytes: uploadedBytes,
            totalBytes: totalBytes,
            sizePendingCount: sizePendingCount
        )
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
        enqueue(assets: assets, accountID: account.accountID)
        run(account: account, assets: assets, client: client)
    }

    func resumeInterruptedBackupIfNeeded(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        client: PhotoLibraryClient
    ) {
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
        for index in jobs.indices where
            jobs[index].accountID == account.accountID && jobs[index].status == .failed {
            jobs[index].status = .waiting
            jobs[index].message = "等待重试"
            jobs[index].updatedAt = Date()
        }
        persist()
        run(account: account, assets: assets, client: client)
    }

    private func enqueue(assets: [LocalPhotoAsset], accountID: String) {
        for asset in assets {
            if let index = jobs.firstIndex(where: {
                $0.accountID == accountID && $0.localIdentifier == asset.localIdentifier
            }) {
                let sourceChanged = jobs[index].sourceModificationDate != asset.modificationDate
                if jobs[index].status == .completed, !sourceChanged {
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
                        status: .waiting,
                        totalBytes: 0,
                        uploadedBytes: 0,
                        resourceCount: 0,
                        assetID: nil,
                        sourceState: nil,
                        derivativeState: nil,
                        message: "等待上传",
                        updatedAt: Date()
                    )
                )
            }
        }
        headline = "已加入 \(assets.count) 项媒体"
        persist()
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
            }

            let jobIDs = self.jobs.filter {
                $0.accountID == account.accountID
                    && $0.status != .completed
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

    private func process(
        jobID: UUID,
        asset: LocalPhotoAsset,
        account: AccountContext,
        client: PhotoLibraryClient
    ) async {
        update(jobID) {
            $0.status = .preparing
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
                $0.message = "备份已暂停，将在下次打开时继续"
            }
        } catch {
            update(jobID) {
                $0.status = .failed
                $0.message = error.localizedDescription
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
            } catch let error as URLError where Self.isTransient(error) {
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
        for index in jobs.indices where jobs[index].status == .preparing || jobs[index].status == .uploading {
            jobs[index].status = .waiting
            jobs[index].message = "等待从 MyNAS 已接收的位置继续"
            changed = true
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

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            true
        default:
            false
        }
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
