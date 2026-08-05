import Foundation

nonisolated enum ServerPhotoMediaKind: String, Codable, Hashable, Sendable {
    case photo
    case video
    case livePhoto
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .photo, .unknown: "照片"
        case .video: "视频"
        case .livePhoto: "实况照片"
        }
    }

    var systemImage: String {
        switch self {
        case .photo, .unknown: "photo"
        case .video: "video"
        case .livePhoto: "livephoto"
        }
    }
}

nonisolated struct ServerPhotoResource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let resourceRole: String
    let originalFilename: String
    let contentType: String
    let byteSize: Int64
    let sha256: String
    let downloadURL: String

    var isVideo: Bool {
        let role = resourceRole.lowercased()
        let type = contentType.lowercased()
        return role.contains("video")
            || type.hasPrefix("video/")
            || type.contains("quicktime")
            || type.contains("mpeg-4")
            || type.contains("mp4")
    }

    var displayRole: String {
        switch resourceRole {
        case "photo", "fullSizePhoto": "静态照片"
        case "pairedVideo", "fullSizePairedVideo": "实况视频"
        case "video", "fullSizeVideo": "视频"
        case "alternatePhoto": "替代照片"
        case "adjustmentBasePhoto": "编辑基底"
        case "adjustmentData": "编辑数据"
        default: resourceRole
        }
    }
}

nonisolated struct ServerPhotoDerivative: Codable, Hashable, Sendable {
    let kind: String
    let recipeID: String
    let recipeVersion: String
    let contentType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteSize: Int64
    let sha256: String
    let downloadURL: String
}

nonisolated struct ServerPhotoAsset: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let volumeID: String
    let mediaType: ServerPhotoMediaKind
    let captureDate: String?
    let modificationDate: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let favorite: Bool
    let sourceState: String
    let derivativeState: String
    let derivativeRecipeVersion: String
    let derivativeError: String?
    let browseReady: Bool
    let version: String
    /// Owner-scoped, anonymous aggregate counts for the exact resource-group
    /// match. They intentionally omit device IDs, local identifiers, and the
    /// content fingerprint itself.
    let exactContentDeviceCount: Int?
    let exactContentMappingCount: Int?
    /// Owner-scoped transition counts recorded after the same device's stable
    /// PhotoKit local identifier moved to a new complete resource group.
    let previousVersionCount: Int?
    let nextVersionCount: Int?
    let resources: [ServerPhotoResource]
    let derivatives: [ServerPhotoDerivative]

    var isRAW: Bool {
        resources.contains { resource in
            let filename = resource.originalFilename.lowercased()
            let contentType = resource.contentType.lowercased()
            return filename.hasSuffix(".dng")
                || contentType.contains("dng")
                || contentType.contains("raw")
        }
    }

    var displayMediaName: String {
        isRAW ? "RAW / ProRAW 照片" : mediaType.displayName
    }

    func derivative(_ kind: String) -> ServerPhotoDerivative? {
        derivatives.first { $0.kind == kind }
    }

    var videoResource: ServerPhotoResource? {
        resources.first { $0.resourceRole == "video" }
            ?? resources.first(where: \.isVideo)
    }

    var pairedVideoResource: ServerPhotoResource? {
        resources.first { $0.resourceRole == "pairedVideo" || $0.resourceRole == "fullSizePairedVideo" }
    }

    var hasExactContentRelationship: Bool {
        (exactContentMappingCount ?? 1) > 1
    }

    /// This represents verified backup records pointing to one complete
    /// resource group on MyNAS; it does not mean the app has merged or hidden
    /// the source records on any device.
    var exactContentRelationshipDescription: String? {
        guard let mappingCount = exactContentMappingCount, mappingCount > 1 else {
            return nil
        }

        let deviceCount = max(1, exactContentDeviceCount ?? 1)
        if deviceCount > 1 {
            return "相同完整资源已关联 \(deviceCount) 台设备的 \(mappingCount) 条备份记录"
        }
        return "相同完整资源已关联 \(mappingCount) 条备份记录"
    }

    var hasVersionTransitionRelationship: Bool {
        (previousVersionCount ?? 0) > 0 || (nextVersionCount ?? 0) > 0
    }

    /// A version relation is written only after one device has committed a new
    /// complete PhotoKit resource group for the same stable local identifier.
    /// It is not inferred from dates, filenames, or visual similarity.
    var versionTransitionRelationshipDescription: String? {
        let previous = max(0, previousVersionCount ?? 0)
        let next = max(0, nextVersionCount ?? 0)
        switch (previous, next) {
        case (0, 0):
            return nil
        case (let previous, 0):
            return "已记录 \(previous) 条前序版本关系"
        case (0, let next):
            return "已记录 \(next) 条后续版本关系"
        case (let previous, let next):
            return "已记录 \(previous) 条前序、\(next) 条后续版本关系"
        }
    }
}

nonisolated struct ServerAssetPage: Codable, Hashable, Sendable {
    let assets: [ServerPhotoAsset]
    let nextCursor: String?
    let hasMore: Bool
}

/// A narrow, owner- and device-scoped recovery record. It deliberately omits
/// content fingerprints: it restores only the exact local identifier and
/// source version MyNAS already verified for this device.
nonisolated struct ServerDeviceAssetMapping: Codable, Hashable, Sendable {
    let localIdentifier: String
    let assetID: String
    let sourceModificationDate: String?
    let sourceState: String
    let derivativeState: String
    let resourceCount: Int
    let sourceBytes: Int64
    let updatedAt: String
}

nonisolated struct ServerDeviceAssetMappingPage: Codable, Hashable, Sendable {
    let mappings: [ServerDeviceAssetMapping]
    let nextCursor: String?
    let hasMore: Bool
}

nonisolated struct RemotePhotoPageResult: Sendable {
    let page: ServerAssetPage
    let isUsingOfflineCache: Bool
}

nonisolated struct RemotePhotoImageResult: Sendable {
    let data: Data
    let isUsingOfflineCache: Bool
}

/// A complete MyNAS original resource that has already passed the server
/// metadata's byte-size and SHA-256 checks in an account-isolated temporary
/// directory. It is intentionally short lived: PhotoKit imports it as a copy,
/// then the caller removes the enclosing download directory.
nonisolated struct DownloadedRemotePhotoResource: Sendable {
    let resource: ServerPhotoResource
    let fileURL: URL
}

nonisolated struct RemotePhotoOriginalDownload: Sendable {
    let temporaryDirectory: URL
    let resources: [DownloadedRemotePhotoResource]

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

nonisolated struct ServerPhotoChange: Codable, Hashable, Sendable {
    let sequence: Int64
    let type: String
    let assetID: String
    let updatedAt: String
}

nonisolated struct ServerPhotoChangePage: Codable, Hashable, Sendable {
    let changes: [ServerPhotoChange]
    let nextCursor: String
    let hasMore: Bool
    let resetRequired: Bool
}

nonisolated struct RemotePhotoChangeSyncResult: Sendable {
    let changeCount: Int
    let changedAssetIDs: Set<String>
    let isInitialSync: Bool
    let resetRequired: Bool
}

nonisolated struct RemotePhotoDeletionResult: Codable, Hashable, Sendable {
    let items: [Item]

    nonisolated struct Item: Codable, Hashable, Sendable {
        let assetID: String
        let deletedAt: String
    }
}
