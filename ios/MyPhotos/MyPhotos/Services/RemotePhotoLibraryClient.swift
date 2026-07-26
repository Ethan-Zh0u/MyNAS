import CryptoKit
import Foundation

enum RemotePhotoLibraryError: LocalizedError, Sendable {
    case notConnected
    case featureUnavailable
    case invalidServerURL
    case invalidResource
    case invalidResponse
    case unauthorized
    case backupTrashRejected
    case serverRejected(Int)
    case corruptedDownload

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "尚未连接 MyNAS。"
        case .featureUnavailable:
            "这台 MyNAS 尚未启用远端图库，请先更新服务器并重新连接。"
        case .invalidServerURL:
            "MyNAS 返回了不安全或无法识别的文件地址。"
        case .invalidResource:
            "这个原件资源不属于当前 MyNAS 项目。"
        case .invalidResponse:
            "MyNAS 返回了无法识别的图库数据。"
        case .unauthorized:
            "Tailscale 身份验证已失效，请确认 Tailscale 仍处于连接状态。"
        case .backupTrashRejected:
            "MyNAS 拒绝移动备份，以避免删除未完成、已变化或被其他设备共用的原件。"
        case .serverRejected(let status):
            "MyNAS 暂时无法读取图库（HTTP \(status)）。"
        case .corruptedDownload:
            "下载的预览文件未通过完整性校验。"
        }
    }
}

