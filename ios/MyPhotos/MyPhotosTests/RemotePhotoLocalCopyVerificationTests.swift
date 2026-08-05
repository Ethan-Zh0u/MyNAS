import XCTest
@testable import MyPhotos

final class RemotePhotoLocalCopyVerificationTests: XCTestCase {
    func testMissingOptionalDeviceMappingDoesNotBlockOriginalDownload() {
        XCTAssertTrue(RemotePhotoLibraryError.featureUnavailable.permitsDownloadWithoutDeviceMappingCheck)
        XCTAssertTrue(RemotePhotoLibraryError.invalidResponse.permitsDownloadWithoutDeviceMappingCheck)
        XCTAssertTrue(RemotePhotoLibraryError.serverRejected(404).permitsDownloadWithoutDeviceMappingCheck)
        XCTAssertFalse(RemotePhotoLibraryError.unauthorized.permitsDownloadWithoutDeviceMappingCheck)
        XCTAssertFalse(RemotePhotoLibraryError.serverRejected(500).permitsDownloadWithoutDeviceMappingCheck)
    }

    func testResourceGroupMatchIgnoresResourceOrderAndHashLetterCase() {
        let photoHash = String(repeating: "a", count: 64)
        let videoHash = String(repeating: "b", count: 64)
        let local = [
            preparedResource(role: "photo", byteSize: 1_024, sha256: photoHash),
            preparedResource(role: "pairedVideo", byteSize: 2_048, sha256: videoHash),
        ]
        let remote = [
            serverResource(role: "pairedVideo", byteSize: 2_048, sha256: videoHash.uppercased()),
            serverResource(role: "photo", byteSize: 1_024, sha256: photoHash.uppercased()),
        ]

        XCTAssertTrue(
            RemotePhotoLocalCopyVerification.hasSameCompleteResourceGroup(
                localResources: local,
                remoteResources: remote
            )
        )
    }

    func testResourceGroupDoesNotMatchWhenAnyResourceHashDiffers() {
        let local = [preparedResource(role: "photo", byteSize: 1_024, sha256: String(repeating: "a", count: 64))]
        let remote = [serverResource(role: "photo", byteSize: 1_024, sha256: String(repeating: "b", count: 64))]

        XCTAssertFalse(
            RemotePhotoLocalCopyVerification.hasSameCompleteResourceGroup(
                localResources: local,
                remoteResources: remote
            )
        )
    }

    func testUnifiedTimelineMergesSeveralCurrentLocalCopiesOfOneRemoteAsset() {
        let modificationDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let remote = ServerPhotoAsset(
            id: "remote-1",
            volumeID: "volume-1",
            mediaType: .photo,
            captureDate: nil,
            modificationDate: nil,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            favorite: false,
            sourceState: PhotoSourceState.committed.rawValue,
            derivativeState: PhotoDerivativeState.ready.rawValue,
            derivativeRecipeVersion: "v1",
            derivativeError: nil,
            browseReady: true,
            version: "1",
            exactContentDeviceCount: 1,
            exactContentMappingCount: 2,
            previousVersionCount: 0,
            nextVersionCount: 0,
            resources: [],
            derivatives: []
        )
        let copies = ["local-old", "local-imported"].map {
            LocalPhotoAsset(
                localIdentifier: $0,
                creationDate: modificationDate,
                modificationDate: modificationDate,
                mediaKind: .photo,
                isRAW: false,
                pixelWidth: 4_032,
                pixelHeight: 3_024,
                duration: 0,
                isFavorite: false
            )
        }
        let jobs = copies.map {
            PhotoBackupJob(
                id: UUID(),
                accountID: "account-1",
                localIdentifier: $0.localIdentifier,
                mediaKind: $0.mediaKind,
                creationDate: $0.creationDate,
                sourceModificationDate: modificationDate,
                status: .completed,
                totalBytes: 1,
                uploadedBytes: 1,
                resourceCount: 1,
                assetID: remote.id,
                sourceState: .committed,
                derivativeState: .ready,
                origin: .manual,
                message: nil,
                failure: nil,
                updatedAt: modificationDate
            )
        }

        let items = UnifiedPhotoTimelineItem.merge(
            localAssets: copies,
            jobs: jobs,
            accountID: "account-1",
            remoteAssets: [remote]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.remoteAsset?.id, remote.id)
        XCTAssertEqual(items.first?.localCopyCount, 2)
        XCTAssertEqual(items.first?.availability, .browseReady)
    }

    private func preparedResource(role: String, byteSize: Int64, sha256: String) -> PreparedPhotoResource {
        PreparedPhotoResource(
            clientResourceID: UUID().uuidString,
            role: role,
            originalFilename: "original",
            contentType: "image/heic",
            byteSize: byteSize,
            sha256: sha256,
            fileURL: URL(fileURLWithPath: "/dev/null")
        )
    }

    private func serverResource(role: String, byteSize: Int64, sha256: String) -> ServerPhotoResource {
        ServerPhotoResource(
            id: UUID().uuidString,
            resourceRole: role,
            originalFilename: "original",
            contentType: "image/heic",
            byteSize: byteSize,
            sha256: sha256,
            downloadURL: "https://example.invalid/original"
        )
    }
}
