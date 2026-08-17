import XCTest
@testable import MyPhotos

final class LocalSemanticModelCatalogTests: XCTestCase {
    func testPinnedQwenMNNManifestHasTheExpectedCompleteContract() {
        let manifest = LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Manifest

        XCTAssertEqual(manifest.runtime, .mnnQwen3VLEmbedding)
        XCTAssertEqual(manifest.profile, LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Profile)
        XCTAssertEqual(manifest.files.count, 9)
        XCTAssertEqual(manifest.totalByteCount, 1_392_153_815)
        XCTAssertEqual(
            manifest.files.first(where: { $0.relativePath == "embedding.mnn.weight" })?.sha256,
            "b73a5f0a52b1949e6de8848f34fa6824b9279f59b21d0a1ac273680a5f4358c6"
        )
        XCTAssertEqual(
            manifest.files.first(where: { $0.relativePath == "visual.mnn.weight" })?.sha256,
            "f817346c4085c0b57d6df535e2ebc10e38b2f32656714a1da804ff106ab0f72e"
        )
    }

    func testRuntimeLockPinsTheOfficialMNNBuildForDeviceAndAppleSiliconSimulator() {
        XCTAssertEqual(
            LocalSemanticMNNRuntimeLock.upstreamCommit,
            "75e53afe568f7b6fabb1adc34894fe9f331d52f8"
        )
        XCTAssertEqual(LocalSemanticMNNRuntimeLock.frameworkVersion, "3.6.1")
        XCTAssertEqual(LocalSemanticMNNRuntimeLock.cpuThreadCount, 4)
        XCTAssertEqual(LocalSemanticMNNRuntimeLock.deviceArm64SHA256.count, 64)
        XCTAssertEqual(LocalSemanticMNNRuntimeLock.simulatorArm64SHA256.count, 64)
    }
}
