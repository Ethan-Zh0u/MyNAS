import Combine
import Foundation

@MainActor
final class UnifiedPhotoTimelineViewModel: ObservableObject {
    enum RemoteState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var items: [UnifiedPhotoTimelineItem] = []
    @Published private(set) var remoteState: RemoteState = .idle
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var isUsingOfflineCache = false

    private let client: RemotePhotoLibraryClient
    private var localAssets: [LocalPhotoAsset] = []
    private var jobs: [PhotoBackupJob] = []
    private var accountID = ""
    private var remoteAssets: [ServerPhotoAsset] = []
    private var nextRemoteCursor: String?
    private var remoteHasMore = false
    private var isSynchronizingRemoteChanges = false

    init(client: RemotePhotoLibraryClient = RemotePhotoLibraryClient()) {
        self.client = client
    }

    var hasMoreRemoteItems: Bool { remoteHasMore }
    var remoteClient: RemotePhotoLibraryClient { client }
    var currentLocalAssets: [LocalPhotoAsset] { localAssets }
    var currentRemoteAssets: [ServerPhotoAsset] { remoteAssets }

    func synchronizeLocal(
        assets: [LocalPhotoAsset],
        jobs: [PhotoBackupJob],
        accountID: String
    ) {
        if self.accountID != accountID {
            self.accountID = accountID
            remoteAssets = []
            nextRemoteCursor = nil
            remoteHasMore = false
            remoteState = .idle
            isUsingOfflineCache = false
        }
        localAssets = assets
        self.jobs = jobs
        rebuildItems()
    }

    func refreshRemote(account: AccountContext) async {
        guard !account.isLocalOnly else {
            remoteAssets = []
            nextRemoteCursor = nil
            remoteHasMore = false
            remoteState = .ready
            isUsingOfflineCache = false
            rebuildItems()
            return
        }
        guard remoteState != .loading else { return }

        remoteState = .loading
        do {
            let result = try await client.fetchAssets(
                account: account,
                cursor: nil,
                limit: 120
            )
            guard !Task.isCancelled else { return }
            remoteAssets = result.page.assets
            nextRemoteCursor = result.page.nextCursor
            remoteHasMore = result.page.hasMore
            isUsingOfflineCache = result.isUsingOfflineCache
            remoteState = .ready
            rebuildItems()
        } catch {
            guard !Task.isCancelled else { return }
            remoteState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "暂时无法读取 MyNAS 项目。"
            )
            rebuildItems()
        }
    }

    func loadNextRemotePage(account: AccountContext) async {
        guard remoteHasMore,
              !isLoadingNextPage,
              let cursor = nextRemoteCursor,
              !account.isLocalOnly else {
            return
        }

        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        do {
            let result = try await client.fetchAssets(
                account: account,
                cursor: cursor,
                limit: 120
            )
            guard !Task.isCancelled else { return }
            var knownIDs = Set(remoteAssets.map(\.id))
            remoteAssets.append(
                contentsOf: result.page.assets.filter { knownIDs.insert($0.id).inserted }
            )
            nextRemoteCursor = result.page.nextCursor
            remoteHasMore = result.page.hasMore
            isUsingOfflineCache = isUsingOfflineCache || result.isUsingOfflineCache
            rebuildItems()
        } catch {
            guard !Task.isCancelled else { return }
            remoteState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "下一页 MyNAS 项目暂时无法读取。"
            )
        }
    }

    /// While the unified "全部" timeline is visible, refresh its remote slice
    /// after the server publishes a new derivative version. The image cache key
    /// includes that derivative hash, so this naturally stops old previews from
    /// being reused after a server-side rebuild.
    func checkForRemoteChanges(account: AccountContext) async {
        guard !account.isLocalOnly,
              remoteState == .ready,
              !isSynchronizingRemoteChanges else {
            return
        }
        isSynchronizingRemoteChanges = true
        defer { isSynchronizingRemoteChanges = false }
        do {
            let result = try await client.synchronizeChanges(account: account)
            guard !Task.isCancelled,
                  !result.isInitialSync,
                  result.resetRequired || result.changeCount > 0 else {
                return
            }
            await refreshRemote(account: account)
        } catch {
            // Keep the visible local/remote timeline usable. The next poll or
            // pull-to-refresh retries instead of replacing it with an error.
        }
    }

    private func rebuildItems() {
        items = UnifiedPhotoTimelineItem.merge(
            localAssets: localAssets,
            jobs: jobs,
            accountID: accountID,
            remoteAssets: remoteAssets
        )
    }
}
