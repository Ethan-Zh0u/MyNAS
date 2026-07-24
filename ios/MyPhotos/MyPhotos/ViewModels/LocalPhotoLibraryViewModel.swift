import Foundation
import Combine

@MainActor
final class LocalPhotoLibraryViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case needsPermission
        case denied
        case loading
        case ready
        case empty
        case failed(String)
    }

    @Published private(set) var authorization: PhotoAuthorizationState = .notDetermined
    @Published private(set) var assets: [LocalPhotoAsset] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingNextPage = false

    private let pageSize = 120
    private let client: PhotoLibraryClient
    private var nextOffset: Int?
    private var started = false

    init(client: PhotoLibraryClient? = nil) {
        self.client = client ?? PhotoLibraryClient()
        self.client.libraryDidChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshAfterLibraryChange()
            }
        }
    }

    var imageClient: PhotoLibraryClient { client }

    func start() async {
        guard !started else { return }
        started = true
        await refresh()
    }

    func requestAuthorization() async {
        state = .loading
        authorization = await client.requestAuthorization()
        await refresh()
    }

    func refresh() async {
        authorization = client.authorizationState()
        guard authorization.canReadLibrary else {
            assets = []
            nextOffset = nil
            state = authorization == .denied ? .denied : .needsPermission
            return
        }

        state = .loading
        assets = []
        nextOffset = 0
        client.resetFetch()
        await loadNextPage()
    }

    func loadNextPage() async {
        guard authorization.canReadLibrary, !isLoadingNextPage, let offset = nextOffset else { return }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        let page = client.page(offset: offset, size: pageSize)
        nextOffset = page.nextOffset
        assets.append(contentsOf: page.items)

        if assets.isEmpty && nextOffset == nil {
            state = .empty
        } else {
            state = .ready
        }
    }

    func showLimitedPicker() {
        client.presentLimitedLibraryPicker()
    }

    func prefetch(assets: [LocalPhotoAsset], targetSize: CGSize) {
        client.startCachingThumbnails(for: assets.prefix(80).map(\.localIdentifier), targetSize: targetSize)
    }

    private func refreshAfterLibraryChange() async {
        await refresh()
    }
}
