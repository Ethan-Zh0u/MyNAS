import Foundation

nonisolated struct PhotoSearchIndexRecord: Identifiable, Codable, Hashable, Sendable {
    let assetID: String
    let sourceVersion: String
    let modelRevision: String
    let mediaKind: LocalMediaKind
    let creationDate: Date?
    let isFavorite: Bool
    let isRAW: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let searchTerms: [String]
    let indexedAt: Date

    var id: String { assetID }

    var displayMediaName: String {
        isRAW ? "RAW / ProRAW 照片" : mediaKind.displayName
    }
}

nonisolated struct PhotoSearchIndexStatus: Equatable, Sendable {
    let isEnabled: Bool
    let indexedAssetCount: Int
    let lastSynchronizedAt: Date?
    let needsRebuild: Bool

    static let disabled = PhotoSearchIndexStatus(
        isEnabled: false,
        indexedAssetCount: 0,
        lastSynchronizedAt: nil,
        needsRebuild: false
    )
}

nonisolated struct PhotoSearchIndexSyncResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let removedCount: Int
    let unchangedCount: Int
    let status: PhotoSearchIndexStatus
}

nonisolated enum PhotoSearchIndexError: LocalizedError, Equatable, Sendable {
    case notEnabled
    case corruptedIndex
    case accountIdentityMismatch
    case unsupportedSchema(Int)
    case unsafeStoragePath

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            "请先为当前账号启用本地搜索索引。"
        case .corruptedIndex:
            "当前账号的本地搜索索引已损坏。请清除后重新建立。"
        case .accountIdentityMismatch:
            "本地搜索索引不属于当前账号，已拒绝读取。"
        case .unsupportedSchema:
            "本地搜索索引版本不受支持。请清除后重新建立。"
        case .unsafeStoragePath:
            "本地搜索索引的存储路径不安全，已拒绝访问。"
        }
    }
}

nonisolated struct PhotoSearchIndexSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let modelRevision: String
    let accountID: String
    let serverID: String
    let userID: String
    let lastSynchronizedAt: Date?
    let records: [PhotoSearchIndexRecord]
}
