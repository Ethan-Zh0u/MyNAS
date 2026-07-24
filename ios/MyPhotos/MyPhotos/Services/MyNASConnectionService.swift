import Foundation

struct MyNASConnectionResult: Sendable {
    let account: AccountContext
}

struct MyNASPairingPayload: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let serverURL: String
    let serverID: String
}

struct MyNASHealthSnapshot: Equatable, Sendable {
    let serverVersion: String
    let temperatureC: Double?
}

enum MyNASConnectionError: LocalizedError {
    case invalidAddress(String)
    case tailscaleUnavailable
    case tailscaleIdentityMissing
    case serverTooOld
    case clientUpdateRequired(minimumVersion: String)
    case incompatibleResponse
    case serverRejected(status: Int, message: String)
    case serverIdentityChanged

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let reason):
            "MyNAS 地址无效：\(reason)"
        case .tailscaleUnavailable:
            "无法通过 Tailscale 找到 MyNAS。请确认 iPhone 上的 Tailscale 已连接、NAS 在线，并检查地址。"
        case .tailscaleIdentityMissing:
            "服务器没有收到 Tailscale 用户身份。请确认使用的是 Tailscale Serve 的 HTTPS 地址，而不是局域网 IP 或直接端口。"
        case .serverTooOld:
            "这台 MyNAS 尚未安装照片连接与备份接口，请先更新服务器。"
        case .clientUpdateRequired(let minimumVersion):
            "这台 MyNAS 要求 MyNAS Photos \(minimumVersion) 或更高版本，请先更新 App。"
        case .incompatibleResponse:
            "服务器返回了无法识别的数据，可能是版本不兼容。"
        case .serverRejected(let status, let message):
            "服务器拒绝连接（\(status)）：\(message)"
        case .serverIdentityChanged:
            "握手过程中服务器身份发生变化，连接已取消。"
        }
    }
}

struct MyNASConnectionService {
    private let session: URLSession
    private let clientVersion: String

