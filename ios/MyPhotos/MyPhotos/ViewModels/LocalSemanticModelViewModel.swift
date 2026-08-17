import Combine
import Foundation

nonisolated enum LocalSemanticModelOperationStage: Equatable, Sendable {
    case preparingDownload
    case downloading(currentFile: Int, totalFiles: Int)
    case validatingDownloadedFiles
    case copyingToDevice
    case validatingInstallation

    var userFacingText: String {
        switch self {
        case .preparingDownload:
            "正在连接 MyNAS…"
        case let .downloading(currentFile, totalFiles):
            "正在下载模型文件（\(currentFile)/\(totalFiles)）…"
        case .validatingDownloadedFiles:
            "正在校验下载文件…"
        case .copyingToDevice:
            "正在安装到此 iPhone…"
        case .validatingInstallation:
            "正在验证已安装模型…"
        }
    }
}

/// User-facing orchestration for the optional, shared Qwen package and the
/// separate current-account semantic-index consent. Installing a model never
/// reads Photos; the first image access happens only after the explicit
/// semantic-index action below.
@MainActor
final class LocalSemanticModelViewModel: ObservableObject {
    @Published private(set) var installationStatus: LocalSemanticModelInstallStatus = .notInstalled
    @Published private(set) var semanticStatus: PhotoSemanticIndexStatus = .disabled
    @Published private(set) var availableCapacity: Int64?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var operationStage: LocalSemanticModelOperationStage?
    @Published var errorMessage: String?

    let manifest = LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Manifest

    private let modelStore: LocalSemanticModelStore
    private let semanticStore: PhotoSemanticIndexStore
    private let myNASModelClient: MyNASSemanticModelClient
    private var activeAccountIdentity: String?
    private var automaticSynchronizationRequest: AutomaticSynchronizationRequest?
    private var isRunningAutomaticSynchronization = false

    private struct AutomaticSynchronizationRequest {
        let account: AccountContext
        let library: any LocalSemanticLibrarySource
    }

    init(
        modelStore: LocalSemanticModelStore = LocalSemanticModelStore(),
        semanticStore: PhotoSemanticIndexStore = PhotoSemanticIndexStore(),
        myNASModelClient: MyNASSemanticModelClient = MyNASSemanticModelClient()
    ) {
        self.modelStore = modelStore
        self.semanticStore = semanticStore
        self.myNASModelClient = myNASModelClient
    }

    var modelProfile: LocalEmbeddingModelProfile { manifest.profile }

    /// Installation stages a complete replacement before removing an older
    /// package, so the store needs double the package size at the final check.
    var minimumAvailableByteCount: Int64 {
        manifest.totalByteCount.multipliedReportingOverflow(by: 2).partialValue
    }

    /// Direct downloads temporarily retain the verified source package while
    /// atomically replacing an existing installation, so they need one extra
    /// package-sized reservation beyond a Files import.
    var minimumDownloadAvailableByteCount: Int64 {
        manifest.totalByteCount.multipliedReportingOverflow(by: 3).partialValue
    }

    var isRuntimeAvailable: Bool {
        MNNQwen3VLEmbeddingBridge.isRuntimeAvailable()
    }

    var canImportPackage: Bool {
        guard !isWorking else { return false }
        return availableCapacity.map { $0 >= minimumAvailableByteCount } ?? true
    }

    var canDownloadFromMyNAS: Bool {
        guard !isWorking else { return false }
        return availableCapacity.map { $0 >= minimumDownloadAvailableByteCount } ?? true
    }

    var canEnableSemanticIndex: Bool {
        installationStatus.isInstalled && isRuntimeAvailable && !isWorking
    }

    var operationStatusText: String? {
        operationStage?.userFacingText
    }

    func load(account: AccountContext) async {
        let identity = Self.identity(for: account)
        activeAccountIdentity = identity
        errorMessage = nil
        statusMessage = nil
        await refresh(account: account, identity: identity)
    }

