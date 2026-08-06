import Foundation

/// Destructive MyNAS actions are fail-closed. A saved `.ts.net` address only
/// proves that an account was connected in the past; it does not prove that
/// Tailscale can reach that server now.
nonisolated enum MyNASRemoteMutationAvailability: Equatable, Sendable {
    case checking
    case available
    case tailscaleUnavailable

    var allowsRemoteMutation: Bool {
        self == .available
    }

    var statusText: String? {
        switch self {
        case .checking:
            "正在检查 Tailscale 连接…"
        case .available:
            nil
        case .tailscaleUnavailable:
            "Tailscale 未连接，无法删除 MyNAS 文件。请先连接 Tailscale，并确认 MyNAS 在线。"
        }
    }
}

enum MyNASRemoteMutationPreflightError: LocalizedError {
    case tailscaleUnavailable

    var errorDescription: String? {
        "Tailscale 未连接，无法删除 MyNAS 文件。请先连接 Tailscale，并确认 MyNAS 在线。"
    }
}

/// Uses the existing authenticated MyNAS health endpoint as proof that the
/// private Tailscale route is usable. The short timeout keeps a destructive
/// control from appearing active for a long time after Tailscale disconnects.
struct MyNASRemoteMutationPreflight {
    private let connectionService: MyNASConnectionService

    init(connectionService: MyNASConnectionService? = nil) {
        if let connectionService {
            self.connectionService = connectionService
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        self.connectionService = MyNASConnectionService(
            session: URLSession(configuration: configuration)
        )
    }

    func availability(for account: AccountContext) async -> MyNASRemoteMutationAvailability {
        guard let serverURL = account.serverURL else {
            return .tailscaleUnavailable
        }
        do {
            _ = try await connectionService.health(from: serverURL)
            return .available
        } catch {
            return .tailscaleUnavailable
        }
    }

    func requireAvailable(for account: AccountContext) async throws {
        guard await availability(for: account).allowsRemoteMutation else {
            throw MyNASRemoteMutationPreflightError.tailscaleUnavailable
        }
    }
}
