import Foundation

/// Downloads the one App-pinned semantic model from the currently paired
/// MyNAS. The response manifest is an availability check, never a source of
/// trust: the model store still verifies every byte against the hashes compiled
/// into this app before it activates anything.
actor MyNASSemanticModelClient {
    private static let httpOK = 200
    private let directories: CacheDirectoryProvider
    private let fileManager: FileManager

    init(
        directories: CacheDirectoryProvider = CacheDirectoryProvider(),
        fileManager: FileManager = .default
    ) {
        self.directories = directories
        self.fileManager = fileManager
    }

    func downloadPinnedQwen3VLEmbedding2BInt8(
        for account: AccountContext,
        into modelStore: LocalSemanticModelStore,
        progress: @escaping @MainActor @Sendable (LocalSemanticModelOperationStage) -> Void
    ) async throws -> LocalSemanticModelInstallStatus {
        guard let baseURL = account.serverURL else {
            throw MyNASSemanticModelDownloadError.notConnected
        }
        let origin = try trustedOrigin(from: baseURL)
        let session = makeSession(for: origin)
        defer { session.invalidateAndCancel() }

        let manifestURL = baseURL.appending(
            path: "api/v1/photos/models/qwen3-vl-embedding-2b/manifest"
        )
        var manifestRequest = URLRequest(url: manifestURL)
        manifestRequest.httpMethod = "GET"
        manifestRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (manifestData, manifestResponse) = try await session.data(for: manifestRequest)
        try validate(
            manifestResponse,
            expectedOrigin: origin,
            expectedStatus: Self.httpOK,
            responseData: manifestData
        )
        let remoteManifest: MyNASSemanticModelManifestResponse
        do {
            remoteManifest = try JSONDecoder().decode(
                MyNASSemanticModelManifestResponse.self,
                from: manifestData
            )
        } catch {
            throw MyNASSemanticModelDownloadError.invalidManifest
        }
        let pinnedManifest = LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Manifest
        guard remoteManifest.serverID == account.serverID,
              remoteManifest.modelID == "qwen3-vl-embedding-2b",
              remoteManifest.manifest == pinnedManifest else {
            throw MyNASSemanticModelDownloadError.invalidManifest
        }

        let sourceDirectory = try stagingDirectory(for: account)
        defer { try? fileManager.removeItem(at: sourceDirectory) }
        for (index, file) in pinnedManifest.files.enumerated() {
            await progress(.downloading(currentFile: index + 1, totalFiles: pinnedManifest.files.count))
            let url = baseURL.appending(
                path: "api/v1/photos/models/qwen3-vl-embedding-2b/files/\(file.relativePath)"
            )
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (downloadedURL, response) = try await session.download(for: request)
            try validate(response, expectedOrigin: origin, expectedStatus: Self.httpOK, responseData: nil)
            let values = try downloadedURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == file.byteCount else {
                throw MyNASSemanticModelDownloadError.invalidPackageFile(file.relativePath)
            }
            let destination = sourceDirectory.appendingPathComponent(file.relativePath, isDirectory: false)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: downloadedURL, to: destination)
        }

        await progress(.validatingDownloadedFiles)
        return try await modelStore.installPinnedQwen3VLEmbedding2BInt8(
            packageDirectory: sourceDirectory,
            progress: progress
        )
    }

    private func stagingDirectory(for account: AccountContext) throws -> URL {
        let root = try directories.directory(for: account, kind: .temporaryDownloads)
        let directory = root.appendingPathComponent(
            "semantic-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func trustedOrigin(from baseURL: URL) throws -> MyNASSemanticModelOrigin {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host?.lowercased(),
              host.hasSuffix(".ts.net"),
              host != "ts.net",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.port == nil || baseURL.port == 443 else {
            throw MyNASSemanticModelDownloadError.untrustedServer
        }
        return MyNASSemanticModelOrigin(host: host, port: baseURL.port ?? 443)
    }

    private func makeSession(for origin: MyNASSemanticModelOrigin) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 8 * 60 * 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(
            configuration: configuration,
            delegate: MyNASSemanticModelRedirectDelegate(expectedOrigin: origin),
            delegateQueue: nil
        )
    }

    private func validate(
        _ response: URLResponse,
        expectedOrigin: MyNASSemanticModelOrigin,
        expectedStatus: Int,
        responseData: Data?
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              finalURL.scheme?.lowercased() == "https",
              finalURL.host?.lowercased() == expectedOrigin.host,
              (finalURL.port ?? 443) == expectedOrigin.port else {
            throw MyNASSemanticModelDownloadError.untrustedServer
        }
        if httpResponse.statusCode == 401 {
            throw MyNASSemanticModelDownloadError.identityUnavailable
        }
        if httpResponse.statusCode == 404 {
            throw MyNASSemanticModelDownloadError.unavailable
        }
        guard httpResponse.statusCode == expectedStatus else {
            let serverMessage = responseData.flatMap {
                String(data: $0.prefix(240), encoding: .utf8)
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MyNASSemanticModelDownloadError.serverRejected(
                status: httpResponse.statusCode,
                message: serverMessage
            )
        }
    }
}

nonisolated private struct MyNASSemanticModelManifestResponse: Decodable, Sendable {
    let serverID: String
    let modelID: String
    let manifest: LocalSemanticModelPackageManifest
}

nonisolated private struct MyNASSemanticModelOrigin: Equatable, Sendable {
    let host: String
    let port: Int
}

private final class MyNASSemanticModelRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let expectedOrigin: MyNASSemanticModelOrigin

    init(expectedOrigin: MyNASSemanticModelOrigin) {
        self.expectedOrigin = expectedOrigin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == expectedOrigin.host,
              (url.port ?? 443) == expectedOrigin.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

nonisolated enum MyNASSemanticModelDownloadError: LocalizedError, Equatable, Sendable {
    case notConnected
    case untrustedServer
    case identityUnavailable
    case unavailable
    case invalidManifest
    case invalidPackageFile(String)
    case serverRejected(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "请先连接 MyNAS，再下载本地语义模型。"
        case .untrustedServer:
            "模型下载必须来自已配对的 MyNAS 私有 HTTPS 地址。"
        case .identityUnavailable:
            "MyNAS 无法确认当前 Tailscale 身份。"
        case .unavailable:
            "这台 MyNAS 尚未准备好本地语义模型，请先更新或安装模型包。"
        case .invalidManifest:
            "MyNAS 上的模型版本与此 App 不匹配，已拒绝下载。"
        case let .invalidPackageFile(path):
            "模型文件 \(path) 不完整，已停止安装。"
        case let .serverRejected(status, message):
            "MyNAS 拒绝了模型下载（\(status)）。\(message ?? "")"
        }
    }
}
