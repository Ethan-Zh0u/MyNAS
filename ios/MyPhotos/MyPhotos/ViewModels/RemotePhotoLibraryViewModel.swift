import Combine
import Foundation

@MainActor
final class RemotePhotoLibraryViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case empty
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var assets: [ServerPhotoAsset] = []
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var isUsingOfflineCache = false
    @Published private(set) var paginationErrorMessage: String?
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var requiresFullRefresh = false

    let account: AccountContext
    let client: RemotePhotoLibraryClient
    private var nextCursor: String?
    private var hasMore = true
    private var isSynchronizingChanges = false

    init(
        account: AccountContext,
        client: RemotePhotoLibraryClient = RemotePhotoLibraryClient()
    ) {
        self.account = account
        self.client = client
    }

    func start() async {
        guard state == .idle else { return }
        await refresh()
        await establishChangeBaseline()
    }

    func refresh() async {
        state = .loading
        paginationErrorMessage = nil
        do {
            let result = try await client.fetchAssets(
                account: account,
                cursor: nil
            )
            guard !Task.isCancelled else { return }
            assets = result.page.assets
            nextCursor = result.page.nextCursor
            hasMore = result.page.hasMore
            isUsingOfflineCache = result.isUsingOfflineCache
            state = assets.isEmpty ? .empty : .ready
            pendingChangeCount = 0
            requiresFullRefresh = false
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "暂时无法读取 MyNAS 图库。"
            )
        }
    }

    func loadNextPage() async {
        guard hasMore,
              !isLoadingNextPage,
              paginationErrorMessage == nil,
              state == .ready else {
            return
        }
        guard let cursor = nextCursor else {
            hasMore = false
            return
        }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        do {
            let result = try await client.fetchAssets(
                account: account,
                cursor: cursor
            )
            guard !Task.isCancelled else { return }
            var knownIDs = Set(assets.map(\.id))
            assets.append(
                contentsOf: result.page.assets.filter { knownIDs.insert($0.id).inserted }
            )
            nextCursor = result.page.nextCursor
            hasMore = result.page.hasMore
            isUsingOfflineCache = isUsingOfflineCache || result.isUsingOfflineCache
        } catch {
            guard !Task.isCancelled else { return }
            paginationErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "下一页暂时无法读取。"
        }
    }

    func retryNextPage() async {
        paginationErrorMessage = nil
        await loadNextPage()
    }

    /// Called only while the remote gallery is visible. It never mutates a
    /// paginated grid in place: a small banner lets the user decide when to
    /// reload from the first page, avoiding duplicate cells and scroll jumps.
    func checkForRemoteChanges() async {
        guard state == .ready, !isSynchronizingChanges else { return }
        isSynchronizingChanges = true
        defer { isSynchronizingChanges = false }
        do {
            let result = try await client.synchronizeChanges(account: account)
            guard !Task.isCancelled, !result.isInitialSync else { return }
            if result.resetRequired {
                requiresFullRefresh = true
                pendingChangeCount = max(pendingChangeCount, 1)
            } else if result.changeCount > 0 {
                pendingChangeCount += result.changedAssetIDs.count
            }
        } catch {
            // A polling failure should not replace a usable remote grid. Pull to
            // refresh remains available, and the next foreground poll retries.
        }
    }

    private func establishChangeBaseline() async {
        guard !isSynchronizingChanges else { return }
        isSynchronizingChanges = true
        defer { isSynchronizingChanges = false }
        do {
            _ = try await client.synchronizeChanges(account: account)
        } catch {
            // The gallery itself is still usable. A later foreground poll can
            // establish the cursor once the network returns.
        }
    }
}
