import Foundation

/// The runtime family expected by a downloaded on-device semantic model. This
/// is deliberately explicit so a package for one runtime can never be handed
/// to a different inference adapter.
nonisolated enum LocalSemanticModelRuntime: String, Codable, Equatable, Sendable {
    case mnnQwen3VLEmbedding

    fileprivate var requiredRuntimeFiles: Set<String> {
        switch self {
        case .mnnQwen3VLEmbedding:
            [
                "config.json",
                "embedding.mnn",
                "embedding.mnn.json",
                "embedding.mnn.weight",
                "embeddings_int8.bin",
                "llm_config.json",
                "tokenizer.mtok",
                "visual.mnn",
                "visual.mnn.weight",
            ]
        }
    }
}

/// One immutable file in a local model package. The manifest is distributed
/// separately from the package bytes and must be verified before activation.
nonisolated struct LocalSemanticModelPackageFile: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String

    init(relativePath: String, byteCount: Int64, sha256: String) throws {
        let canonicalPath = try Self.canonicalRelativePath(relativePath)
        let canonicalSHA256 = try Self.canonicalSHA256(sha256)
        guard byteCount >= 0 else {
            throw LocalSemanticModelPackageError.invalidManifest
        }
        self.relativePath = canonicalPath
        self.byteCount = byteCount
        self.sha256 = canonicalSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case byteCount
        case sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            byteCount: container.decode(Int64.self, forKey: .byteCount),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    fileprivate static func canonicalRelativePath(_ value: String) throws -> String {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = canonical.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !canonical.isEmpty,
              canonical.count <= 240,
              !canonical.hasPrefix("/"),
              components.count <= 8,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw LocalSemanticModelPackageError.invalidManifest
        }
        return canonical
    }

    fileprivate static func canonicalSHA256(_ value: String) throws -> String {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard canonical.count == 64,
              canonical.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw LocalSemanticModelPackageError.invalidManifest
        }
        return canonical
    }
}

/// The complete integrity contract for one locally installed semantic model.
/// It is global to the app so multiple accounts can share one verified model;
/// account-specific photo vectors remain in their own deletion namespace.
nonisolated struct LocalSemanticModelPackageManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let runtime: LocalSemanticModelRuntime
    let profile: LocalEmbeddingModelProfile
    let files: [LocalSemanticModelPackageFile]

    init(
        runtime: LocalSemanticModelRuntime,
        profile: LocalEmbeddingModelProfile,
        files: [LocalSemanticModelPackageFile]
    ) throws {
        let sortedFiles = files.sorted { $0.relativePath < $1.relativePath }
        let paths = sortedFiles.map(\.relativePath)
        guard !sortedFiles.isEmpty,
              Set(paths).count == paths.count,
              runtime.requiredRuntimeFiles.isSubset(of: Set(paths)),
              Self.isSupportedProfile(profile, for: runtime),
              !paths.contains(LocalSemanticModelInstallationEnvelope.filename),
              (try? Self.totalByteCount(of: sortedFiles)) != nil else {
            throw LocalSemanticModelPackageError.invalidManifest
        }
        schemaVersion = Self.schemaVersion
        self.runtime = runtime
        self.profile = profile
        self.files = sortedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runtime
        case profile
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw LocalSemanticModelPackageError.unsupportedSchema(schemaVersion)
        }
        try self.init(
            runtime: container.decode(LocalSemanticModelRuntime.self, forKey: .runtime),
            profile: container.decode(LocalEmbeddingModelProfile.self, forKey: .profile),
            files: container.decode([LocalSemanticModelPackageFile].self, forKey: .files)
        )
    }

    var totalByteCount: Int64 {
        // Initializers reject overflow, so this is safe for every live value.
        (try? Self.totalByteCount(of: files)) ?? 0
    }

    fileprivate static func totalByteCount(of files: [LocalSemanticModelPackageFile]) throws -> Int64 {
        var total: Int64 = 0
        for file in files {
            let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
            guard !overflow else { throw LocalSemanticModelPackageError.invalidManifest }
            total = sum
        }
        return total
    }

    private static func isSupportedProfile(
        _ profile: LocalEmbeddingModelProfile,
        for runtime: LocalSemanticModelRuntime
    ) -> Bool {
        switch runtime {
        case .mnnQwen3VLEmbedding:
            profile.modelIdentifier.caseInsensitiveCompare("Qwen3-VL-Embedding-2B") == .orderedSame
                && profile.dimension == 2_048
                && profile.quantization.caseInsensitiveCompare("int8") == .orderedSame
        }
    }
}

nonisolated struct LocalSemanticModelInstallStatus: Equatable, Sendable {
    let isInstalled: Bool
    let profile: LocalEmbeddingModelProfile?
    let runtime: LocalSemanticModelRuntime?
    let byteCount: Int64
    let installedAt: Date?

    static let notInstalled = LocalSemanticModelInstallStatus(
        isInstalled: false,
        profile: nil,
        runtime: nil,
        byteCount: 0,
        installedAt: nil
    )
}

/// A verified package location for an inference adapter. The directory contains
/// model assets only, never photo pixels, vectors or account identifiers.
nonisolated struct LocalSemanticModelInstallation: Equatable, Sendable {
    let manifest: LocalSemanticModelPackageManifest
    let directoryURL: URL
    let installedAt: Date
}

nonisolated enum LocalSemanticModelPackageError: LocalizedError, Equatable, Sendable {
    case invalidManifest
    case unsupportedSchema(Int)
    case packageUnavailable
    case packageFileMissing(String)
    case packageFileInvalid(String)
    case corruptedInstallation
    case insufficientDiskSpace(requiredByteCount: Int64)
    case unsafeStoragePath

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "本地模型包清单无效，已拒绝安装。"
        case .unsupportedSchema:
            "本地模型包版本不受支持。"
        case .packageUnavailable:
            "所选本地模型包不可用。"
        case .packageFileMissing:
            "本地模型包缺少必要文件。"
        case .packageFileInvalid:
            "本地模型包的文件校验失败。"
        case .corruptedInstallation:
            "已安装的本地模型包损坏，请删除后重新下载。"
        case .insufficientDiskSpace:
            "iPhone 可用空间不足，无法安全安装本地模型。"
        case .unsafeStoragePath:
            "本地模型包的存储路径不安全，已拒绝访问。"
        }
    }
}

nonisolated struct LocalSemanticModelInstallationEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let filename = "installation.json"

    let schemaVersion: Int
    let manifest: LocalSemanticModelPackageManifest
    let installedAt: Date
}
