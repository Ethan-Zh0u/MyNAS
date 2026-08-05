import AVFoundation
import Foundation

/// Feeds AVFoundation's byte-range requests through an isolated no-proxy
/// session. Responses are forwarded as URLSession data chunks: unlike
/// `URLSession.data(for:)`, this never buffers a whole original video in RAM.
final class MyNASMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private final class ActiveRequest {
        let loadingRequest: AVAssetResourceLoadingRequest
        var preparationTask: Task<Void, Never>?
        var networkTask: URLSessionDataTask?

        init(loadingRequest: AVAssetResourceLoadingRequest) {
            self.loadingRequest = loadingRequest
        }
    }

    /// URLSession keeps its delegate alive until invalidation. Keeping only a
    /// weak back-reference here lets a dismissed video detail release its
    /// loader and cancel any in-flight range request.
    private final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: MyNASMediaResourceLoader?

        init(owner: MyNASMediaResourceLoader) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let owner else {
                completionHandler(.cancel)
                return
            }
            owner.handleResponse(
                for: dataTask,
                response: response,
                completionHandler: completionHandler
            )
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            owner?.handleData(data, for: dataTask)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            owner?.handleCompletion(for: task, error: error)
        }
    }

    private let sourceURL: URL
    private let resource: ServerPhotoResource
    private let asset: ServerPhotoAsset
    private let account: AccountContext
    private let client: RemotePhotoLibraryClient
    private let lock = NSLock()
    private var activeRequests: [ObjectIdentifier: ActiveRequest] = [:]
    private var requestIdentifiersByTaskID: [Int: ObjectIdentifier] = [:]
    private lazy var streamingSessionDelegate = StreamingSessionDelegate(owner: self)

    private lazy var streamingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Keep Tailscale video traffic independent from an iPhone, Simulator,
        // or Mac PAC/proxy configuration, just like the MyNAS API session.
        configuration.connectionProxyDictionary = [:]
        return URLSession(
            configuration: configuration,
            delegate: streamingSessionDelegate,
            delegateQueue: nil
        )
    }()

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

    deinit {
        invalidate()
    }

    /// The detail view calls this as soon as it disappears. AVFoundation can
    /// otherwise keep a speculative range request alive while the user has
    /// already returned to the MyNAS gallery.
    func invalidate() {
        let requests: [ActiveRequest]
        lock.lock()
        requests = Array(activeRequests.values)
        activeRequests.removeAll()
        requestIdentifiersByTaskID.removeAll()
        lock.unlock()

        for request in requests {
            request.preparationTask?.cancel()
            request.networkTask?.cancel()
        }
        streamingSession.invalidateAndCancel()
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
        let activeRequest = ActiveRequest(loadingRequest: loadingRequest)
        lock.lock()
        activeRequests[identifier] = activeRequest
        lock.unlock()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.makeStreamingRequest(for: loadingRequest)
                guard !Task.isCancelled else { return }
                self.startNetworkRequest(request, for: identifier)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishRequest(identifier, error: error)
            }
        }

        lock.lock()
        if activeRequests[identifier] === activeRequest {
            activeRequest.preparationTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancelRequest(ObjectIdentifier(loadingRequest))
    }

    private func makeStreamingRequest(
        for loadingRequest: AVAssetResourceLoadingRequest
    ) async throws -> URLRequest {
        guard resource.byteSize > 0 else {
            throw RemotePhotoLibraryError.invalidResource
        }
        let sourceURL = try await client.streamingURL(
            for: resource,
            in: asset,
            account: account
        )
        let range = requestedRange(for: loadingRequest)
        guard range.offset < resource.byteSize else {
            throw RemotePhotoLibraryError.invalidResource
        }
        let safeLength = min(range.length, resource.byteSize - range.offset)

        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.setValue("video/*", forHTTPHeaderField: "Accept")
        request.setValue(
            "bytes=\(range.offset)-\(range.offset + safeLength - 1)",
            forHTTPHeaderField: "Range"
        )
        return request
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
        return (
            offset: max(offset, 0),
            length: Int64(clamping: max(dataRequest.requestedLength, 1))
        )
    }

    private func startNetworkRequest(_ request: URLRequest, for identifier: ObjectIdentifier) {
        let task: URLSessionDataTask
        lock.lock()
        guard let activeRequest = activeRequests[identifier] else {
            lock.unlock()
            return
        }
        task = streamingSession.dataTask(with: request)
        activeRequest.networkTask = task
        requestIdentifiersByTaskID[task.taskIdentifier] = identifier
        lock.unlock()
        task.resume()
    }

    private func cancelRequest(_ identifier: ObjectIdentifier) {
        let activeRequest: ActiveRequest?
        lock.lock()
        activeRequest = activeRequests.removeValue(forKey: identifier)
        if let taskID = activeRequest?.networkTask?.taskIdentifier {
            requestIdentifiersByTaskID.removeValue(forKey: taskID)
        }
        lock.unlock()
        activeRequest?.preparationTask?.cancel()
        activeRequest?.networkTask?.cancel()
    }

    private func finishRequest(_ identifier: ObjectIdentifier, error: Error? = nil) {
        let activeRequest: ActiveRequest?
        lock.lock()
        activeRequest = activeRequests.removeValue(forKey: identifier)
        if let taskID = activeRequest?.networkTask?.taskIdentifier {
            requestIdentifiersByTaskID.removeValue(forKey: taskID)
        }
        lock.unlock()

        activeRequest?.networkTask?.cancel()
        if let error {
            activeRequest?.loadingRequest.finishLoading(with: error)
        } else {
            activeRequest?.loadingRequest.finishLoading()
        }
    }

    private func activeRequest(for task: URLSessionTask) -> (ObjectIdentifier, ActiveRequest)? {
        lock.lock()
        defer { lock.unlock() }
        guard let identifier = requestIdentifiersByTaskID[task.taskIdentifier],
              let activeRequest = activeRequests[identifier],
              activeRequest.networkTask?.taskIdentifier == task.taskIdentifier else {
            return nil
        }
        return (identifier, activeRequest)
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

private extension MyNASMediaResourceLoader {
    func handleResponse(
        for dataTask: URLSessionDataTask,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let (identifier, activeRequest) = activeRequest(for: dataTask),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            if let (identifier, _) = activeRequest(for: dataTask) {
                finishRequest(identifier, error: RemotePhotoLibraryError.invalidResponse)
            }
            return
        }

        // A server that ignored Range would return the wrong bytes for every
        // request after the first. Refuse it rather than corrupting playback.
        if httpResponse.statusCode != 206,
           dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil,
           (activeRequest.loadingRequest.dataRequest?.requestedOffset ?? 0) > 0 {
            completionHandler(.cancel)
            finishRequest(identifier, error: RemotePhotoLibraryError.invalidResponse)
            return
        }

        if let informationRequest = activeRequest.loadingRequest.contentInformationRequest {
            informationRequest.contentType = Self.uniformTypeIdentifier(
                responseContentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                fallback: resource.contentType
            )
            informationRequest.contentLength = resource.byteSize
            informationRequest.isByteRangeAccessSupported = httpResponse.statusCode == 206
                || httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
        completionHandler(.allow)
    }

    func handleData(_ data: Data, for dataTask: URLSessionDataTask) {
        guard let (_, activeRequest) = activeRequest(for: dataTask) else { return }
        activeRequest.loadingRequest.dataRequest?.respond(with: data)
    }

    func handleCompletion(for task: URLSessionTask, error: Error?) {
        guard let (identifier, _) = activeRequest(for: task) else { return }
        finishRequest(identifier, error: error)
    }
}
