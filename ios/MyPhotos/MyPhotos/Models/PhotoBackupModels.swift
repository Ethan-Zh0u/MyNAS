import CryptoKit
import Foundation

enum PhotoBackupPreparationError: LocalizedError {
    case assetUnavailable
    case noResources
    case invalidResource

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            "照片资源已从本地图库移除或当前不可访问。"
        case .noResources:
            "这项媒体没有可备份的原始资源。"
        case .invalidResource:
            "照片资源的大小或校验信息无效。"
        }
    }
}

struct PreparedPhotoResource: Identifiable, Sendable {
    struct Draft: Sendable {
        let role: String
        let originalFilename: String
        let contentType: String
        let byteSize: Int64
        let sha256: String
        let fileURL: URL
    }

    let clientResourceID: String
    let role: String
    let originalFilename: String
    let contentType: String
    let byteSize: Int64
    let sha256: String
    let fileURL: URL

    var id: String { clientResourceID }
}

struct PreparedPhotoAsset: Sendable {
    let localAsset: LocalPhotoAsset
    let temporaryDirectory: URL
    let resources: [PreparedPhotoResource]
    let fingerprint: String

    init(
        localAsset: LocalPhotoAsset,
        temporaryDirectory: URL,
        resourceDrafts: [PreparedPhotoResource.Draft]
    ) {
        let sortedDrafts = resourceDrafts.sorted {
            if $0.role != $1.role { return $0.role < $1.role }
            if $0.sha256 != $1.sha256 { return $0.sha256 < $1.sha256 }
            if $0.byteSize != $1.byteSize { return $0.byteSize < $1.byteSize }
            return $0.originalFilename < $1.originalFilename
        }
        let resources = sortedDrafts.enumerated().map { index, draft in
            PreparedPhotoResource(
                clientResourceID: String(format: "resource-%03d", index),
                role: draft.role,
                originalFilename: draft.originalFilename,
                contentType: draft.contentType,
                byteSize: draft.byteSize,
                sha256: draft.sha256,
                fileURL: draft.fileURL
            )
        }
        self.localAsset = localAsset
        self.temporaryDirectory = temporaryDirectory
        self.resources = resources
        self.fingerprint = Self.manifestFingerprint(resources)
    }

    var totalBytes: Int64 {
        resources.reduce(0) { $0 + $1.byteSize }
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static func manifestFingerprint(_ resources: [PreparedPhotoResource]) -> String {
        var hasher = SHA256()
        for resource in resources.sorted(by: { $0.clientResourceID < $1.clientResourceID }) {
            let line = "\(resource.clientResourceID)\0\(resource.role)\0\(resource.sha256)\0\(resource.byteSize)\n"
            hasher.update(data: Data(line.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum PhotoBackupJobStatus: String, Codable, Sendable {
    case waiting
    case preparing
    case uploading
    case completed
    case failed

    var title: String {
        switch self {
        case .waiting: "等待中"
        case .preparing: "读取原始资源"
        case .uploading: "上传中"
        case .completed: "原件已安全上传"
        case .failed: "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: "clock"
        case .preparing: "doc.badge.gearshape"
        case .uploading: "arrow.up.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum PhotoSourceState: String, Codable, Sendable {
    case committed = "sourceCommitted"
}

enum PhotoDerivativeState: String, Codable, Sendable {
    case pending
    case processing
    case ready
    case failed
}

struct PhotoBackupJob: Identifiable, Codable, Sendable {
    let id: UUID
    let accountID: String
    let localIdentifier: String
    let mediaKind: LocalMediaKind
    let creationDate: Date?
    var sourceModificationDate: Date?
    var status: PhotoBackupJobStatus
    var totalBytes: Int64
    var uploadedBytes: Int64
    var resourceCount: Int
    var assetID: String?
    var sourceState: PhotoSourceState?
    var derivativeState: PhotoDerivativeState?
    var message: String?
    var updatedAt: Date

    var isBrowseReady: Bool {
        sourceState == .committed && derivativeState == .ready
    }

    var progress: Double {
        guard totalBytes > 0 else {
            return status == .completed ? 1 : 0
        }
        return min(1, max(0, Double(uploadedBytes) / Double(totalBytes)))
    }
}

struct PhotoBackupProgressSnapshot: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let isRunning: Bool
    let uploadedBytes: Int64
    let totalBytes: Int64
    let sizePendingCount: Int

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }

    var percentage: Int {
        Int((fractionCompleted * 100).rounded())
    }

    var countText: String {
        "\(completedCount) / \(totalCount)"
    }

    var hasCompleteSize: Bool {
        totalCount > 0 && sizePendingCount == 0
    }
}

enum FileSHA256 {
    nonisolated static func digest(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
