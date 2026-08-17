import Foundation

/// A value-only result from an on-device semantic image encoder. The image is
/// deliberately absent: it must be released before this crosses into storage.
nonisolated struct LocalSemanticEmbeddingOutput: Equatable, Sendable {
    let assetID: String
    let embedding: LocalEmbeddingVector
}

nonisolated struct PhotoSemanticIndexStatus: Equatable, Sendable {
    let isEnabled: Bool
    let indexedAssetCount: Int
    let lastSynchronizedAt: Date?
    let modelProfile: LocalEmbeddingModelProfile?

    static let disabled = PhotoSemanticIndexStatus(
        isEnabled: false,
        indexedAssetCount: 0,
        lastSynchronizedAt: nil,
        modelProfile: nil
    )
}

nonisolated struct PhotoSemanticIndexSyncResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let removedCount: Int
    let unchangedCount: Int
    /// Current static images whose image bytes are not available to the model
    /// yet. They have no stale vector left in the index.
    let deferredAssetCount: Int
    let status: PhotoSemanticIndexStatus
}

nonisolated enum PhotoSemanticIndexError: LocalizedError, Equatable, Sendable {
    case pixelAnalysisNotAllowed
    case notEnabled
    case corruptedIndex
    case accountIdentityMismatch
    case unsupportedSchema(Int)
    case unsupportedConsentRevision(String)
    case modelProfileMismatch
    case invalidEmbeddingOutput
    case unsafeStoragePath

    var errorDescription: String? {
        switch self {
        case .pixelAnalysisNotAllowed:
            "请先允许当前账号进行端侧像素分析。"
        case .notEnabled:
            "请先明确允许当前账号建立本地语义索引。"
        case .corruptedIndex:
            "当前账号的本地语义索引已损坏。请删除后重新建立。"
        case .accountIdentityMismatch:
            "本地语义索引不属于当前账号，已拒绝读取。"
        case .unsupportedSchema:
            "本地语义索引版本不受支持。请删除后重新建立。"
        case .unsupportedConsentRevision:
            "本地语义索引许可版本不受支持。请重新确认许可。"
        case .modelProfileMismatch:
            "本地语义索引与当前模型不一致，必须明确重建。"
        case .invalidEmbeddingOutput:
            "模型返回的语义向量与当前本地图库不匹配，已拒绝保存。"
        case .unsafeStoragePath:
            "本地语义索引的存储路径不安全，已拒绝访问。"
        }
    }
}

nonisolated struct PhotoSemanticIndexSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let consentRevision: String
    let accountID: String
    let serverID: String
    let userID: String
    let modelProfile: LocalEmbeddingModelProfile
    let lastSynchronizedAt: Date?
    let records: [LocalPhotoEmbeddingRecord]
}