    func importPinnedPackage(from directoryURL: URL, account: AccountContext) async {
        let identity = Self.identity(for: account)
        operationStage = .validatingDownloadedFiles
        await perform(account: account) {
            let didAccess = directoryURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    directoryURL.stopAccessingSecurityScopedResource()
                }
            }
            let installed = try await self.modelStore.installPinnedQwen3VLEmbedding2BInt8(
                packageDirectory: directoryURL,
                progress: { stage in
                    self.operationStage = stage
                }
            )
            guard self.activeAccountIdentity == identity else { return }
            self.installationStatus = installed
            self.statusMessage = "本地语义模型已校验并安装。尚未读取任何照片；请单独允许当前账号建立语义索引。"
            await self.refresh(account: account, identity: identity, preservesMessage: true)
        }
    }

    func downloadPinnedPackageFromMyNAS(account: AccountContext) async {
        let identity = Self.identity(for: account)
        operationStage = .preparingDownload
        await perform(account: account) {
            guard self.availableCapacity.map({ $0 >= self.minimumDownloadAvailableByteCount }) ?? true else {
                throw LocalSemanticModelPackageError.insufficientDiskSpace(
                    requiredByteCount: self.minimumDownloadAvailableByteCount
                )
            }
            let installed = try await self.myNASModelClient.downloadPinnedQwen3VLEmbedding2BInt8(
                for: account,
                into: self.modelStore,
                progress: { stage in
                    self.operationStage = stage
                }
            )
            guard self.activeAccountIdentity == identity else { return }
            self.installationStatus = installed
            self.statusMessage = "本地语义模型已从 MyNAS 下载、校验并安装。尚未读取任何照片。"
            await self.refresh(account: account, identity: identity, preservesMessage: true)
        }
    }

    func uninstallModel(account: AccountContext) async {
        let identity = Self.identity(for: account)
        await perform(account: account) {
            let didRemove = try await self.modelStore.uninstall(self.modelProfile)
            guard self.activeAccountIdentity == identity else { return }
            self.installationStatus = .notInstalled
            self.statusMessage = didRemove
                ? "本地语义模型已删除。当前账号的语义向量未删除，但在重新安装同一模型前不可用。"
                : "本地语义模型尚未安装。"
            await self.refresh(account: account, identity: identity, preservesMessage: true)
        }
    }

    func enableAndSynchronizeSemanticIndex(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        imageSource: any LocalSemanticImageSource
    ) async {
        let identity = Self.identity(for: account)
        await perform(account: account) {
            guard self.isRuntimeAvailable else {
                throw LocalSemanticEmbeddingRuntimeError.runtimeUnavailable
            }
            let engine = try await LocalMNNQwen3VLEmbeddingEngine.load(
                profile: self.modelProfile,
                modelStore: self.modelStore
            )
            let coordinator = LocalSemanticIndexCoordinator(
                store: self.semanticStore,
                engine: engine
            )
            _ = try await coordinator.enable(for: account)
            let result = try await coordinator.synchronize(
                assets: assets,
                for: account,
                imageSource: imageSource
            )
            guard self.activeAccountIdentity == identity else { return }
            self.semanticStatus = result.status
            self.statusMessage = Self.semanticSynchronizationMessage(for: result)
        }
    }

    func synchronizeSemanticIndex(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        imageSource: any LocalSemanticImageSource
    ) async {
        let identity = Self.identity(for: account)
        await perform(account: account) {
            guard self.isRuntimeAvailable else {
                throw LocalSemanticEmbeddingRuntimeError.runtimeUnavailable
            }
            let engine = try await LocalMNNQwen3VLEmbeddingEngine.load(
                profile: self.modelProfile,
                modelStore: self.modelStore
            )
            let coordinator = LocalSemanticIndexCoordinator(
                store: self.semanticStore,
                engine: engine
            )
            let result = try await coordinator.synchronize(
                assets: assets,
                for: account,
                imageSource: imageSource
            )
            guard self.activeAccountIdentity == identity else { return }
            self.semanticStatus = result.status
            self.statusMessage = Self.semanticSynchronizationMessage(for: result)
        }
    }

    /// Coalesces foreground lifecycle and PhotoKit-change triggers. Automatic
    /// work has exactly the same opt-in, image-source and model boundaries as
    /// the manual update action; it only makes newly accessible local photos
    /// searchable without requiring the user to revisit Settings.
    func requestAutomaticSynchronization(
        account: AccountContext,
        library: any LocalSemanticLibrarySource
    ) {
        automaticSynchronizationRequest = AutomaticSynchronizationRequest(
            account: account,
            library: library
        )
        guard !isRunningAutomaticSynchronization else { return }
        isRunningAutomaticSynchronization = true
        Task { @MainActor [weak self] in
            await self?.runAutomaticSynchronization()
        }
    }

    func clearSemanticIndex(account: AccountContext) async {
        let identity = Self.identity(for: account)
        await perform(account: account) {
            let cleared = try await self.semanticStore.clear(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.semanticStatus = cleared
            self.statusMessage = "当前账号的本地语义向量已清空。保留许可时，下次更新会重新建立索引。"
        }
    }

    func disableAndDeleteSemanticIndex(account: AccountContext) async {
        let identity = Self.identity(for: account)
        await perform(account: account) {
            let disabled = try await self.semanticStore.disableAndDelete(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.semanticStatus = disabled
            self.statusMessage = "当前账号的本地语义索引已关闭并删除。模型包、系统照片和 MyNAS 原件未受影响。"
        }
    }

    func reportImportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func refresh(
        account: AccountContext,
        identity: String,
        preservesMessage: Bool = false
    ) async {
        do {
            // The package is fully hashed during installation and again before
            // a fresh MNN engine is constructed. Opening Settings should only
            // read the signed installation record, rather than re-hashing a
            // 1.39 GB package and making the page feel stalled.
            let installed = try await modelStore.status(for: modelProfile)
            let capacity = try await modelStore.availableCapacityForImportantUsage()
            let semantic = try await semanticStore.status(for: account)
            guard activeAccountIdentity == identity else { return }
            installationStatus = installed
            availableCapacity = capacity
            semanticStatus = semantic
            if !preservesMessage {
                statusMessage = nil
            }
        } catch {
            guard activeAccountIdentity == identity else { return }
            installationStatus = .notInstalled
            semanticStatus = .disabled
            availableCapacity = nil
            errorMessage = error.localizedDescription
        }
    }

    private func runAutomaticSynchronization() async {
        defer { isRunningAutomaticSynchronization = false }

        while !Task.isCancelled, let request = automaticSynchronizationRequest {
            automaticSynchronizationRequest = nil
            let identity = Self.identity(for: request.account)
            // `load` reads the installed-package record. A full digest check
            // occurs immediately before a fresh MNN engine is constructed,
            // avoiding a multi-gigabyte re-hash for every Settings appearance.
            if activeAccountIdentity != identity {
                await load(account: request.account)
            }
            guard activeAccountIdentity == identity,
                  installationStatus.isInstalled,
                  semanticStatus.isEnabled,
                  isRuntimeAvailable else {
                continue
            }

            // A user-initiated install or update owns the same serial MNN
            // path. Wait rather than dropping a PhotoKit lifecycle trigger.
            while isWorking && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            if automaticSynchronizationRequest != nil { continue }

            let assets = await request.library.allAccessibleAssets()
            guard activeAccountIdentity == identity else { continue }
            if automaticSynchronizationRequest != nil { continue }

            do {
                // Most lifecycle notifications do not change a static image.
                // This cheap, value-only preflight prevents an unnecessary
                // package validation and MNN setup when the vector snapshot
                // already matches the accessible library.
                guard try await semanticStore.needsSynchronization(
                    from: assets,
                    modelProfile: modelProfile,
                    for: request.account
                ) else {
                    continue
                }
            } catch {
                guard activeAccountIdentity == identity else { continue }
                errorMessage = error.localizedDescription
                continue
            }

            do {
                let candidates = try await semanticStore.assetsNeedingEmbedding(
                    from: assets,
                    modelProfile: modelProfile,
                    for: request.account
                )
                if candidates.isEmpty {
                    // A removal needs the same current-library reconciliation
                    // but no image inference or model load.
                    await synchronizeSemanticScope(
                        assets: assets,
                        account: request.account
                    )
                    continue
                }

                // iCloud-only photos remain intentionally out of scope. Probe
                // the constrained, non-network image boundary before opening
                // MNN so an unavailable photo cannot repeatedly load the
                // multi-gigabyte package on every foreground notification.
                guard await hasLocallyAccessibleCandidate(
                    candidates,
                    imageSource: request.library
                ) else {
                    // Mark added cloud-only inputs as deferred and invalidate
                    // any previous vector for a changed-but-now-unavailable
                    // photo. This keeps stale results out without loading MNN.
                    await synchronizeSemanticScope(
                        assets: assets,
                        account: request.account
                    )
                    continue
                }
            } catch {
                guard activeAccountIdentity == identity else { continue }
                errorMessage = error.localizedDescription
                continue
            }

            await synchronizeSemanticIndex(
                assets: assets,
                account: request.account,
                imageSource: request.library
            )
        }
    }

    /// Reconciles a vector snapshot when records left the current Photos scope.
    /// Passing no embedding output is safe only after the automatic path has
    /// established there are no added or changed static-image candidates.
    private func synchronizeSemanticScope(
        assets: [LocalPhotoAsset],
        account: AccountContext
    ) async {
        let identity = Self.identity(for: account)
        await perform(account: account) {
            let result = try await self.semanticStore.synchronize(
                assets: assets,
                outputs: [],
                modelProfile: self.modelProfile,
                for: account
            )
            guard self.activeAccountIdentity == identity else { return }
            self.semanticStatus = result.status
            self.statusMessage = Self.semanticSynchronizationMessage(for: result)
        }
    }

    /// This is a bounded, non-network availability probe. It deliberately
    /// discards the image immediately; `LocalSemanticIndexCoordinator` asks
    /// for a fresh short-lived input only when MNN is actually needed.
    private func hasLocallyAccessibleCandidate(
        _ candidates: [LocalPhotoAsset],
        imageSource: any LocalSemanticImageSource
    ) async -> Bool {
        for candidate in candidates {
            guard !Task.isCancelled else { return false }
            if (await imageSource.semanticIndexImage(for: candidate.localIdentifier)).image != nil {
                return true
            }
        }
        return false
    }

    private func perform(
        account: AccountContext,
        operation: @escaping @MainActor () async throws -> Void
    ) async {
        let identity = Self.identity(for: account)
        guard activeAccountIdentity == identity, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer {
            if activeAccountIdentity == identity {
                isWorking = false
                operationStage = nil
            }
        }
        do {
            try await operation()
        } catch {
            guard activeAccountIdentity == identity else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func semanticSynchronizationMessage(
        for result: PhotoSemanticIndexSyncResult
    ) -> String {
        var message = "已更新语义索引 \(result.status.indexedAssetCount) 项：新增 \(result.insertedCount)、更新 \(result.updatedCount)、移除 \(result.removedCount)。"
        if result.deferredAssetCount > 0 {
            message += " \(result.deferredAssetCount) 项当前无法在本机读取，未保留旧向量。"
        }
        return message
    }

    private static func identity(for account: AccountContext) -> String {
        "\(account.accountID)|\(account.serverID)|\(account.userID)"
    }
}
