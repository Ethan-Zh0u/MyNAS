import Foundation
import UIKit

enum LocalMediaKind: String, Codable, Hashable, Sendable {
    case photo
    case video
    case livePhoto

    nonisolated var displayName: String {
        switch self {
        case .photo: "照片"
        case .video: "视频"
        case .livePhoto: "实况照片"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "livephoto"
        }
    }

    nonisolated var backupMediaType: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "livePhoto"
        }
    }
}

/// A value-only representation of a PhotoKit asset. `PHAsset` objects stay inside PhotoLibraryClient.
struct LocalPhotoAsset: Identifiable, Hashable, Sendable {
    let localIdentifier: String
    let creationDate: Date?
    let modificationDate: Date?
    let mediaKind: LocalMediaKind
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let isFavorite: Bool

    var id: String { localIdentifier }
    var pixelSizeText: String { "\(pixelWidth) × \(pixelHeight)" }
}

enum PhotoAuthorizationState: Equatable {
    case notDetermined
    case limited
    case authorized
    case denied

    var canReadLibrary: Bool {
        self == .limited || self == .authorized
    }
}

struct PhotoImageResult {
    let image: UIImage?
    let isCloudOnly: Bool
}
