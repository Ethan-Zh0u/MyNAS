@preconcurrency import Photos
import PhotosUI
import UIKit
import Combine

@MainActor
final class PhotoLibraryClient: NSObject {
    private let imageManager = PHCachingImageManager()
    private var fetchResult: PHFetchResult<PHAsset>?
    private var isObserving = false

    var libraryDidChange: (() -> Void)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    deinit {
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func authorizationState() -> PhotoAuthorizationState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
        return state(for: status)
    }

    func presentLimitedLibraryPicker() {
        guard let controller = topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func resetFetch() {
        fetchResult = nil
        imageManager.stopCachingImagesForAllAssets()
    }

    func page(offset: Int, size: Int) -> (items: [LocalPhotoAsset], nextOffset: Int?) {
        let assets = photoAssets()
        guard offset < assets.count else { return ([], nil) }

        let upperBound = min(offset + size, assets.count)
        var items: [LocalPhotoAsset] = []
        items.reserveCapacity(upperBound - offset)

        for index in offset..<upperBound {
            let asset = assets.object(at: index)
            guard let item = localAsset(from: asset) else { continue }
            items.append(item)
        }

        return (items, upperBound < assets.count ? upperBound : nil)
    }

    func thumbnail(for localIdentifier: String, targetSize: CGSize) async -> PhotoImageResult {
        guard let asset = photoAsset(localIdentifier) else {
            return PhotoImageResult(image: nil, isCloudOnly: false)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            var resumed = false
            let requestID = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !resumed else { return }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let isCloudOnly = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false && image == nil
                let error = info?[PHImageErrorKey] as? Error

                // A degraded PhotoKit result is still a valid thumbnail. In particular,
                // Simulator can provide only this fast preview for newly imported media.
                // Accept the first usable image and reserve the retry tile for an explicit
                // cancellation/error. A nil callback without either flag is transitional.
                if let image {
                    resumed = true
                    continuation.resume(returning: PhotoImageResult(image: image, isCloudOnly: false))
                    return
                }

                if !cancelled, error == nil, !isCloudOnly {
                    return
                }

                resumed = true
                continuation.resume(returning: PhotoImageResult(
                    image: nil,
                    isCloudOnly: isCloudOnly
                ))
            }

            if requestID == PHInvalidImageRequestID, !resumed {
                resumed = true
                continuation.resume(returning: PhotoImageResult(image: nil, isCloudOnly: false))
            }
        }
    }

    func prepareBackupAsset(_ localAsset: LocalPhotoAsset) async throws -> PreparedPhotoAsset {
        guard let asset = photoAsset(localAsset.localIdentifier) else {
            throw PhotoBackupPreparationError.assetUnavailable
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else {
            throw PhotoBackupPreparationError.noResources
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNASPhotosBackup", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        do {
            var drafts: [PreparedPhotoResource.Draft] = []
            drafts.reserveCapacity(resources.count)
            for (index, resource) in resources.enumerated() {
                let role = Self.backupRole(for: resource.type)
                let originalFilename = Self.safeBackupFilename(
                    resource.originalFilename,
                    fallback: "\(role)-\(index)"
                )
                let fileURL = directory.appendingPathComponent(
                    String(format: "%03d-%@", index, originalFilename),
                    isDirectory: false
                )
                try await export(resource: resource, to: fileURL)
                let values = try await Task.detached(priority: .utility) {
                    let size = try FileManager.default.attributesOfItem(
                        atPath: fileURL.path
                    )[.size] as? NSNumber
                    return (
                        size?.int64Value ?? 0,
                        try FileSHA256.digest(of: fileURL)
                    )
                }.value
                drafts.append(
                    PreparedPhotoResource.Draft(
                        role: role,
                        originalFilename: originalFilename,
                        contentType: Self.resourceContentTypeIdentifier(resource),
                        byteSize: values.0,
                        sha256: values.1,
                        fileURL: fileURL
                    )
                )
            }
            return PreparedPhotoAsset(
                localAsset: localAsset,
                temporaryDirectory: directory,
                resourceDrafts: drafts
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func startCachingThumbnails(for identifiers: [String], targetSize: CGSize) {
        let assets = identifiers.compactMap(photoAsset)
        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: localThumbnailOptions()
        )
    }

    func stopCachingThumbnails(for identifiers: [String], targetSize: CGSize) {
        let assets = identifiers.compactMap(photoAsset)
        imageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: localThumbnailOptions()
        )
    }

    private func photoAssets() -> PHFetchResult<PHAsset> {
        if let fetchResult { return fetchResult }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        let result = PHAsset.fetchAssets(with: options)
        fetchResult = result
        return result
    }

    private func photoAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private func localAsset(from asset: PHAsset) -> LocalPhotoAsset? {
        let mediaKind: LocalMediaKind
        switch asset.mediaType {
        case .image:
            mediaKind = asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video: mediaKind = .video
        default: return nil
        }

        return LocalPhotoAsset(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaKind: mediaKind,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite
        )
    }

    private func localThumbnailOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }

    private func export(resource: PHAssetResource, to fileURL: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        // Manual backup is an explicit request for originals, so iCloud downloads are allowed.
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: fileURL,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func backupRole(for type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .photoProxy: "photoProxy"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        @unknown default: "resourceType\(type.rawValue)"
        }
    }

    private nonisolated static func resourceContentTypeIdentifier(
        _ resource: PHAssetResource
    ) -> String {
        if #available(iOS 26.0, *) {
            resource.contentType.identifier
        } else {
            resource.uniformTypeIdentifier
        }
    }

    private static func safeBackupFilename(_ value: String, fallback: String) -> String {
        let candidate = URL(fileURLWithPath: value).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "-")
            .replacingOccurrences(of: "\r", with: "-")
            .replacingOccurrences(of: "\t", with: "-")
        return candidate.isEmpty || candidate == "." || candidate == ".." ? fallback : candidate
    }

    private func state(for status: PHAuthorizationStatus) -> PhotoAuthorizationState {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)?.rootViewController
    }
}

extension PhotoLibraryClient: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.resetFetch()
            self?.libraryDidChange?()
        }
    }
}
