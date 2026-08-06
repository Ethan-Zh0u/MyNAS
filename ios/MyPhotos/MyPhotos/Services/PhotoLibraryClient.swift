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

enum PhotoLibraryImportError: LocalizedError {
    case permissionDenied
    case invalidResource
    case unsupportedResourceCombination
    case systemRejected

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有写入系统照片库的权限。请在系统设置中允许 MyNAS Photos 添加照片。"
        case .invalidResource:
            "下载的原件资源不完整或无法安全导入系统照片库。"
        case .unsupportedResourceCombination:
            "这组 MyNAS 原件不能由 iPhone 的照片图库还原为一个项目。"
        case .systemRejected:
            "iPhone 没有确认这次原件导入。"
        }
    }
}

@MainActor
final class PhotoLibraryClient: NSObject {
    private let imageManager = PHCachingImageManager()
    private var fetchResult: PHFetchResult<PHAsset>?
    /// Identifiers observed by PhotoKit to have changed without changing image
    /// or video bytes. They are consumed by the backup coordinator after the
    /// library view has refreshed its value snapshot.
    private var metadataOnlyChangedAssetIdentifiers = Set<String>()
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

    /// Returns PhotoKit changes for which `assetContentChanged` was explicitly
    /// false. A missing identifier or a broad/nonincremental notification is
    /// deliberately not treated as metadata-only: callers must then preserve
    /// the normal content-version safety check.
    func consumeMetadataOnlyChangedAssetIdentifiers() -> Set<String> {
        defer { metadataOnlyChangedAssetIdentifiers.removeAll() }
        return metadataOnlyChangedAssetIdentifiers
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

    /// Returns true only for a PhotoKit identifier MyNAS has already confirmed
    /// for this device and which remains accessible under the current Photos
    /// permission. It intentionally does not compare filenames or dates.
    func hasAccessibleAsset(localIdentifier: String) -> Bool {
        authorizationState().canReadLibrary && photoAsset(localIdentifier) != nil
    }

    /// Resolves one currently accessible Photos item without relying on the
    /// timeline's paged grid snapshot. A persisted backup mapping can name an
    /// older item that is not among the first visible local results.
    func accessibleAsset(localIdentifier: String) -> LocalPhotoAsset? {
        guard authorizationState().canReadLibrary,
              let asset = photoAsset(localIdentifier) else {
            return nil
        }
        return localAsset(from: asset)
    }

    /// Reads only PhotoKit metadata for the current permission scope. It does
    /// not request image data or iCloud originals; callers still must perform
    /// complete-resource verification before describing a candidate as equal.
    func allAccessibleAssets() async -> [LocalPhotoAsset] {
        guard authorizationState().canReadLibrary else { return [] }
        // PHAssetResource metadata is not always prefetched. Reading it from
        // this @MainActor client makes PhotoKit synchronously fault original
        // metadata on the UI thread, which becomes visible on large libraries.
        // Fetch and flatten a separate snapshot on a utility worker; only the
        // value-only, Sendable LocalPhotoAsset records return to the UI actor.
        return await Task.detached(priority: .utility) {
            Self.fetchAllAccessibleAssetMetadata()
        }.value
    }

    /// Imports an already verified complete original-resource group. PhotoKit
    /// owns the actual library write; the caller keeps ownership of its private
    /// temporary directory and removes it only after this method returns.
    func importDownloadedRemoteResources(
        _ downloadedResources: [DownloadedRemotePhotoResource]
    ) async throws -> String? {
        guard authorizationState().canReadLibrary else {
            throw PhotoLibraryImportError.permissionDenied
        }
        guard !downloadedResources.isEmpty else {
            throw PhotoLibraryImportError.invalidResource
        }

        let resources: [(DownloadedRemotePhotoResource, PHAssetResourceType)] = try downloadedResources.map { downloaded in
            guard let resourceType = Self.photoResourceType(for: downloaded.resource.resourceRole),
                  Self.isRegularFile(
                    at: downloaded.fileURL,
                    expectedByteSize: downloaded.resource.byteSize
                  ) else {
                throw PhotoLibraryImportError.invalidResource
            }
            return (downloaded, resourceType)
        }

        let resourceTypes = resources.map { NSNumber(value: $0.1.rawValue) }
        guard PHAssetCreationRequest.supportsAssetResourceTypes(resourceTypes) else {
            throw PhotoLibraryImportError.unsupportedResourceCombination
        }

        // A Photos service restart can invalidate its XPC connection while a
        // request is in flight. Do not blindly retry: first use the creation
        // placeholder to determine whether Photos committed the first request,
        // so an interrupted callback cannot create an accidental duplicate.
        let firstAttempt = await submitDownloadedRemoteResources(resources)
        switch firstAttempt {
        case .success(let placeholderLocalIdentifier):
            return placeholderLocalIdentifier
        case .failure(let error, let placeholderLocalIdentifier):
            guard Self.wasPhotoLibraryServiceInterrupted(error) else {
                throw error
            }
            if let placeholderLocalIdentifier,
               hasAccessibleAsset(localIdentifier: placeholderLocalIdentifier) {
                return placeholderLocalIdentifier
            }

            // Let photolibraryd finish reconnecting, then make exactly one
            // fresh change request using the still-owned temporary files.
            try await Task.sleep(nanoseconds: 750_000_000)
            let retry = await submitDownloadedRemoteResources(resources)
            switch retry {
            case .success(let placeholderLocalIdentifier):
                return placeholderLocalIdentifier
            case .failure(let retryError, let retryPlaceholderLocalIdentifier):
                if Self.wasPhotoLibraryServiceInterrupted(retryError),
                   let retryPlaceholderLocalIdentifier,
                   hasAccessibleAsset(localIdentifier: retryPlaceholderLocalIdentifier) {
                    return retryPlaceholderLocalIdentifier
                }
                throw retryError
            }
        }
    }

    private enum DownloadedRemoteResourceImportResult {
        case success(placeholderLocalIdentifier: String?)
        case failure(Error, placeholderLocalIdentifier: String?)
    }

    /// Submits one Photos change request and retains the placeholder identity
    /// even if the system reports failure after it has accepted the request.
    private func submitDownloadedRemoteResources(
        _ resources: [(DownloadedRemotePhotoResource, PHAssetResourceType)]
    ) async -> DownloadedRemoteResourceImportResult {
        await withCheckedContinuation { continuation in
            var placeholderLocalIdentifier: String?
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                placeholderLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
                for (downloaded, resourceType) in resources {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    options.originalFilename = Self.safeBackupFilename(
                        downloaded.resource.originalFilename,
                        fallback: downloaded.resource.id
                    )
                    // MyNAS preserves PhotoKit's UTI when it is available.
                    // A MIME string is not accepted by this PhotoKit property,
                    // so leave it unset and let Photos infer from the filename.
                    if !downloaded.resource.contentType.contains("/") {
                        options.uniformTypeIdentifier = downloaded.resource.contentType
                    }
                    request.addResource(
                        with: resourceType,
                        fileURL: downloaded.fileURL,
                        options: options
                    )
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume(
                        returning: .success(
                            placeholderLocalIdentifier: placeholderLocalIdentifier
                        )
                    )
                } else if let error {
                    continuation.resume(
                        returning: .failure(
                            error,
                            placeholderLocalIdentifier: placeholderLocalIdentifier
                        )
                    )
                } else {
                    continuation.resume(
                        returning: .failure(
                            PhotoLibraryImportError.systemRejected,
                            placeholderLocalIdentifier: placeholderLocalIdentifier
                        )
                    )
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

    /// Provides a bounded rendered still for an explicitly enabled I3 OCR
    /// operation. This deliberately rejects videos and Live Photos, never
    /// requests the original resource, caps the raster at 2,048 px and keeps
    /// PhotoKit network access off so an iCloud-only item remains unindexed.
    func textRecognitionImage(for localIdentifier: String) async -> PhotoImageResult {
        guard let asset = photoAsset(localIdentifier),
              asset.mediaType == .image,
              !asset.mediaSubtypes.contains(.photoLive) else {
            return PhotoImageResult(image: nil, isCloudOnly: false)
        }

        let maximumDimension: CGFloat = 2_048
        let sourceWidth = max(CGFloat(asset.pixelWidth), 1)
        let sourceHeight = max(CGFloat(asset.pixelHeight), 1)
        let scale = min(1, maximumDimension / max(sourceWidth, sourceHeight))
        let targetSize = CGSize(
            width: max(1, floor(sourceWidth * scale)),
            height: max(1, floor(sourceHeight * scale))
        )
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.version = .current

        return await withCheckedContinuation { continuation in
            var resumed = false
            let requestID = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !resumed else { return }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let isCloudOnly = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false && image == nil
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error

                if let image, !isDegraded {
                    resumed = true
                    continuation.resume(returning: PhotoImageResult(image: image, isCloudOnly: false))
                    return
                }
                if cancelled || isCloudOnly || error != nil || image == nil {
                    resumed = true
                    continuation.resume(
                        returning: PhotoImageResult(image: nil, isCloudOnly: isCloudOnly)
                    )
                }
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

    func prepareBackupAsset(
        _ localAsset: LocalPhotoAsset,
        allowsNetworkAccess: Bool = true
    ) async throws -> PreparedPhotoAsset {
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
                try await export(
                    resource: resource,
                    to: fileURL,
                    allowsNetworkAccess: allowsNetworkAccess
                )
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

    /// Records only a narrow, PhotoKit-proven subset of changes. We retain the
    /// pre-change objects from the cached fetch result because PhotoKit's
    /// object-level detail is defined relative to the object it previously
    /// handed us. If it cannot provide an incremental diff, no identifier is
    /// accepted as metadata-only and the coordinator will fail closed.
    private func recordMetadataOnlyChanges(from change: PHChange) {
        guard let previousFetchResult = fetchResult,
              let fetchDetails = change.changeDetails(for: previousFetchResult),
              fetchDetails.hasIncrementalChanges else {
            return
        }

        var previousAssetsByIdentifier: [String: PHAsset] = [:]
        previousAssetsByIdentifier.reserveCapacity(previousFetchResult.count)
        previousFetchResult.enumerateObjects { asset, _, _ in
            previousAssetsByIdentifier[asset.localIdentifier] = asset
        }

        for changedAsset in fetchDetails.changedObjects {
            guard let previousAsset = previousAssetsByIdentifier[changedAsset.localIdentifier],
                  let objectDetails = change.changeDetails(for: previousAsset),
                  !objectDetails.objectWasDeleted,
                  objectDetails.objectAfterChanges != nil,
                  !objectDetails.assetContentChanged else {
                continue
            }
            metadataOnlyChangedAssetIdentifiers.insert(changedAsset.localIdentifier)
        }
    }

    private func photoAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private func localAsset(from asset: PHAsset) -> LocalPhotoAsset? {
        Self.localAssetValue(from: asset)
    }

    private nonisolated static func fetchAllAccessibleAssetMetadata() -> [LocalPhotoAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        let assets = PHAsset.fetchAssets(with: options)

        var result: [LocalPhotoAsset] = []
        result.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            guard !Task.isCancelled else { return result }
            if let localAsset = localAssetValue(from: assets.object(at: index)) {
                result.append(localAsset)
            }
        }
        return result
    }

    private nonisolated static func localAssetValue(from asset: PHAsset) -> LocalPhotoAsset? {
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
    private nonisolated static func isRAWAsset(_ asset: PHAsset) -> Bool {
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

    private func export(
        resource: PHAssetResource,
        to fileURL: URL,
        allowsNetworkAccess: Bool
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        // Manual backup and an explicitly opened detail may read an iCloud
        // original. The automatic duplicate-repair sweep passes false so it
        // never creates an unexpected background iCloud transfer.
        options.isNetworkAccessAllowed = allowsNetworkAccess
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

    private static func photoResourceType(for role: String) -> PHAssetResourceType? {
        switch role {
        case "photo": .photo
        case "video": .video
        case "audio": .audio
        case "alternatePhoto": .alternatePhoto
        case "photoProxy": .photoProxy
        case "fullSizePhoto": .fullSizePhoto
        case "fullSizeVideo": .fullSizeVideo
        case "adjustmentData": .adjustmentData
        case "adjustmentBasePhoto": .adjustmentBasePhoto
        case "pairedVideo": .pairedVideo
        case "fullSizePairedVideo": .fullSizePairedVideo
        case "adjustmentBaseVideo": .adjustmentBaseVideo
        case "adjustmentBasePairedVideo": .adjustmentBasePairedVideo
        default: nil
        }
    }

    private static func isRegularFile(at url: URL, expectedByteSize: Int64) -> Bool {
        guard expectedByteSize >= 0,
              let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular,
              let byteSize = (values[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return byteSize == expectedByteSize
    }

    private static func wasPhotoLibraryServiceInterrupted(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == 4099
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
            self?.recordMetadataOnlyChanges(from: changeInstance)
            self?.resetFetch()
            self?.libraryDidChange?()
        }
    }
}
