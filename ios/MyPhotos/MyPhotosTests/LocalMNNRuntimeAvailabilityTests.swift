import XCTest
@testable import MyPhotos

final class LocalMNNRuntimeAvailabilityTests: XCTestCase {
    func testRuntimeAvailabilityMatchesTheTargetArchitecture() {
        #if arch(arm64)
        XCTAssertTrue(
            MNNQwen3VLEmbeddingBridge.isRuntimeAvailable(),
            "arm64 iPhone and Apple Silicon Simulator builds must link the pinned MNN runtime"
        )
        #elseif arch(x86_64)
        XCTAssertFalse(
            MNNQwen3VLEmbeddingBridge.isRuntimeAvailable(),
            "Intel Simulator intentionally retains the no-runtime fallback"
        )
        #else
        XCTFail("Unexpected MyPhotos architecture")
        #endif
    }
}
