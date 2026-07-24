import Foundation

struct AccountPersistenceSnapshot: Codable, Sendable {
    let currentAccountID: String
    let accounts: [AccountContext]
}

/// MyNAS Photos has no app-owned password or token. This store contains only connection metadata.
struct AccountPersistenceStore {
    private let fileManager: FileManager
    private let explicitURL: URL?

    init(fileManager: FileManager = .default, explicitURL: URL? = nil) {
        self.fileManager = fileManager
        self.explicitURL = explicitURL
    }

    func load() throws -> AccountPersistenceSnapshot? {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AccountPersistenceSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: AccountPersistenceSnapshot) throws {
        let url = try storageURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func storageURL() throws -> URL {
        if let explicitURL {
            return explicitURL
        }
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }
}
