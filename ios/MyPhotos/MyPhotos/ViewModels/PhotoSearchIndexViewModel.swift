import Foundation
import Combine

@MainActor
final class PhotoSearchIndexViewModel: ObservableObject {
    @Published private(set) var status: PhotoSearchIndexStatus = .disabled
    @Published private(set) var results: [PhotoSearchIndexRecord] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?

    private let store: PhotoSearchIndexStore
    private var activeAccountIdentity: String?
    private var activeQuery = ""

    init(store: PhotoSearchIndexStore = PhotoSearchIndexStore()) {
        self.store = store
    }

    func load(account: AccountContext) async {
        let identity = Self.identity(for: account)
        activeAccountIdentity = identity
        activeQuery = ""
        results = []
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

    func enable(account: AccountContext) async -> Bool {
        let identity = Self.identity(for: account)
        return await perform(account: account) {
            let enabled = try await self.store.enable(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = enabled
            self.statusMessage = "本地索引已启用，尚未读取任何照片像素。"
        }
    }

    func synchronize(assets: [LocalPhotoAsset], account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let result = try await self.store.synchronize(assets: assets, for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = result.status
            self.statusMessage = "已索引 \(result.status.indexedAssetCount) 项：新增 \(result.insertedCount)、更新 \(result.updatedCount)、移除 \(result.removedCount)。"
            await self.refreshSearchIfNeeded(account: account)
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
            self.statusMessage = "当前账号的本地索引已清空。"
        }
    }

    func disableAndDelete(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let disabled = try await self.store.disableAndDelete(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = disabled
            self.results = []
            self.statusMessage = "本地索引已关闭并删除。"
        }
    }

    func resetCorruptedIndex(account: AccountContext) async {
        let identity = Self.identity(for: account)
        _ = await perform(account: account) {
            let reset = try await self.store.resetCorruptedIndex(for: account)
            guard self.activeAccountIdentity == identity else { return }
            self.status = reset
            self.results = []
            self.errorMessage = nil
            self.statusMessage = "不可读的本地索引已移除。"
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

    private static func identity(for account: AccountContext) -> String {
        "\(account.accountID)|\(account.serverID)|\(account.userID)"
    }
}
