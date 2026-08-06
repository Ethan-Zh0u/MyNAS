import XCTest
@testable import MyPhotos

final class MyNASRemoteMutationPreflightTests: XCTestCase {
    func testUnavailableStatusIsFailClosedAndNamesTailscale() {
        let status = MyNASRemoteMutationAvailability.tailscaleUnavailable

        XCTAssertFalse(status.allowsRemoteMutation)
        XCTAssertEqual(
            status.statusText,
            "Tailscale 未连接，无法删除 MyNAS 文件。请先连接 Tailscale，并确认 MyNAS 在线。"
        )
    }

    func testCheckingStatusDoesNotPermitRemoteDeletion() {
        XCTAssertFalse(MyNASRemoteMutationAvailability.checking.allowsRemoteMutation)
        XCTAssertTrue(MyNASRemoteMutationAvailability.available.allowsRemoteMutation)
    }

    func testPairedDeletionRequiresLiveTailscaleConnection() {
        let asset = LocalPhotoAsset(
            localIdentifier: "local-1",
            creationDate: nil,
            modificationDate: nil,
            mediaKind: .photo,
            isRAW: false,
            pixelWidth: 100,
            pixelHeight: 100,
            duration: 0,
            isFavorite: false
        )
        let candidate = PhotoBackupDeletionCandidate(
            assetID: "remote-1",
            deviceID: "device-1",
            localIdentifier: asset.localIdentifier,
            sourceModificationDate: "2026-08-06T00:00:00.000Z"
        )
        let request = PhotoDeletionRequest(
            assets: [asset],
            backupCandidates: [candidate],
            isConnectedToMyNAS: true,
            isMyNASDeletionAvailable: true
        )

        XCTAssertFalse(request.canAlsoDeleteMyNASBackups(when: .checking))
        XCTAssertFalse(request.canAlsoDeleteMyNASBackups(when: .tailscaleUnavailable))
        XCTAssertTrue(request.canAlsoDeleteMyNASBackups(when: .available))
    }
}