actor RemotePhotoLibraryClient {
    private nonisolated struct MetadataCacheEnvelope: Codable {
        let eTag: String?
        let fetchedAt: Date
        let page: ServerAssetPage
    }

    private nonisolated struct ImageCacheEnvelope: Codable {
        let eTag: String?
        let sha256: String
        let fetchedAt: Date
    }

    private nonisolated struct ChangeCursorCacheEnvelope: Codable {
        let cursor: String
        let eTag: String?
    }

    private let session: URLSession
    private let directories = CacheDirectoryProvider()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let imageFreshness: TimeInterval = 6 * 60 * 60
    private let maximumImageBytes = 24 * 1_024 * 1_024

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration)
        }
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func fetchAssets(
        account: AccountContext,
        cursor: String?,
        limit: Int = 60
    ) async throws -> RemotePhotoPageResult {
        guard let baseURL = account.serverURL else {
            throw RemotePhotoLibraryError.notConnected
        }
        if account.serverCapabilities.supportsRemoteBrowsing == false {
            throw RemotePhotoLibraryError.featureUnavailable
        }

        let cacheURL = try metadataCacheURL(account: account, cursor: cursor)
        let cachedEnvelope = try? loadMetadataEnvelope(from: cacheURL)
        let requestURL = try assetPageURL(
            baseURL: baseURL,
            cursor: cursor,
            limit: min(max(limit, 1), 200)
        )
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let eTag = cachedEnvelope?.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = try validatedHTTPResponse(response, data: data)
            if httpResponse.statusCode == 304, let cachedEnvelope {
                return RemotePhotoPageResult(
                    page: cachedEnvelope.page,
                    isUsingOfflineCache: false
                )
            }
            guard httpResponse.statusCode == 200 else {
                throw error(for: httpResponse.statusCode)
            }
            let page: ServerAssetPage
            do {
                page = try decoder.decode(ServerAssetPage.self, from: data)
            } catch {
                throw RemotePhotoLibraryError.invalidResponse
            }
            let envelope = MetadataCacheEnvelope(
                eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
                fetchedAt: Date(),
                page: page
            )
            try persist(envelope, to: cacheURL)
            return RemotePhotoPageResult(page: page, isUsingOfflineCache: false)
        } catch {
            if let cachedEnvelope, Self.canUseOfflineCache(after: error) {
                return RemotePhotoPageResult(
                    page: cachedEnvelope.page,
                    isUsingOfflineCache: true
                )
            }
            throw error
        }
    }

    /// Fetches only server-confirmed mappings for this account and this iPhone.
    /// It never infers relationships from filenames, capture dates, thumbnails,
    /// or fingerprints.
    func fetchDeviceAssetMappings(
        account: AccountContext,
        deviceID: String
    ) async throws -> [ServerDeviceAssetMapping] {
        guard let baseURL = account.serverURL else {
            throw RemotePhotoLibraryError.notConnected
        }
        // Older persisted accounts do not have this capability field. Probe
        // them once as well: a 404 safely falls back to normal backup, while a
        // newly upgraded MyNAS works without requiring the user to reconnect.
        guard account.serverCapabilities.supportsDeviceAssetMappingRecovery != false else {
            throw RemotePhotoLibraryError.featureUnavailable
        }
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceID.isEmpty, normalizedDeviceID.count <= 200 else {
            throw RemotePhotoLibraryError.invalidResponse
        }

        var mappings: [ServerDeviceAssetMapping] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let requestURL = try deviceAssetMappingPageURL(
                baseURL: baseURL,
                deviceID: normalizedDeviceID,
                cursor: cursor,
                limit: 200
            )
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            let httpResponse = try validatedHTTPResponse(response, data: data)
            guard httpResponse.statusCode == 200 else {
                throw error(for: httpResponse.statusCode)
            }
            let page: ServerDeviceAssetMappingPage
            do {
                page = try decoder.decode(ServerDeviceAssetMappingPage.self, from: data)
            } catch {
                throw RemotePhotoLibraryError.invalidResponse
            }
            mappings.append(contentsOf: page.mappings)
            guard page.hasMore else { break }
            guard let nextCursor = page.nextCursor,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                throw RemotePhotoLibraryError.invalidResponse
            }
            cursor = nextCursor
        } while true

        return mappings
    }

    /// Moves only server-revalidated complete resource groups to the dedicated
    /// MyNAS Photos trash. It is intentionally a batch request: the backend
    /// validates every selected item before moving the first one.
    func moveBackupsToTrash(
        candidates: [PhotoBackupTrashCandidate],
        account: AccountContext
    ) async throws -> RemotePhotoTrashResult {
        guard let baseURL = account.serverURL else {
            throw RemotePhotoLibraryError.notConnected
        }
        guard !candidates.isEmpty, candidates.count <= 200 else {
            throw RemotePhotoLibraryError.invalidResponse
        }
        let requestURL = baseURL.appending(path: "api/v1/photos/assets")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(TrashRequest(items: candidates.map(TrashRequest.Item.init)))

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(response, data: data)
        guard httpResponse.statusCode == 200 else {
            throw error(for: httpResponse.statusCode)
        }
        do {
            return try decoder.decode(RemotePhotoTrashResult.self, from: data)
        } catch {
            throw RemotePhotoLibraryError.invalidResponse
        }
    }

    /// Used as compensation if iOS rejects its Photos-library deletion after
    /// MyNAS has already accepted the paired move to its own recycle area.
    func restoreBackups(
        assetIDs: [String],
        account: AccountContext
    ) async throws -> RemotePhotoRestoreResult {
        guard let baseURL = account.serverURL else {
            throw RemotePhotoLibraryError.notConnected
        }
        guard !assetIDs.isEmpty, assetIDs.count <= 200 else {
            throw RemotePhotoLibraryError.invalidResponse
        }
        let requestURL = baseURL.appending(path: "api/v1/photos/assets/restore")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(RestoreRequest(assetIDs: assetIDs))

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(response, data: data)
        guard httpResponse.statusCode == 200 else {
            throw error(for: httpResponse.statusCode)
        }
        do {
            return try decoder.decode(RemotePhotoRestoreResult.self, from: data)
        } catch {
            throw RemotePhotoLibraryError.invalidResponse
        }
    }

    func image(
        for asset: ServerPhotoAsset,
        kind: String,
        account: AccountContext
    ) async throws -> RemotePhotoImageResult {
        guard let derivative = asset.derivative(kind) else {
            throw RemotePhotoLibraryError.invalidResponse
        }
        guard let baseURL = account.serverURL else {
            throw RemotePhotoLibraryError.notConnected
        }
        let downloadURL = try resolvedDownloadURL(
            derivative.downloadURL,
            relativeTo: baseURL
        )
        let cache = try imageCacheURLs(
            account: account,
            asset: asset,
            derivative: derivative
        )
        let cachedData = try? Data(contentsOf: cache.data)
        let cachedEnvelope = try? loadImageEnvelope(from: cache.metadata)
        let cachedIsValid = cachedData.map {
            Self.sha256Hex($0) == derivative.sha256.lowercased()
        } ?? false

        if cachedIsValid,
           let cachedData,
           let cachedEnvelope,
           Date().timeIntervalSince(cachedEnvelope.fetchedAt) < imageFreshness {
            return RemotePhotoImageResult(
                data: cachedData,
                isUsingOfflineCache: false
            )
        }

        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if cachedIsValid, let eTag = cachedEnvelope?.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = try validatedHTTPResponse(response, data: data)
            if httpResponse.statusCode == 304, cachedIsValid, let cachedData {
                let refreshed = ImageCacheEnvelope(
                    eTag: cachedEnvelope?.eTag,
                    sha256: derivative.sha256,
                    fetchedAt: Date()
                )
                try persist(refreshed, to: cache.metadata)
                return RemotePhotoImageResult(
                    data: cachedData,
                    isUsingOfflineCache: false
                )
            }
            guard httpResponse.statusCode == 200 else {
                throw error(for: httpResponse.statusCode)
            }
            guard data.count <= maximumImageBytes,
                  Self.sha256Hex(data) == derivative.sha256.lowercased() else {
                throw RemotePhotoLibraryError.corruptedDownload
            }
            let envelope = ImageCacheEnvelope(
                eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
                sha256: derivative.sha256,
                fetchedAt: Date()
            )
            try persist(data, to: cache.data)
            try persist(envelope, to: cache.metadata)
            return RemotePhotoImageResult(data: data, isUsingOfflineCache: false)
        } catch {
            if cachedIsValid,
               let cachedData,
               Self.canUseOfflineCache(after: error) {
                return RemotePhotoImageResult(
                    data: cachedData,
                    isUsingOfflineCache: true
                )
            }
            throw error
        }
    }

    /// Returns a same-origin original-resource URL for AVFoundation. The player
    /// then issues HTTP Range requests itself; this method never downloads or
    /// persists the original file.
    func streamingURL(
        for resource: ServerPhotoResource,
        in asset: ServerPhotoAsset,
        account: AccountContext
    ) throws -> URL {
        guard asset.resources.contains(resource), let baseURL = account.serverURL else {
            throw account.serverURL == nil
                ? RemotePhotoLibraryError.notConnected
                : RemotePhotoLibraryError.invalidResource
        }
        return try resolvedDownloadURL(resource.downloadURL, relativeTo: baseURL)
    }

    /// Reads only the byte range requested by AVFoundation. Keeping this inside
    /// the actor makes video playback use the same Tailscale-safe URLSession as
    /// the metadata and derivative clients.
    func streamingData(
        for resource: ServerPhotoResource,
        in asset: ServerPhotoAsset,
        account: AccountContext,
        offset: Int64,
        length: Int64
    ) async throws -> RemotePhotoStreamResult {
        let downloadURL = try streamingURL(
            for: resource,
            in: asset,
            account: account
        )
        let safeOffset = max(offset, 0)
        let safeLength = max(length, 1)
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.setValue("video/*", forHTTPHeaderField: "Accept")
        request.setValue(
            "bytes=\(safeOffset)-\(safeOffset + safeLength - 1)",
            forHTTPHeaderField: "Range"
        )

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(response, data: data)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw error(for: httpResponse.statusCode)
        }
        return RemotePhotoStreamResult(
            data: data,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            contentLength: Self.contentLength(from: httpResponse, fallback: data.count),
            supportsByteRanges: httpResponse.statusCode == 206
                || httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        )
    }

    /// Advances the account-isolated `/changes` cursor. On first use it drains
    /// historical changes only to establish a baseline, so an existing library
    /// never opens with a misleading "new" badge.
    func synchronizeChanges(
        account: AccountContext
    ) async throws -> RemotePhotoChangeSyncResult {
        guard let baseURL = account.serverURL else {
            throw RemotePhotoLibraryError.notConnected
        }
        if account.serverCapabilities.supportsChangeFeed == false {
            return RemotePhotoChangeSyncResult(
                changeCount: 0,
                changedAssetIDs: [],
                isInitialSync: false,
                resetRequired: false
            )
        }

        let cacheURL = try changeCursorCacheURL(account: account)
        let cached = try? loadChangeCursorEnvelope(from: cacheURL)
        let isInitialSync = cached == nil
        var cursor = cached?.cursor
        var requestETag = cached?.eTag
        var allChanges: [ServerPhotoChange] = []

        while true {
            let requestURL = try changesURL(baseURL: baseURL, cursor: cursor, limit: 200)
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let requestETag {
                request.setValue(requestETag, forHTTPHeaderField: "If-None-Match")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw error
            }
            let httpResponse = try validatedHTTPResponse(response, data: data)
            if httpResponse.statusCode == 304 {
                return RemotePhotoChangeSyncResult(
                    changeCount: 0,
                    changedAssetIDs: [],
                    isInitialSync: false,
                    resetRequired: false
                )
            }
            guard httpResponse.statusCode == 200 else {
                throw error(for: httpResponse.statusCode)
            }

            let page: ServerPhotoChangePage
            do {
                page = try decoder.decode(ServerPhotoChangePage.self, from: data)
            } catch {
                throw RemotePhotoLibraryError.invalidResponse
            }
            if page.resetRequired {
                try? FileManager.default.removeItem(at: cacheURL)
                return RemotePhotoChangeSyncResult(
                    changeCount: 0,
                    changedAssetIDs: [],
                    isInitialSync: false,
                    resetRequired: true
                )
            }

            allChanges.append(contentsOf: page.changes)
            cursor = page.nextCursor
            requestETag = httpResponse.value(forHTTPHeaderField: "ETag")
            guard page.hasMore else { break }
            // ETags describe the cursor result page, so only the first request
            // can be conditional against a persisted ETag.
            requestETag = nil
        }

        guard let cursor else {
            throw RemotePhotoLibraryError.invalidResponse
        }
        try persist(
            ChangeCursorCacheEnvelope(cursor: cursor, eTag: requestETag),
            to: cacheURL
        )
        return RemotePhotoChangeSyncResult(
            changeCount: allChanges.count,
            changedAssetIDs: Set(allChanges.map(\.assetID)),
            isInitialSync: isInitialSync,
            resetRequired: false
        )
    }

    private func assetPageURL(
        baseURL: URL,
        cursor: String?,
        limit: Int
    ) throws -> URL {
        let endpoint = baseURL.appending(path: "api/v1/photos/assets")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        return url
    }

    private func deviceAssetMappingPageURL(
        baseURL: URL,
        deviceID: String,
        cursor: String?,
        limit: Int
    ) throws -> URL {
        let endpoint = baseURL.appending(path: "api/v1/photos/device-asset-mappings")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        var queryItems = [
            URLQueryItem(name: "deviceID", value: deviceID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        return url
    }

    private func changesURL(
        baseURL: URL,
        cursor: String?,
        limit: Int
    ) throws -> URL {
        let endpoint = baseURL.appending(path: "api/v1/photos/changes")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        return url
    }

    private func resolvedDownloadURL(
        _ relativePath: String,
        relativeTo baseURL: URL
    ) throws -> URL {
        guard let url = URL(string: relativePath, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              (url.port ?? 443) == (baseURL.port ?? 443),
              url.user == nil,
              url.password == nil else {
            throw RemotePhotoLibraryError.invalidServerURL
        }
        return url
    }

    private func validatedHTTPResponse(
        _ response: URLResponse,
        data: Data
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw RemotePhotoLibraryError.invalidResponse
        }
        if response.statusCode == 401 {
            throw RemotePhotoLibraryError.unauthorized
        }
        if response.statusCode != 304 {
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased() ?? ""
            let prefix = String(data: data.prefix(50), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if contentType.contains("text/html")
                || prefix.hasPrefix("<!doctype html")
                || prefix.hasPrefix("<html") {
                throw RemotePhotoLibraryError.invalidResponse
            }
        }
        return response
    }

    private func error(for statusCode: Int) -> RemotePhotoLibraryError {
        if statusCode == 401 { return .unauthorized }
        if statusCode == 409 { return .backupTrashRejected }
        return .serverRejected(statusCode)
    }

    private nonisolated struct TrashRequest: Encodable, Sendable {
        let items: [Item]

        nonisolated struct Item: Encodable, Sendable {
            let assetID: String
            let deviceID: String
            let localIdentifier: String
            let sourceModificationDate: String

            init(_ candidate: PhotoBackupTrashCandidate) {
                assetID = candidate.assetID
                deviceID = candidate.deviceID
                localIdentifier = candidate.localIdentifier
                sourceModificationDate = candidate.sourceModificationDate
            }
        }
    }

    private nonisolated struct RestoreRequest: Encodable, Sendable {
        let assetIDs: [String]
    }

    private func metadataCacheURL(
        account: AccountContext,
        cursor: String?
    ) throws -> URL {
        let directory = try directories.directory(for: account, kind: .metadata)
        let key = Self.sha256Hex(Data((cursor ?? "first-page").utf8))
        return directory.appendingPathComponent("remote-assets-\(key).json")
    }

    private func changeCursorCacheURL(account: AccountContext) throws -> URL {
        let directory = try directories.directory(for: account, kind: .metadata)
        return directory.appendingPathComponent("remote-changes-cursor.json")
    }

    private func imageCacheURLs(
        account: AccountContext,
        asset: ServerPhotoAsset,
        derivative: ServerPhotoDerivative
    ) throws -> (data: URL, metadata: URL) {
        let kind: CacheDirectoryKind = derivative.kind == "preview" ? .previews : .thumbnails
        let directory = try directories.directory(for: account, kind: kind)
        let keyMaterial = "\(asset.id)|\(asset.version)|\(derivative.kind)|\(derivative.sha256)"
        let key = Self.sha256Hex(Data(keyMaterial.utf8))
        return (
            directory.appendingPathComponent("\(key).image"),
            directory.appendingPathComponent("\(key).json")
        )
    }

    private func loadMetadataEnvelope(from url: URL) throws -> MetadataCacheEnvelope {
        try decoder.decode(MetadataCacheEnvelope.self, from: Data(contentsOf: url))
    }

    private func loadImageEnvelope(from url: URL) throws -> ImageCacheEnvelope {
        try decoder.decode(ImageCacheEnvelope.self, from: Data(contentsOf: url))
    }

    private func loadChangeCursorEnvelope(from url: URL) throws -> ChangeCursorCacheEnvelope {
        try decoder.decode(ChangeCursorCacheEnvelope.self, from: Data(contentsOf: url))
    }

    private func persist<Value: Encodable>(_ value: Value, to url: URL) throws {
        try persist(encoder.encode(value), to: url)
    }

    private func persist(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func contentLength(
        from response: HTTPURLResponse,
        fallback: Int
    ) -> Int64 {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last,
           let byteCount = Int64(total) {
            return byteCount
        }
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return Int64(fallback)
    }

    private static func canUseOfflineCache(after error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                    .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return true
            default:
                return false
            }
        }
        if case RemotePhotoLibraryError.serverRejected(let status) = error {
            return status == 408 || status == 429 || status >= 500
        }
        return false
    }
}