    init(
        session: URLSession? = nil,
        clientVersion: String? = nil
    ) {
        self.clientVersion = clientVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // Tailscale Serve is reached directly inside the user's tailnet.
            // A loopback system proxy (common on development Macs and Simulator)
            // cannot route that private hostname and can terminate its TLS tunnel.
            // An explicit empty dictionary disables proxy discovery for this
            // MyNAS-only session without weakening HTTPS trust evaluation.
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration)
        }
    }

    func connect(
        address: String,
        expectedServerID: String? = nil
    ) async throws -> MyNASConnectionResult {
        let baseURL = try Self.normalizedBaseURL(from: address)

        let capabilityEnvelope: CapabilityEnvelope = try await get(
            "api/v1/photos/capabilities",
            from: baseURL
        )
        if let expectedServerID, capabilityEnvelope.serverID != expectedServerID {
            throw MyNASConnectionError.serverIdentityChanged
        }
        guard !Self.isVersion(clientVersion, lowerThan: capabilityEnvelope.minimumClientVersion) else {
            throw MyNASConnectionError.clientUpdateRequired(
                minimumVersion: capabilityEnvelope.minimumClientVersion
            )
        }
        guard capabilityEnvelope.supportsVolumes else {
            throw MyNASConnectionError.incompatibleResponse
        }
        let me: MeEnvelope = try await get("api/v1/photos/me", from: baseURL)
        guard capabilityEnvelope.serverID == me.serverID else {
            throw MyNASConnectionError.serverIdentityChanged
        }
        let volumeEnvelope: VolumeEnvelope = try await get(
            "api/v1/photos/volumes",
            from: baseURL
        )

        let volumes = volumeEnvelope.volumes
        let selectedVolume = volumes.first(where: { $0.isDefault && $0.isOnline })
            ?? volumes.first(where: \.isOnline)
            ?? volumes.first
        let account = AccountContext(
            accountID: "\(me.serverID):\(me.userID)",
            serverID: me.serverID,
            serverURL: baseURL,
            userID: me.userID,
            authenticationIdentity: me.authenticationIdentity,
            displayName: me.displayName,
            avatarVersion: me.avatarVersion,
            selectedVolumeID: selectedVolume?.id,
            serverCapabilities: ServerCapabilities(
                apiVersion: capabilityEnvelope.apiVersion,
                supportsPhotoAssets: capabilityEnvelope.features.photoAssets,
                supportsBackgroundTransfers: capabilityEnvelope.features.backgroundTransfers,
                supportsLivePhotos: capabilityEnvelope.features.livePhotos,
                backupStateModelVersion: capabilityEnvelope.backupStateModelVersion,
                derivativePolicyVersion: capabilityEnvelope.derivativePolicyVersion,
                availableDerivativeRecipes: capabilityEnvelope.derivativeRecipes
            ),
            availableVolumes: volumes,
            encryptionNamespace: nil
        )
        return MyNASConnectionResult(account: account)
    }

    func health(from baseURL: URL) async throws -> MyNASHealthSnapshot {
        let envelope: HealthEnvelope = try await get("api/v1/health", from: baseURL)
        guard envelope.ok else {
            throw MyNASConnectionError.incompatibleResponse
        }
        return MyNASHealthSnapshot(
            serverVersion: envelope.version,
            temperatureC: envelope.system?.temperatureC
        )
    }

    static func pairingPayload(from scannedValue: String) throws -> MyNASPairingPayload {
        guard let data = scannedValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MyNASPairingPayload.self, from: data),
              payload.format == "mynas-photos-pairing",
              payload.version == 1,
              !payload.serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MyNASConnectionError.invalidAddress("这不是有效的 MyNAS Photos 配对二维码")
        }
        let normalizedURL = try normalizedBaseURL(from: payload.serverURL)
        return MyNASPairingPayload(
            format: payload.format,
            version: payload.version,
            serverURL: normalizedURL.absoluteString,
            serverID: payload.serverID
        )
    }

    static func normalizedBaseURL(from rawValue: String) throws -> URL {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MyNASConnectionError.invalidAddress("请输入服务器地址")
        }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host.hasSuffix(".ts.net"),
              host != "ts.net" else {
            throw MyNASConnectionError.invalidAddress("应为 https://设备名.tailnet名.ts.net")
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MyNASConnectionError.invalidAddress("地址不能包含账号、查询参数或片段")
        }
        guard components.port == nil || components.port == 443 else {
            throw MyNASConnectionError.invalidAddress("Tailscale Serve 应使用标准 HTTPS 端口")
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw MyNASConnectionError.invalidAddress("请只填写服务器根地址")
        }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        guard let result = normalized.url else {
            throw MyNASConnectionError.invalidAddress("无法解析地址")
        }
        return result
    }

    private static func isVersion(_ version: String, lowerThan minimum: String) -> Bool {
        let left = version.split(separator: ".").map { Int($0) ?? 0 }
        let right = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue {
                return leftValue < rightValue
            }
        }
        return false
    }

    private func get<Response: Decodable>(_ path: String, from baseURL: URL) async throws -> Response {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                    .networkConnectionLost, .timedOut:
                throw MyNASConnectionError.tailscaleUnavailable
            default:
                throw error
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MyNASConnectionError.incompatibleResponse
        }
        if httpResponse.statusCode == 401 {
            throw MyNASConnectionError.tailscaleIdentityMissing
        }
        if httpResponse.statusCode == 404 {
            throw MyNASConnectionError.serverTooOld
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data.prefix(500), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
            throw MyNASConnectionError.serverRejected(
                status: httpResponse.statusCode,
                message: message
            )
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        let responsePrefix = String(data: data.prefix(100), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if contentType.contains("text/html")
            || responsePrefix.hasPrefix("<!doctype html")
            || responsePrefix.hasPrefix("<html") {
            // Older MyNAS versions send the SPA's index.html
            // with HTTP 200 for an unknown API path.
            throw MyNASConnectionError.serverTooOld
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MyNASConnectionError.incompatibleResponse
        }
    }
}

private struct CapabilityEnvelope: Decodable {
    let serverID: String
    let apiVersion: String
    let serverVersion: String
    let minimumClientVersion: String
    let backupStateModelVersion: Int?
    let derivativePolicyVersion: String?
    let features: FeatureEnvelope
    let derivativeRecipes: [String]
    let supportsVolumes: Bool
}

private struct HealthEnvelope: Decodable {
    let ok: Bool
    let version: String
    let system: SystemEnvelope?
}

private struct SystemEnvelope: Decodable {
    let temperatureC: Double?
}

private struct FeatureEnvelope: Decodable {
    let photoAssets: Bool
    let backgroundTransfers: Bool
    let livePhotos: Bool
}

private struct MeEnvelope: Decodable {
    let serverID: String
    let userID: String
    let authenticationIdentity: String
    let displayName: String
    let avatarVersion: String?
}

private struct VolumeEnvelope: Decodable {
    let volumes: [MyNASVolume]
}
