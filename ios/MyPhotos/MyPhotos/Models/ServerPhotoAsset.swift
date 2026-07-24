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
}

nonisolated struct ServerAssetPage: Codable, Hashable, Sendable {
    let assets: [ServerPhotoAsset]
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
