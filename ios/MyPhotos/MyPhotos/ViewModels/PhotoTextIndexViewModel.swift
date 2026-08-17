import Combine
import Foundation

@MainActor
final class PhotoTextIndexViewModel: ObservableObject {
    @Published private(set) var status: PhotoTextIndexStatus = .disabled
    @Published private(set) var results: [PhotoTextIndexRecord] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?

    private let store: PhotoTextIndexStore
    private let recognizer: VisionTextRecognitionCoordinator
    private var activeAccountIdentity: String?
    private var activeQuery = ""
    private var automaticSynchronizationRequest: AutomaticSynchronizationRequest?
    private var isRunningAutomaticSynchronization = false

    private struct AutomaticSynchronizationRequest {
        let account: AccountContext
        let photoClient: PhotoLibraryClient
    }

    init(
        store: PhotoTextIndexStore = PhotoTextIndexStore(),
        recognizer: VisionTextRecognitionCoordinator? = nil
    ) {
        self.store = store
        self.recognizer = recognizer ?? VisionTextRecognitionCoordinator()
    }

    func load(account: AccountContext) async {
        let identity = Self.identity(for: account)
        let didChangeAccount = activeAccountIdentity != identity
        activeAccountIdentity = identity
        if didChangeAccount {
            activeQuery = ""
            results = []
            isWorking = false
            statusMessage = nil
            errorMessage = nil
        }
        do {
            let loaded = try await store.status(for: account)
            guard activeAccountIdentity == identity else { return }
            status = loaded
            guard loaded.isEnabled else {
                activeQuery = ""
                results = []
                return
            }
            await refreshSearchIfNeeded(account: account)
        } catch {
            guard activeAccountIdentity == identity else { return }
            status = .disabled
            activeQuery = ""
            results = []
            errorMessage = error.localizedDescription
        }
    }

    func enableAndSynchronize(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        photoClient: PhotoLibraryClient
    ) async {
        await synchronize(
            assets: assets,
            account: account,
            photoClient: photoClient,
            enablesIndex: true
        )
    }

    func synchronize(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        photoClient: PhotoLibraryClient
    ) async {
        await synchronize(
            assets: assets,
            account: account,
            photoClient: photoClient,
            enablesIndex: false
        )
    }

    /// Coalesces lifecycle and PhotoKit-change triggers into full-library,
    /// incremental OCR work. A new trigger received while Vision is busy is
    /// retained and runs immediately afterward, so a large iCloud library is
    /// never skipped just because another update was already in flight.
    func requestAutomaticSynchronization(
        account: AccountContext,
        photoClient: PhotoLibraryClient
    ) {
        automaticSynchronizationRequest = AutomaticSynchronizationRequest(
            account: account,
            photoClient: photoClient
        )
        guard !isRunningAutomaticSynchronization else { return }
        isRunningAutomaticSynchronization = true
        Task { @MainActor [weak self] in
            await self?.runAutomaticSynchronization()
        }
    }

    func updateQuery(_ query: String, account: AccountContext) async {
        activeQuery = query
        let identity = Self.identity(for: account)
        guard activeAccountIdentity == identity else { return }
        guard status.isEnabled, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        do {
            let found = try await store.search(query, for: account)
            guard activeAccountIdentity == identity, activeQuery == query else { return }
            results = found
        } catch {
            guard activeAccountIdentity == identity, activeQuery == query else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }

    func clear(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let cleared = try await self.store.clear(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = cleared
            self.results = []
            self.statusMessage = "当前账号的本地 OCR 文字索引已清空。"
        }
    }

    func disableAndDelete(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let disabled = try await self.store.disableAndDelete(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = disabled
            self.results = []
            self.statusMessage = "本地 OCR 文字索引已关闭并删除；端侧像素分析许可仍保持不变。"
        }
    }

    func resetCorruptedIndex(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let disabled = try await self.store.resetCorruptedIndex(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = disabled
            self.results = []
            self.errorMessage = nil
            self.statusMessage = "不可读的本地 OCR 文字索引已删除。"
        }
    }

    private func synchronize(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        photoClient: PhotoLibraryClient,
        enablesIndex: Bool
    ) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            if enablesIndex {
                _ = try await self.store.enable(for: account)
            }
            let candidates = try await self.store.assetsNeedingRecognition(from: assets, for: account)
            let outputs = try await self.recognizer.recognize(
                assets: candidates,
                photoClient: photoClient
            )
            let result = try await self.store.synchronize(
                assets: assets,
                outputs: outputs,
                for: account
            )
            guard self.activeAccountIdentity == identity else { return }
            self.status = result.status
            self.statusMessage = Self.synchronizedMessage(for: result)
            await self.refreshSearchIfNeeded(account: account)
        }
    }

    private func perform(
        account: AccountContext,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        let identity = Self.identity(for: account)
        guard activeAccountIdentity == identity, !isWorking else { return false }
        isWorking = true
        errorMessage = nil
        defer {
            if activeAccountIdentity == identity {
                isWorking = false
            }
        }
        do {
            try await operation()
            return activeAccountIdentity == identity
        } catch {
            guard activeAccountIdentity == identity else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshSearchIfNeeded(account: AccountContext) async {
        guard !activeQuery.isEmpty else { return }
        let query = activeQuery
        do {
            let found = try await store.search(query, for: account)
            guard activeAccountIdentity == Self.identity(for: account), activeQuery == query else { return }
            results = found
        } catch {
            guard activeAccountIdentity == Self.identity(for: account) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func runAutomaticSynchronization() async {
        defer { isRunningAutomaticSynchronization = false }

        while !Task.isCancelled, let request = automaticSynchronizationRequest {
            automaticSynchronizationRequest = nil
            let identity = Self.identity(for: request.account)
            await load(account: request.account)
            guard activeAccountIdentity == identity, status.isEnabled else { continue }

            // A foreground/manual update owns the same serial Vision path.
            // Wait rather than discard this automatic trigger.
            while isWorking && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            if automaticSynchronizationRequest != nil { continue }

            let assets = await request.photoClient.allAccessibleAssets()
            guard activeAccountIdentity == identity else { continue }
            if automaticSynchronizationRequest != nil { continue }
            await synchronize(
                assets: assets,
                account: request.account,
                photoClient: request.photoClient
            )
        }
    }

    private static func synchronizedMessage(for result: PhotoTextIndexSyncResult) -> String {
        var message = "已更新 OCR 索引 \(result.status.indexedAssetCount) 项：新增 \(result.insertedCount)、更新 \(result.updatedCount)、移除 \(result.removedCount)。"
        if result.deferredAssetCount > 0 {
            message += " \(result.deferredAssetCount) 项暂时无法从 Photos 读取，将在下次自动更新或手动更新时重试。"
        }
        return message
    }

    private static func identity(for account: AccountContext) -> String {
        "\(account.accountID)|\(account.serverID)|\(account.userID)"
    }
}
