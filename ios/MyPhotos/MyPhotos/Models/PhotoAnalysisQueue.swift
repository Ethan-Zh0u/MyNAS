import Foundation

/// A minimal, local-only work item for a later pixel-analysis phase. I2 must
/// never persist image/video bytes or derived model data: the PhotoKit ID and
/// a metadata-derived source version are sufficient to decide whether a later
/// worker needs to revisit the asset.
nonisolated struct PhotoAnalysisQueueItem: Identifiable, Codable, Equatable, Sendable {
    let assetID: String
    let sourceVersion: String
    let queuedAt: Date

    var id: String { assetID }
}

nonisolated struct PhotoAnalysisQueueStatus: Equatable, Sendable {
    let isPixelAnalysisAllowed: Bool
    let pendingAssetCount: Int
    let lastPreparedAt: Date?

    static let disabled = PhotoAnalysisQueueStatus(
        isPixelAnalysisAllowed: false,
        pendingAssetCount: 0,
        lastPreparedAt: nil
    )
}

nonisolated struct PhotoAnalysisQueueSyncResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let removedCount: Int
    let unchangedCount: Int
    let status: PhotoAnalysisQueueStatus
}

nonisolated enum PhotoAnalysisQueueError: LocalizedError, Equatable, Sendable {
    case pixelAnalysisNotAllowed
    case corruptedQueue
    case accountIdentityMismatch
    case unsupportedSchema(Int)
    case unsupportedConsentRevision(String)
    case unsafeStoragePath

    var errorDescription: String? {
        switch self {
        case .pixelAnalysisNotAllowed:
            "请先明确允许当前账号进行端侧像素分析。"
        case .corruptedQueue:
            "当前账号的端侧分析队列已损坏。请删除后重新建立。"
        case .accountIdentityMismatch:
            "端侧分析队列不属于当前账号，已拒绝读取。"
        case .unsupportedSchema:
            "端侧分析队列版本不受支持。请删除后重新建立。"
        case .unsupportedConsentRevision:
            "端侧像素分析许可版本不受支持。请重新确认许可。"
        case .unsafeStoragePath:
            "端侧分析队列的存储路径不安全，已拒绝访问。"
        }
    }
}

nonisolated struct PhotoAnalysisQueueSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let consentRevision: String
    let accountID: String
    let serverID: String
    let userID: String
    let lastPreparedAt: Date?
    let items: [PhotoAnalysisQueueItem]
}
