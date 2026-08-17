import Combine
import Foundation

/// Queries the optional, account-scoped semantic index from the Photos-home
/// search sheet. The Qwen runtime is created only after an explicit semantic
/// index exists and the user enters a nonempty query; installing a model alone
/// therefore never loads photo vectors or starts inference.
@MainActor
final class LocalSemanticSearchViewModel: ObservableObject {
    @Published private(set) var status: PhotoSemanticIndexStatus = .disabled
    @Published private(set) var results: [LocalSemanticSearchHit] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let modelStore: LocalSemanticModelStore
    private let semanticStore: PhotoSemanticIndexStore
    private var activeAccountIdentity: String?
    private var activeQuery = ""
    private var searchTask: Task<Void, Never>?
    private var runtime: (identity: String, engine: LocalMNNQwen3VLEmbeddingEngine)?

    init(
        modelStore: LocalSemanticModelStore = LocalSemanticModelStore(),
        semanticStore: PhotoSemanticIndexStore = PhotoSemanticIndexStore()
    ) {
        self.modelStore = modelStore
        self.semanticStore = semanticStore
    }

    var isRuntimeAvailable: Bool {
        MNNQwen3VLEmbeddingBridge.isRuntimeAvailable()
    }

    func load(account: AccountContext) async {
        let identity = Self.identity(for: account)
        let didChangeAccount = activeAccountIdentity != identity
        activeAccountIdentity = identity
        if didChangeAccount {
            searchTask?.cancel()
            searchTask = nil
            activeQuery = ""
            results = []
            isWorking = false
            errorMessage = nil
            runtime = nil
        }

        do {
            let loaded = try await semanticStore.status(for: account)
            guard activeAccountIdentity == identity else { return }
            status = loaded
            guard loaded.isEnabled else {
                results = []
                runtime = nil
                return
            }
            startSearchIfNeeded(query: activeQuery, account: account)
        } catch {
            guard activeAccountIdentity == identity else { return }
            status = .disabled
            results = []
            runtime = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Debounces incremental search input. Earlier query tasks are cancelled
    /// before they reach the model, so typing does not perform an embedding
    /// inference for every intermediate character.
    func updateQuery(_ query: String, account: AccountContext) {
        activeQuery = query
        guard activeAccountIdentity == Self.identity(for: account) else { return }
        startSearchIfNeeded(query: query, account: account)
    }

    func clearError() {
        errorMessage = nil
    }

    private func startSearchIfNeeded(query: String, account: AccountContext) {
        searchTask?.cancel()
        searchTask = nil
        results = []
        errorMessage = nil

        let canonicalQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.isEnabled, !canonicalQuery.isEmpty else {
            isWorking = false
            return
        }
        guard isRuntimeAvailable else {
            isWorking = false
            errorMessage = LocalSemanticEmbeddingRuntimeError.runtimeUnavailable.errorDescription
            return
        }

        let identity = Self.identity(for: account)
        isWorking = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                guard let self, self.activeAccountIdentity == identity,
                      self.activeQuery == query else { return }

                let engine = try await self.loadRuntimeIfNeeded(for: identity)
                try Task.checkCancellation()
                let coordinator = LocalSemanticIndexCoordinator(
                    store: self.semanticStore,
                    engine: engine
                )
                let hits = try await coordinator.search(canonicalQuery, for: account)
                try Task.checkCancellation()
                guard self.activeAccountIdentity == identity,
                      self.activeQuery == query else { return }
                self.results = hits
                self.isWorking = false
                self.searchTask = nil
            } catch is CancellationError {
                guard let self, self.activeAccountIdentity == identity,
                      self.activeQuery == query else { return }
                self.isWorking = false
                self.searchTask = nil
            } catch {
                guard let self, self.activeAccountIdentity == identity,
                      self.activeQuery == query else { return }
                self.results = []
                self.isWorking = false
                self.searchTask = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadRuntimeIfNeeded(
        for identity: String
    ) async throws -> LocalMNNQwen3VLEmbeddingEngine {
        if let runtime, runtime.identity == identity { return runtime.engine }
        let loaded = try await LocalMNNQwen3VLEmbeddingEngine.load(
            profile: LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Profile,
            modelStore: modelStore
        )
        runtime = (identity, loaded)
        return loaded
    }

    private static func identity(for account: AccountContext) -> String {
        "\(account.accountID)|\(account.serverID)|\(account.userID)"
    }
}
