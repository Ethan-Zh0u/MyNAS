import AVFoundation
import Foundation

/// Feeds AVFoundation's byte-range requests through RemotePhotoLibraryClient.
/// The actor owns the same no-proxy URLSession used for MyNAS API calls, so a
/// Mac or Simulator PAC setting cannot divert a private Tailscale stream.
final class MyNASMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let sourceURL: URL
    private let resource: ServerPhotoResource
    private let asset: ServerPhotoAsset
    private let account: AccountContext
    private let client: RemotePhotoLibraryClient
    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        sourceURL: URL,
        resource: ServerPhotoResource,
        asset: ServerPhotoAsset,
        account: AccountContext,
        client: RemotePhotoLibraryClient
    ) {
        self.sourceURL = sourceURL
        self.resource = resource
        self.asset = asset
        self.account = account
        self.client = client
    }

    func makeAsset() throws -> AVURLAsset {
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        components.scheme = "mynas-media"
        guard let resourceLoadingURL = components.url else {
            throw RemotePhotoLibraryError.invalidServerURL
        }

        let asset = AVURLAsset(url: resourceLoadingURL)
        asset.resourceLoader.setDelegate(
            self,
            queue: DispatchQueue(label: "com.mynas.photos.media-resource-loader")
        )
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let identifier = ObjectIdentifier(loadingRequest)
        let range = requestedRange(for: loadingRequest)
        let task = Task { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            defer { self.removeTask(identifier) }
            do {
                let result = try await client.streamingData(
                    for: resource,
                    in: asset,
                    account: account,
                    offset: range.offset,
                    length: range.length
                )
                guard !Task.isCancelled else { return }
                if let informationRequest = loadingRequest.contentInformationRequest {
                    informationRequest.contentType = Self.uniformTypeIdentifier(
                        responseContentType: result.contentType,
                        fallback: resource.contentType
                    )
                    informationRequest.contentLength = result.contentLength
                    informationRequest.isByteRangeAccessSupported = result.supportsByteRanges
                }
                loadingRequest.dataRequest?.respond(with: result.data)
                loadingRequest.finishLoading()
            } catch {
                guard !Task.isCancelled else { return }
                loadingRequest.finishLoading(with: error)
            }
        }

        lock.lock()
        activeTasks[identifier] = task
        lock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = activeTasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.cancel()
    }

    private func requestedRange(
        for loadingRequest: AVAssetResourceLoadingRequest
    ) -> (offset: Int64, length: Int64) {
        guard let dataRequest = loadingRequest.dataRequest else {
            return (offset: 0, length: 2)
        }
        let offset = dataRequest.currentOffset > 0
            ? dataRequest.currentOffset
            : dataRequest.requestedOffset
        return (offset: max(offset, 0), length: Int64(max(dataRequest.requestedLength, 1)))
    }

    private func removeTask(_ identifier: ObjectIdentifier) {
        lock.lock()
        activeTasks.removeValue(forKey: identifier)
        lock.unlock()
    }

    /// `contentInformationRequest.contentType` expects a UTI, rather than an
    /// HTTP MIME type. Preserve PhotoKit's UTI where available and map the
    /// normalised server MIME values back to their corresponding movie UTIs.
    private static func uniformTypeIdentifier(
        responseContentType: String?,
        fallback: String
    ) -> String {
        switch responseContentType?.lowercased() {
        case "video/quicktime":
            "com.apple.quicktime-movie"
        case "video/mp4":
            "public.mpeg-4"
        default:
            fallback
        }
    }
}
