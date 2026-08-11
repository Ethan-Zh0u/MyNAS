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

    func testVerifiedAssociationCarriesExpectedRemoteAssetIntoUploadManifest() throws {
        let source = Data("verified-original".utf8)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try source.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let local = LocalPhotoAsset(
            localIdentifier: "local-import-placeholder",
            creationDate: nil,
            modificationDate: nil,
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1_200,
            pixelHeight: 800,
            duration: 0,
            isFavorite: false
        )
        let prepared = PreparedPhotoAsset(
            localAsset: local,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            resourceDrafts: [
                .init(
                    role: "photo",
                    originalFilename: "test.png",
                    contentType: "public.png",
                    byteSize: Int64(source.count),
                    sha256: FileSHA256.digest(of: source),
                    fileURL: sourceURL
                )
            ]
        )

        let request = prepared.uploadSessionRequest(
            volumeID: "primary",
            deviceID: "current-iphone",
            expectedAssetID: "  ast-verified-target  "
        )

        XCTAssertEqual(request.expectedAssetID, "ast-verified-target")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(
            try JSONDecoder().decode(PhotoUploadSessionRequest.self, from: encoded).expectedAssetID,
            "ast-verified-target"
        )
    }

    func testUniqueCompleteResourceGroupMatchSelectsOnlyExactRemote() {
        let exactHash = String(repeating: "a", count: 64)
        let otherHash = String(repeating: "b", count: 64)
        let local = [
            preparedResource(role: "photo", byteSize: 1_024, sha256: exactHash)
        ]
        let exact = remoteAsset(
            id: "remote-exact",
            resources: [serverResource(role: "photo", byteSize: 1_024, sha256: exactHash)]
        )
        let other = remoteAsset(
            id: "remote-other",
            resources: [serverResource(role: "photo", byteSize: 1_024, sha256: otherHash)]
        )

        XCTAssertEqual(
            RemotePhotoLocalCopyVerification.uniqueCompleteResourceGroupMatch(
                localResources: local,
                among: [other, exact]
            )?.id,
            exact.id
        )
    }

    func testUniqueCompleteResourceGroupMatchRejectsTwoRemoteIDsWithSameProof() {
        let exactHash = String(repeating: "a", count: 64)
        let local = [
            preparedResource(role: "photo", byteSize: 1_024, sha256: exactHash)
        ]
        let first = remoteAsset(
            id: "remote-first",
            resources: [serverResource(role: "photo", byteSize: 1_024, sha256: exactHash)]
        )
        let second = remoteAsset(
            id: "remote-second",
            resources: [serverResource(role: "photo", byteSize: 1_024, sha256: exactHash)]
        )

        XCTAssertNil(
            RemotePhotoLocalCopyVerification.uniqueCompleteResourceGroupMatch(
                localResources: local,
                among: [first, second]
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

    func testUnifiedTimelineKeepsCommittedRemoteLinkAcrossMetadataOnlyRevision() {
        let sourceDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let metadataDate = sourceDate.addingTimeInterval(60)
        let local = LocalPhotoAsset(
            localIdentifier: "local-favourite",
            creationDate: sourceDate,
            modificationDate: metadataDate,
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            isFavorite: true
        )
        let remote = ServerPhotoAsset(
            id: "remote-favourite",
            volumeID: "volume-1",
            mediaType: .photo,
            captureDate: nil,
            modificationDate: PhotoBackupSourceVersion.string(from: sourceDate),
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
            exactContentMappingCount: 1,
            previousVersionCount: 0,
            nextVersionCount: 0,
            resources: [],
            derivatives: []
        )
        let job = PhotoBackupJob(
            id: UUID(),
            accountID: "account-1",
            localIdentifier: local.localIdentifier,
            mediaKind: local.mediaKind,
            creationDate: local.creationDate,
            sourceModificationDate: sourceDate,
            lastKnownLocalModificationDate: metadataDate,
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
            updatedAt: metadataDate
        )

        let items = UnifiedPhotoTimelineItem.merge(
            localAssets: [local],
            jobs: [job],
            accountID: "account-1",
            remoteAssets: [remote]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.localAsset?.localIdentifier, local.localIdentifier)
        XCTAssertEqual(items.first?.remoteAsset?.id, remote.id)
        XCTAssertEqual(items.first?.availability, .browseReady)
    }

    func testUnifiedTimelineMergesPersistedExactAssociationBeforeServerMappingCompletes() {
        let modificationDate = Date(timeIntervalSinceReferenceDate: 234_567)
        let local = LocalPhotoAsset(
            localIdentifier: "local-import-placeholder",
            creationDate: modificationDate,
            modificationDate: modificationDate,
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 1_200,
            pixelHeight: 800,
            duration: 0,
            isFavorite: false
        )
        let remote = ServerPhotoAsset(
            id: "remote-downloaded",
            volumeID: "volume-1",
            mediaType: .photo,
            captureDate: nil,
            modificationDate: nil,
            pixelWidth: 1_200,
            pixelHeight: 800,
            duration: 0,
            favorite: false,
            sourceState: PhotoSourceState.committed.rawValue,
            derivativeState: PhotoDerivativeState.ready.rawValue,
            derivativeRecipeVersion: "v1",
            derivativeError: nil,
            browseReady: true,
            version: "1",
            exactContentDeviceCount: 1,
            exactContentMappingCount: 1,
            previousVersionCount: 0,
            nextVersionCount: 0,
            resources: [],
            derivatives: []
        )
        let pendingAssociation = PhotoBackupJob(
            id: UUID(),
            accountID: "account-1",
            localIdentifier: local.localIdentifier,
            mediaKind: local.mediaKind,
            creationDate: local.creationDate,
            sourceModificationDate: local.modificationDate,
            status: .waiting,
            totalBytes: 0,
            uploadedBytes: 0,
            resourceCount: 0,
            assetID: nil,
            pendingVerifiedRemoteAssetID: remote.id,
            sourceState: nil,
            derivativeState: nil,
            origin: .manual,
            message: "已核验同一原件，等待登记当前 iPhone",
            failure: nil,
            updatedAt: modificationDate
        )

        let items = UnifiedPhotoTimelineItem.merge(
            localAssets: [local],
            jobs: [pendingAssociation],
            accountID: "account-1",
            remoteAssets: [remote]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.localAsset?.localIdentifier, local.localIdentifier)
        XCTAssertEqual(items.first?.remoteAsset?.id, remote.id)
        XCTAssertEqual(items.first?.availability, .waitingForBackup)
        XCTAssertFalse(items.first?.availability.hasVerifiedOriginals == true)
    }

    func testUnifiedTimelineDoesNotTrustUnclassifiedModifiedAsset() {
        let sourceDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let editedDate = sourceDate.addingTimeInterval(60)
        let local = LocalPhotoAsset(
            localIdentifier: "local-edited",
            creationDate: sourceDate,
            modificationDate: editedDate,
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            isFavorite: false
        )
        let remote = ServerPhotoAsset(
            id: "remote-original",
            volumeID: "volume-1",
            mediaType: .photo,
            captureDate: nil,
            modificationDate: PhotoBackupSourceVersion.string(from: sourceDate),
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
            exactContentMappingCount: 1,
            previousVersionCount: 0,
            nextVersionCount: 0,
            resources: [],
            derivatives: []
        )
        let job = PhotoBackupJob(
            id: UUID(),
            accountID: "account-1",
            localIdentifier: local.localIdentifier,
            mediaKind: local.mediaKind,
            creationDate: local.creationDate,
            sourceModificationDate: sourceDate,
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
            updatedAt: sourceDate
        )

        let items = UnifiedPhotoTimelineItem.merge(
            localAssets: [local],
            jobs: [job],
            accountID: "account-1",
            remoteAssets: [remote]
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter { $0.localAsset != nil }.count, 1)
        XCTAssertEqual(items.filter { $0.remoteAsset != nil }.count, 1)
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

    private func remoteAsset(
        id: String,
        resources: [ServerPhotoResource]
    ) -> ServerPhotoAsset {
        ServerPhotoAsset(
            id: id,
            volumeID: "volume-1",
            mediaType: .photo,
            captureDate: nil,
            modificationDate: nil,
            pixelWidth: 1_200,
            pixelHeight: 800,
            duration: 0,
            favorite: false,
            sourceState: PhotoSourceState.committed.rawValue,
            derivativeState: PhotoDerivativeState.ready.rawValue,
            derivativeRecipeVersion: "v1",
            derivativeError: nil,
            browseReady: true,
            version: "1",
            exactContentDeviceCount: 1,
            exactContentMappingCount: 1,
            previousVersionCount: 0,
            nextVersionCount: 0,
            resources: resources,
            derivatives: []
        )
    }
}
