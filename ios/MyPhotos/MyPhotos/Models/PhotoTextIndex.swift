import Foundation

/// A locally retained OCR result. The text is sensitive user data, so it is
/// stored only after the separate I3 consent and always under the current
/// account's protected cache namespace.
nonisolated struct PhotoTextIndexRecord: Identifiable, Codable, Equatable, Sendable {
    let assetID: String
    let sourceVersion: String
    let processorRevision: String
    let recognizedText: String
    let indexedAt: Date

    var id: String { assetID }
}

nonisolated struct PhotoTextIndexStatus: Equatable, Sendable {
    let isEnabled: Bool
    let indexedAssetCount: Int
    let lastSynchronizedAt: Date?
    let needsRebuild: Bool
    /// A prior OCR permission did not include downloading iCloud photos. Its
    /// records stay unreadable until the owner explicitly accepts the new
    /// scope, at which point the old index is replaced.
    let requiresICloudDownloadConsent: Bool

    static let disabled = PhotoTextIndexStatus(
        isEnabled: false,
        indexedAssetCount: 0,
        lastSynchronizedAt: nil,
        needsRebuild: false,
        requiresICloudDownloadConsent: false
    )
}

/// A value-only OCR output. It deliberately carries no image, thumbnail,
/// file URL, bounding box or Vision object.
nonisolated struct PhotoTextRecognitionOutput: Equatable, Sendable {
    let assetID: String
    let recognizedText: String
}

nonisolated struct PhotoTextIndexSyncResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let removedCount: Int
    let unchangedCount: Int
    /// Images that could not currently be rendered after requesting their
    /// iCloud photo download are left for a later automatic or manual retry.
    let deferredAssetCount: Int
    let status: PhotoTextIndexStatus
}

nonisolated enum PhotoTextIndexError: LocalizedError, Equatable, Sendable {
    case pixelAnalysisNotAllowed
    case notEnabled
    case corruptedIndex
    case accountIdentityMismatch
    case unsupportedSchema(Int)
    case unsupportedConsentRevision(String)
    case unsafeStoragePath
    case invalidRecognitionOutput
    case recognizedTextTooLarge

    var errorDescription: String? {
        switch self {
        case .pixelAnalysisNotAllowed:
            "请先允许当前账号进行端侧像素分析。"
        case .notEnabled:
            "请先明确允许当前账号建立本地 OCR 文字索引。"
        case .corruptedIndex:
            "当前账号的本地 OCR 文字索引已损坏。请删除后重新建立。"
        case .accountIdentityMismatch:
            "本地 OCR 文字索引不属于当前账号，已拒绝读取。"
        case .unsupportedSchema:
            "本地 OCR 文字索引版本不受支持。请删除后重新建立。"
        case .unsupportedConsentRevision:
            "本地 OCR 文字索引许可版本不受支持。请重新确认许可。"
        case .unsafeStoragePath:
            "本地 OCR 文字索引的存储路径不安全，已拒绝访问。"
        case .invalidRecognitionOutput:
            "OCR 结果与当前本地图库不匹配，已拒绝保存。"
        case .recognizedTextTooLarge:
            "单张照片的 OCR 文字过长，已拒绝保存。"
        }
    }
}

nonisolated struct PhotoTextIndexSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let processorRevision: String
    let consentRevision: String
    let accountID: String
    let serverID: String
    let userID: String
    let lastSynchronizedAt: Date?
    let records: [PhotoTextIndexRecord]
}
