import Foundation
import XCTest
@testable import MyPhotos

@MainActor
final class LocalSemanticModelStoreTests: XCTestCase {
    func testInstallCopiesVerifiedSharedModelAndUninstallLeavesNoPackage() async throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let profile = try makeProfile()
        let manifest = try makePackage(at: source, profile: profile)
        let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalSemanticModelStore(
            applicationSupportRootOverride: applicationSupport,
            now: { installedAt }
        )

        let installed = try await store.install(packageDirectory: source, manifest: manifest)
        XCTAssertTrue(installed.isInstalled)
        XCTAssertEqual(installed.profile, profile)
        XCTAssertEqual(installed.runtime, .mnnQwen3VLEmbedding)
        XCTAssertEqual(installed.byteCount, manifest.totalByteCount)
        XCTAssertEqual(installed.installedAt, installedAt)

        let verifiedInstallation = try await store.verifiedInstallation(for: profile)
        let installation = try XCTUnwrap(verifiedInstallation)
        XCTAssertEqual(installation.manifest, manifest)
        XCTAssertEqual(installation.installedAt, installedAt)
        XCTAssertFalse(installation.directoryURL.path.hasPrefix(source.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installation.directoryURL.appendingPathComponent("embedding.mnn").path
            )
        )

        let envelopeURL = installation.directoryURL.appendingPathComponent("installation.json")
        let rawEnvelope = try JSONSerialization.jsonObject(with: Data(contentsOf: envelopeURL)) as? [String: Any]
        let envelopeKeys = Set(rawEnvelope?.keys.map { $0 } ?? [])
        XCTAssertEqual(envelopeKeys, Set(["schemaVersion", "manifest", "installedAt"]))
        XCTAssertFalse(rawEnvelope?.keys.contains("sourceURL") == true)
        XCTAssertFalse(rawEnvelope?.keys.contains("accountID") == true)

