import Foundation
import UIKit

/// Build lock for the runtime shipped with MyPhotos. The model package itself
/// is still independently verified by `LocalSemanticModelStore`; this lock
/// lets diagnostics distinguish a changing model revision from its native
/// executor revision.
nonisolated enum LocalSemanticMNNRuntimeLock {
    static let upstreamCommit = "75e53afe568f7b6fabb1adc34894fe9f331d52f8"
    static let frameworkVersion = "3.6.1"
    static let cpuThreadCount = 4

    // SHA-256 values of the release-build static MNN frameworks produced from
    // `upstreamCommit`. The delivery artifact has arm64 slices for iPhone and
    // Apple Silicon Simulator. Intel Simulator keeps the no-runtime fallback
    // so it never becomes a release requirement. These are supply-chain checks
    // for the separately versioned binary artifact, not photo or user data.
    static let deviceArm64SHA256 = "253bf287c59577e2bf30ae01d717d926044a3b3a1fc415271de35424879fd6bc"
    static let simulatorArm64SHA256 = "0a31c6957303af69dada2ae35e45456c2f68de4e00b296e04c4b005aa492695d"
}

nonisolated enum LocalSemanticEmbeddingRuntimeError: LocalizedError, Equatable, Sendable {
    case unsupportedInstallation
    case runtimeUnavailable
    case modelUnavailable
    case modelLoadFailed
    case inferenceFailed
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unsupportedInstallation:
            "当前本地模型包与语义运行时不兼容。"
        case .runtimeUnavailable:
            "本地语义运行时尚未安装。"
        case .modelUnavailable:
            "本地语义模型尚未安装或已损坏。"
        case .modelLoadFailed:
            "本地语义模型无法加载。"
        case .inferenceFailed:
            "本地语义模型未能生成有效向量。"
        case .invalidImage:
            "无法准备这张照片的本地语义缩略图。"
        }
    }
}

/// MNN's Objective-C++ object is not thread-safe. This box confines it to one
/// worker queue; the `@unchecked Sendable` conformance is sound because no
/// bridge access escapes that queue.
private final class LocalMNNEmbeddingRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.ethanzhou.MyPhotos.local-semantic-mnn",
        qos: .utility
    )
    private let modelDirectoryURL: URL
    private var bridge: MNNQwen3VLEmbeddingBridge?

    init(modelDirectoryURL: URL) {
        self.modelDirectoryURL = modelDirectoryURL
    }

    func embed(text: String) async throws -> LocalEmbeddingVector {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let bridge = try loadBridgeIfNeeded()
                    let values = try bridge.embedText(text)
                    continuation.resume(returning: try Self.vector(from: values))
                } catch let error as LocalSemanticEmbeddingRuntimeError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: Self.runtimeError(error as NSError))
                }
            }
        }
    }

    func embed(jpegData: Data) async throws -> LocalEmbeddingVector {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let bridge = try loadBridgeIfNeeded()
                    let values = try bridge.embedJPEGData(jpegData)
                    continuation.resume(returning: try Self.vector(from: values))
                } catch let error as LocalSemanticEmbeddingRuntimeError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: Self.runtimeError(error as NSError))
                }
            }
        }
    }

    private func loadBridgeIfNeeded() throws -> MNNQwen3VLEmbeddingBridge {
        if let bridge { return bridge }
        do {
            let created = try MNNQwen3VLEmbeddingBridge(modelDirectoryURL: modelDirectoryURL)
            bridge = created
            return created
        } catch {
            throw Self.runtimeError(error as NSError)
        }
    }

    private static func vector(from values: [NSNumber]) throws -> LocalEmbeddingVector {
        guard values.count == 2_048 else {
            throw LocalSemanticEmbeddingRuntimeError.inferenceFailed
        }
        return try LocalEmbeddingVector(normalizing: values.map(\.floatValue))
    }

    private static func runtimeError(_ nativeError: NSError?) -> LocalSemanticEmbeddingRuntimeError {
        switch nativeError?.code {
        case 1:
            .modelUnavailable
        case 2:
            .modelLoadFailed
        case 5:
            .runtimeUnavailable
        default:
            .inferenceFailed
        }
    }
}

/// Concrete on-device Qwen3-VL embedding engine. It deliberately uses CPU
/// with four threads: the iPhone 16 Pro spike showed it avoids Metal's roughly
/// 2 GB peak physical footprint while keeping bounded-thumbnail indexing fast.
@MainActor
final class LocalMNNQwen3VLEmbeddingEngine: LocalSemanticEmbeddingEngine {
    let modelProfile: LocalEmbeddingModelProfile
    private let runtime: LocalMNNEmbeddingRuntime

    init(installation: LocalSemanticModelInstallation) throws {
        // Only the exact app-owned catalog entry may reach native inference.
        // A later model update must arrive in a new app version with a new
        // profile revision, forcing vectors from the old executor/model pair
        // to be rebuilt instead of being compared across revisions.
        guard installation.manifest == LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Manifest else {
            throw LocalSemanticEmbeddingRuntimeError.unsupportedInstallation
        }
        guard MNNQwen3VLEmbeddingBridge.isRuntimeAvailable() else {
            throw LocalSemanticEmbeddingRuntimeError.runtimeUnavailable
        }
        modelProfile = installation.manifest.profile
        runtime = LocalMNNEmbeddingRuntime(modelDirectoryURL: installation.directoryURL)
    }

    static func load(
        profile: LocalEmbeddingModelProfile,
        modelStore: LocalSemanticModelStore = LocalSemanticModelStore()
    ) async throws -> LocalMNNQwen3VLEmbeddingEngine {
        guard let installation = try await modelStore.verifiedInstallation(for: profile) else {
            throw LocalSemanticEmbeddingRuntimeError.modelUnavailable
        }
        return try LocalMNNQwen3VLEmbeddingEngine(installation: installation)
    }

    func embed(text: String) async throws -> LocalEmbeddingVector {
        let canonical = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else {
            throw LocalSemanticEmbeddingRuntimeError.inferenceFailed
        }
        return try await runtime.embed(text: canonical)
    }

    func embed(image: UIImage) async throws -> LocalEmbeddingVector {
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
            throw LocalSemanticEmbeddingRuntimeError.invalidImage
        }
        return try await runtime.embed(jpegData: jpegData)
    }
}
