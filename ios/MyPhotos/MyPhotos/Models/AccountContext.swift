import Foundation
import Combine

/// The identity boundary for every future network request, transfer, cache entry, and database row.
struct AccountContext: Identifiable, Codable, Hashable, Sendable {
    let accountID: String
    let serverID: String
    let serverURL: URL?
    let userID: String
    let authenticationIdentity: String
    var displayName: String
    var avatarVersion: String?
    var selectedVolumeID: String?
    var serverCapabilities: ServerCapabilities
    var availableVolumes: [MyNASVolume]
    var encryptionNamespace: String?

    var id: String { accountID }

    /// A stable, filesystem-safe namespace. It must never be shared by different accounts.
    var cacheNamespace: String {
        "\(serverID.cachePathComponent)/\(userID.cachePathComponent)"
    }

    static let localOnly = AccountContext(
        accountID: "local-library",
        serverID: "local-device",
        serverURL: nil,
        userID: "local-user",
        authenticationIdentity: "local-only",
        displayName: "MyNAS Photos",
        avatarVersion: nil,
        selectedVolumeID: nil,
        serverCapabilities: .localOnly,
        availableVolumes: [],
        encryptionNamespace: nil
    )

    var isLocalOnly: Bool {
        serverURL == nil
    }
}

struct ServerCapabilities: Codable, Hashable, Sendable {
    var apiVersion: String?
    var supportsPhotoAssets: Bool
    var supportsBackgroundTransfers: Bool
    var supportsLivePhotos: Bool
    var backupStateModelVersion: Int?
    var derivativePolicyVersion: String?
    var availableDerivativeRecipes: [String]?

    static let localOnly = ServerCapabilities(
        apiVersion: nil,
        supportsPhotoAssets: false,
        supportsBackgroundTransfers: false,
        supportsLivePhotos: false,
        backupStateModelVersion: nil,
        derivativePolicyVersion: nil,
        availableDerivativeRecipes: nil
    )
}

struct MyNASVolume: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let status: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let isDefault: Bool

    var isOnline: Bool {
        status == "online"
    }
}

enum CacheDirectoryKind: String, CaseIterable, Sendable {
    case thumbnails
    case previews
    case livePhotos = "live-photo"
    case metadata
    case searchIndex = "search-index"
    case temporaryDownloads = "temporary-downloads"
}

/// Owns the account-isolated directory convention. Cache eviction and downloads arrive in stage H.
struct CacheDirectoryProvider {
    private let fileManager = FileManager.default

    func directory(for account: AccountContext, kind: CacheDirectoryKind) throws -> URL {
        let root = try applicationSupportRoot()
        let directory = root
            .appendingPathComponent("AppCache", isDirectory: true)
            .appendingPathComponent(account.serverID.cachePathComponent, isDirectory: true)
            .appendingPathComponent(account.userID.cachePathComponent, isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func rootDirectory(for account: AccountContext) throws -> URL {
        let root = try applicationSupportRoot()
        let directory = root
            .appendingPathComponent("AppCache", isDirectory: true)
            .appendingPathComponent(account.serverID.cachePathComponent, isDirectory: true)
            .appendingPathComponent(account.userID.cachePathComponent, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func applicationSupportRoot() throws -> URL {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }
}

/// Kept intentionally as an interface only. Remote asset reads arrive in stage E.
protocol StorageProvider: Sendable {
    var providerID: String { get }
    func authenticate(account: AccountContext) async throws
    func listAssets(cursor: String?) async throws -> ServerAssetPage
    func upload(_ request: StorageUploadRequest) async throws
    func resumeUpload(jobID: String) async throws
    func download(assetID: String) async throws -> URL
    func delete(assetID: String) async throws
    func quota() async throws -> StorageQuota
    func capabilities() async throws -> ServerCapabilities
}

struct ServerAssetPage: Sendable {
    let nextCursor: String?
}

struct StorageUploadRequest: Sendable {
    let accountID: String
    let localIdentifier: String
}

struct StorageQuota: Sendable {
    let usedBytes: Int64
    let availableBytes: Int64
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [AccountContext]
    @Published private(set) var current: AccountContext
    private let persistence: AccountPersistenceStore

    init(
        current: AccountContext? = nil,
        persistence: AccountPersistenceStore? = nil
    ) {
        let persistence = persistence ?? AccountPersistenceStore()
        self.persistence = persistence

        if let current {
            accounts = current.isLocalOnly ? [.localOnly] : [.localOnly, current]
            self.current = current
            return
        }

        let snapshot = try? persistence.load()
        let remoteAccounts = snapshot?.accounts.filter { !$0.isLocalOnly } ?? []
        let restoredAccounts = [.localOnly] + remoteAccounts
        accounts = restoredAccounts
        self.current = restoredAccounts.first { $0.accountID == snapshot?.currentAccountID } ?? .localOnly
    }

    func activate(_ account: AccountContext) {
        guard accounts.contains(where: { $0.accountID == account.accountID }) else { return }
        current = account
        persist()
    }

    func saveConnectedAccount(_ account: AccountContext) {
        if let index = accounts.firstIndex(where: { $0.accountID == account.accountID }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        current = account
        persist()
    }

    func selectVolume(_ volumeID: String, for accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.accountID == accountID }),
              accounts[index].availableVolumes.contains(where: { $0.id == volumeID }) else {
            return
        }
        accounts[index].selectedVolumeID = volumeID
        if current.accountID == accountID {
            current = accounts[index]
        }
        persist()
    }

    func remove(_ account: AccountContext) {
        guard !account.isLocalOnly else { return }
        accounts.removeAll { $0.accountID == account.accountID }
        if current.accountID == account.accountID {
            current = .localOnly
        }
        persist()
    }

    private func persist() {
        try? persistence.save(
            AccountPersistenceSnapshot(
                currentAccountID: current.accountID,
                accounts: accounts.filter { !$0.isLocalOnly }
            )
        )
    }
}

private extension String {
    var cachePathComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return encoded.isEmpty ? "unknown" : String(encoded.prefix(120))
    }
}