        try FileManager.default.removeItem(at: source)
        let installationAfterSourceDeletion = try await store.verifiedInstallation(for: profile)
        XCTAssertNotNil(installationAfterSourceDeletion)
        let wasUninstalled = try await store.uninstall(profile)
        XCTAssertTrue(wasUninstalled)
        let statusAfterUninstall = try await store.status(for: profile)
        XCTAssertEqual(statusAfterUninstall, .notInstalled)
    }

    func testTamperedSourceCannotReplaceCurrentVerifiedPackage() async throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let profile = try makeProfile()
        let manifest = try makePackage(at: source, profile: profile)
        let store = LocalSemanticModelStore(applicationSupportRootOverride: applicationSupport)
        _ = try await store.install(packageDirectory: source, manifest: manifest)

        let sourceEmbedding = source.appendingPathComponent("embedding.mnn")
        try Data("tampered".utf8).write(to: sourceEmbedding, options: .atomic)
        do {
            _ = try await store.install(packageDirectory: source, manifest: manifest)
            XCTFail("A source file with the wrong digest must be rejected")
        } catch let error as LocalSemanticModelPackageError {
            XCTAssertEqual(error, .packageFileInvalid("embedding.mnn"))
        }
        let survivingInstallation = try await store.verifiedInstallation(for: profile)
        XCTAssertNotNil(survivingInstallation)
    }

    func testCorruptedInstalledPackageCanBeRepairedFromMatchingVerifiedSource() async throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let profile = try makeProfile()
        let manifest = try makePackage(at: source, profile: profile)
        let store = LocalSemanticModelStore(applicationSupportRootOverride: applicationSupport)
        _ = try await store.install(packageDirectory: source, manifest: manifest)
        let verifiedInstallation = try await store.verifiedInstallation(for: profile)
        let installation = try XCTUnwrap(verifiedInstallation)

        try Data("corrupted".utf8).write(
            to: installation.directoryURL.appendingPathComponent("visual.mnn"),
            options: .atomic
        )
        do {
            _ = try await store.verifiedInstallation(for: profile)
            XCTFail("Tampering with an installed file must be detected")
        } catch let error as LocalSemanticModelPackageError {
            XCTAssertEqual(error, .packageFileInvalid("visual.mnn"))
        }

        let repaired = try await store.install(packageDirectory: source, manifest: manifest)
        XCTAssertTrue(repaired.isInstalled)
        let repairedInstallation = try await store.verifiedInstallation(for: profile)
        XCTAssertNotNil(repairedInstallation)
    }

    func testManifestTraversalAndSymlinkedSourceAreRejected() async throws {
        XCTAssertThrowsError(
            try LocalSemanticModelPackageFile(
                relativePath: "../embedding.mnn",
                byteCount: 1,
                sha256: String(repeating: "0", count: 64)
            )
        )

        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let profile = try makeProfile()
        let manifest = try makePackage(at: source, profile: profile)
        let target = source.appendingPathComponent("original-embedding.mnn")
        let link = source.appendingPathComponent("embedding.mnn")
        try FileManager.default.moveItem(at: link, to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = LocalSemanticModelStore(applicationSupportRootOverride: applicationSupport)

        do {
            _ = try await store.install(packageDirectory: source, manifest: manifest)
            XCTFail("A symlink may not enter the installed model package")
        } catch let error as LocalSemanticModelPackageError {
            XCTAssertEqual(error, .unsafeStoragePath)
        }
    }

    func testDiscardOrphanedStagingPackagesDoesNotTouchInstalledPackage() async throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let profile = try makeProfile()
        let manifest = try makePackage(at: source, profile: profile)
        let store = LocalSemanticModelStore(applicationSupportRootOverride: applicationSupport)
        _ = try await store.install(packageDirectory: source, manifest: manifest)

        let staging = applicationSupport
            .appendingPathComponent("SemanticModels", isDirectory: true)
            .appendingPathComponent(".staging-interrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let discardedCount = try await store.discardOrphanedStagingPackages()
        XCTAssertEqual(discardedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let installedAfterCleanup = try await store.verifiedInstallation(for: profile)
        XCTAssertNotNil(installedAfterCleanup)
    }

    func testVerifiedInstallationRestoresInterruptedReplacementBeforeReportingStatus() async throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let profile = try makeProfile()
        let manifest = try makePackage(at: source, profile: profile)
        let store = LocalSemanticModelStore(applicationSupportRootOverride: applicationSupport)
        _ = try await store.install(packageDirectory: source, manifest: manifest)
        let verifiedInstallation = try await store.verifiedInstallation(for: profile)
        let installation = try XCTUnwrap(verifiedInstallation)
        let target = installation.directoryURL
        let backup = target.deletingLastPathComponent().appendingPathComponent(
            ".replacement-\(target.lastPathComponent)",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: target, to: backup)

        let recovered = try await store.verifiedInstallation(for: profile)

        XCTAssertNotNil(recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPinnedInstallerRejectsAFileThatDoesNotMatchTheAppOwnedCatalog() async throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let source = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let applicationSupport = temporaryRoot.appendingPathComponent("app-support", isDirectory: true)
        let arbitraryProfile = try makeProfile()
        _ = try makePackage(at: source, profile: arbitraryProfile)
        let store = LocalSemanticModelStore(applicationSupportRootOverride: applicationSupport)

        do {
            _ = try await store.installPinnedQwen3VLEmbedding2BInt8(packageDirectory: source)
            XCTFail("The fixed catalog must reject a package with arbitrary test bytes")
        } catch let error as LocalSemanticModelPackageError {
            XCTAssertEqual(error, .packageFileInvalid("config.json"))
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    private func makeProfile() throws -> LocalEmbeddingModelProfile {
        try LocalEmbeddingModelProfile(
            modelIdentifier: "Qwen3-VL-Embedding-2B",
            modelRevision: "mnn-int8-test-r1",
            dimension: 2_048,
            quantization: "int8"
        )
    }

    private func makePackage(
        at directory: URL,
        profile: LocalEmbeddingModelProfile
    ) throws -> LocalSemanticModelPackageManifest {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payloads: [(String, Data)] = [
            ("config.json", Data("{}".utf8)),
            ("embedding.mnn", Data("embedding-model".utf8)),
            ("embedding.mnn.json", Data("{}".utf8)),
            ("embedding.mnn.weight", Data("embedding-weights".utf8)),
            ("embeddings_int8.bin", Data("embedding-table".utf8)),
            ("llm_config.json", Data("{}".utf8)),
            ("tokenizer.mtok", Data("tokenizer".utf8)),
            ("visual.mnn", Data("visual-model".utf8)),
            ("visual.mnn.weight", Data("visual-weights".utf8)),
        ]
        var files: [LocalSemanticModelPackageFile] = []
        for (path, data) in payloads {
            let url = directory.appendingPathComponent(path)
            try data.write(to: url, options: .atomic)
            files.append(
                try LocalSemanticModelPackageFile(
                    relativePath: path,
                    byteCount: Int64(data.count),
                    sha256: FileSHA256.digest(of: data)
                )
            )
        }
        return try LocalSemanticModelPackageManifest(
            runtime: .mnnQwen3VLEmbedding,
            profile: profile,
            files: files
        )
    }
}
