import Combine
import Foundation

@MainActor
final class PhotoAnalysisQueueViewModel: ObservableObject {
    @Published private(set) var status: PhotoAnalysisQueueStatus = .disabled
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?

    private let store: PhotoAnalysisQueueStore
    private var activeAccountIdentity: String?

    init(store: PhotoAnalysisQueueStore = PhotoAnalysisQueueStore()) {
        self.store = store
    }

    func load(account: AccountContext) async {
        let identity = Self.identity(for: account)
        activeAccountIdentity = identity
        isWorking = false
        statusMessage = nil
        errorMessage = nil
        do {
            let loaded = try await store.status(for: account)
            guard activeAccountIdentity == identity else { return }
            status = loaded
        } catch {
            guard activeAccountIdentity == identity else { return }
            status = .disabled
            errorMessage = error.localizedDescription
        }
    }

    func enableAndPrepare(assets: [LocalPhotoAsset], account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            _ = try await self.store.enablePixelAnalysis(for: account)
            let result = try await self.store.prepare(assets: assets, for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = result.status
            self.statusMessage = Self.preparedMessage(for: result)
        }
    }

    func prepare(assets: [LocalPhotoAsset], account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let result = try await self.store.prepare(assets: assets, for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = result.status
            self.statusMessage = Self.preparedMessage(for: result)
        }
    }

    func disableAndDelete(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let disabled = try await self.store.disableAndDelete(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = disabled
            self.statusMessage = "已撤回当前账号的端侧像素分析许可，并删除本地队列及其依赖数据。"
        }
    }

    func resetCorruptedQueue(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let disabled = try await self.store.resetCorruptedQueue(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = disabled
            self.errorMessage = nil
            self.statusMessage = "不可读的端侧分析数据已删除，像素分析仍保持关闭。"
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

    private static func preparedMessage(for result: PhotoAnalysisQueueSyncResult) -> String {
        "已准备 \(result.status.pendingAssetCount) 项：新增 \(result.insertedCount)、更新 \(result.updatedCount)、移除 \(result.removedCount)。I2 未读取任何照片或视频像素。"
    }

    private static func identity(for account: AccountContext) -> String {
        "\(account.accountID)|\(account.serverID)|\(account.userID)"
    }
}
