@preconcurrency import Photos
import AVFoundation
import PhotosUI
import UIKit
import Combine

enum PhotoLibraryDeletionError: LocalizedError {
    case permissionDenied
    case assetsUnavailable
    case systemRejected

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有修改系统照片库的权限。请在系统设置中允许 MyNAS Photos 访问照片。"
        case .assetsUnavailable:
            "有照片已不在当前可访问的系统图库中，请刷新后重试。"
        case .systemRejected:
            "iPhone 没有确认这次删除。"
        }
    }
}

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

    /// Requests one atomic Photos-library change for the selected assets. iOS
    /// owns the user confirmation and its Recently Deleted retention; the app
    /// never reaches into the Photos filesystem itself.
    func deleteAssets(localIdentifiers: [String]) async throws {
        guard authorizationState().canReadLibrary else {
            throw PhotoLibraryDeletionError.permissionDenied
        }
        let identifiers = Array(Set(localIdentifiers)).filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard result.count == identifiers.count else {
            throw PhotoLibraryDeletionError.assetsUnavailable
        }
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotoLibraryDeletionError.systemRejected)
                }
            }
        }
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

    func previewImage(
        for localIdentifier: String,
        targetSize: CGSize
    ) async -> PhotoImageResult {
        guard let asset = photoAsset(localIdentifier) else {
            return PhotoImageResult(image: nil, isCloudOnly: false)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !resumed else { return }
                resumed = true
                let isCloudOnly = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(
                    returning: PhotoImageResult(
                        image: image,
                        isCloudOnly: isCloudOnly && image == nil
                    )
                )
            }
        }
    }

    func playerItem(for localIdentifier: String) async -> AVPlayerItem? {
        guard let asset = photoAsset(localIdentifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            imageManager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    func livePhoto(
        for localIdentifier: String,
        targetSize: CGSize
    ) async -> PHLivePhoto? {
        guard let asset = photoAsset(localIdentifier) else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                guard !resumed else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                resumed = true
                continuation.resume(returning: livePhoto)
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
            isRAW: isRAWAsset(asset),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite
        )
    }

    /// PhotoKit has no `PHAssetMediaSubtype` dedicated to RAW. Inspecting the
    /// original resource metadata identifies ProRAW/DNG without decoding it.
    private func isRAWAsset(_ asset: PHAsset) -> Bool {
        let rawFilenameExtensions: Set<String> = [
            "3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq",
            "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef",
            "raf", "raw", "rw2", "rwl", "sr2", "srf", "x3f",
        ]

        return PHAssetResource.assetResources(for: asset).contains { resource in
            let filenameExtension = URL(fileURLWithPath: resource.originalFilename)
                .pathExtension
                .lowercased()
            if rawFilenameExtensions.contains(filenameExtension) {
                return true
            }

            let contentType = Self.resourceContentTypeIdentifier(resource).lowercased()
            return contentType == "com.adobe.raw-image"
                || contentType == "com.adobe.digital-negative"
                || contentType == "public.camera-raw-image"
                || contentType.contains("digital-negative")
        }
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
