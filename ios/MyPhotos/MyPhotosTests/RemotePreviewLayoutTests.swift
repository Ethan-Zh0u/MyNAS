import XCTest
@testable import MyPhotos

final class RemotePreviewLayoutTests: XCTestCase {
    func testUsesDerivativeGeometryBeforeOriginalAssetMetadata() {
        let ratio = RemotePreviewLayout.aspectRatio(
            preferredWidth: 1_920,
            preferredHeight: 1_080,
            fallbackWidth: 1_080,
            fallbackHeight: 1_920
        )

        XCTAssertEqual(ratio, 1_920.0 / 1_080.0, accuracy: 0.0001)
    }

    func testUsesDecodedGeometryWhenItDiffersFromAdvertisedDerivative() {
        let ratio = RemotePreviewLayout.aspectRatio(
            preferredWidth: 1_440,
            preferredHeight: 1_920,
            fallbackWidth: 1_920,
            fallbackHeight: 1_080
        )

        XCTAssertEqual(ratio, 0.75, accuracy: 0.0001)
    }

    func testFallsBackAndBoundsInvalidGeometry() {
        XCTAssertEqual(
            RemotePreviewLayout.aspectRatio(
                preferredWidth: 0,
                preferredHeight: 0,
                fallbackWidth: 4_000,
                fallbackHeight: 1_000
            ),
            2.4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RemotePreviewLayout.aspectRatio(
                preferredWidth: 0,
                preferredHeight: 0,
                fallbackWidth: 0,
                fallbackHeight: 0
            ),
            1,
            accuracy: 0.0001
        )
    }
}
