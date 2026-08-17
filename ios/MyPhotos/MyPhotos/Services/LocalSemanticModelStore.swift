import Foundation

/// Installs and validates app-global, on-device semantic model packages. It
/// accepts a pre-downloaded directory rather than owning a network endpoint:
/// a future downloader may choose its trusted distribution channel without
/// giving model bytes or arbitrary URLs to account-scoped photo indexing.
actor LocalSemanticModelStore {
    private static let directoryName = "SemanticModels"
    private static let stagingPrefix = ".staging-"
    private static let replacementBackupPrefix = ".replacement-"

    private let fileManager: FileManager
    private let applicationSupportRootOverride: URL?
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        applicationSupportRootOverride: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.applicationSupportRootOverride = applicationSupportRootOverride
        self.now = now
    }

    func status(
        for profile: LocalEmbeddingModelProfile
    ) throws -> LocalSemanticModelInstallStatus {
        guard let installation = try installation(for: profile, verifyDigests: false) else {
            return .notInstalled
        }
        return LocalSemanticModelInstallStatus(
            isInstalled: true,
            profile: installation.manifest.profile,
            runtime: installation.manifest.runtime,
            byteCount: installation.manifest.totalByteCount,
            installedAt: installation.installedAt
        )
    }

    /// Reports the capacity of the volume that will hold the protected model
    /// package. The caller must still use `install` for the final fail-closed
    /// space check, because available storage can change after this snapshot.
    func availableCapacityForImportantUsage() throws -> Int64? {
        let root = try storageRoot(create: true)
        let values = try root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Returns a package only after re-checking every declared byte count and
    /// SHA-256 digest. Call this before constructing a fresh native MNN model
    /// handle; an already resident engine may keep its verified handle alive.
    func verifiedInstallation(
        for profile: LocalEmbeddingModelProfile
    ) throws -> LocalSemanticModelInstallation? {
        try installation(for: profile, verifyDigests: true)
    }

    /// Activates only the App-owned Qwen/MNN package contract. A downloader may
    /// fetch the bytes, but it cannot alter the model identity, revision or
    /// file hashes accepted by the local semantic runtime.
    @discardableResult
    func installPinnedQwen3VLEmbedding2BInt8(
        packageDirectory: URL,
        progress: (@MainActor @Sendable (LocalSemanticModelOperationStage) -> Void)? = nil
    ) async throws -> LocalSemanticModelInstallStatus {
        try await install(
            packageDirectory: packageDirectory,
            manifest: LocalSemanticModelCatalog.qwen3VLEmbedding2BInt8Manifest,
            progress: progress
        )
    }

    /// Copies a complete pre-downloaded package into protected application
    /// storage only after every manifest file passes size and SHA-256 checks.
    /// The prior good package remains intact until the staged replacement is
    /// complete, so failed imports never leave a half-installed model active.
    @discardableResult
    func install(
        packageDirectory: URL,
        manifest: LocalSemanticModelPackageManifest,
        progress: (@MainActor @Sendable (LocalSemanticModelOperationStage) -> Void)? = nil
    ) async throws -> LocalSemanticModelInstallStatus {
        if let progress {
            await progress(.validatingDownloadedFiles)
        }
        try validateSourcePackage(packageDirectory, against: manifest)
        let root = try storageRoot(create: true)
        let target = root.appendingPathComponent(directoryName(for: manifest.profile), isDirectory: true)
        try recoverInterruptedReplacement(at: target)
        if let existing = try? installation(for: manifest.profile, verifyDigests: false),
           existing.manifest == manifest,
           (try? validateInstallation(existing, verifyDigests: true)) != nil {
            return try status(for: manifest.profile)
        }

        try ensureAvailableSpace(for: manifest.totalByteCount, at: root)
        if fileManager.fileExists(atPath: target.path) {
            try rejectSymbolicLink(at: target)
        }
        let staging = root.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: protectionAttributes
        )

        do {
            if let progress {
                await progress(.copyingToDevice)
            }
            for file in manifest.files {
                let source = try resolvedFileURL(file.relativePath, in: packageDirectory)
                let destination = try destinationFileURL(file.relativePath, in: staging)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: protectionAttributes
                )
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes(protectionAttributes, ofItemAtPath: destination.path)
            }

            let installedAt = now()
            let envelope = LocalSemanticModelInstallationEnvelope(
                schemaVersion: LocalSemanticModelInstallationEnvelope.schemaVersion,
                manifest: manifest,
                installedAt: installedAt
            )
            try writeEnvelope(envelope, in: staging)
            let stagedInstallation = LocalSemanticModelInstallation(
                manifest: manifest,
                directoryURL: staging,
                installedAt: installedAt
            )
            if let progress {
                await progress(.validatingInstallation)
            }
            try validateInstallation(stagedInstallation, verifyDigests: true)

            var replacementBackup: URL?
            if fileManager.fileExists(atPath: target.path) {
                try rejectSymbolicLink(at: target)
                let backup = replacementBackupURL(for: target)
                if fileManager.fileExists(atPath: backup.path) {
                    try rejectSymbolicLink(at: backup)
                    try fileManager.removeItem(at: backup)
                }
                try fileManager.moveItem(at: target, to: backup)
                replacementBackup = backup
            }
            do {
                try fileManager.moveItem(at: staging, to: target)
            } catch {
                if let replacementBackup,
                   !fileManager.fileExists(atPath: target.path),
                   fileManager.fileExists(atPath: replacementBackup.path) {
                    try? fileManager.moveItem(at: replacementBackup, to: target)
                }
                throw error
            }
            if let replacementBackup {
                try? fileManager.removeItem(at: replacementBackup)
            }
            return LocalSemanticModelInstallStatus(
                isInstalled: true,
                profile: manifest.profile,
                runtime: manifest.runtime,
                byteCount: manifest.totalByteCount,
                installedAt: installedAt
            )
        } catch let error as LocalSemanticModelPackageError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw LocalSemanticModelPackageError.packageUnavailable
        }
    }

    /// Deletes one shared model package. This has no effect on account-scoped
    /// semantic vectors; they remain unavailable until the same model is
    /// installed again or are separately deleted by their own lifecycle.
    @discardableResult
    func uninstall(_ profile: LocalEmbeddingModelProfile) throws -> Bool {
        let root = try storageRoot(create: false)
        let target = root.appendingPathComponent(directoryName(for: profile), isDirectory: true)
        try recoverInterruptedReplacement(at: target)
        guard fileManager.fileExists(atPath: target.path) else { return false }
        try rejectSymbolicLink(at: target)
        try fileManager.removeItem(at: target)
        return true
    }

    /// Removes incomplete installation directories left by a terminated import.
    /// Installed packages have deterministic hashed names and are untouched.
    @discardableResult
    func discardOrphanedStagingPackages() throws -> Int {
        let root = try storageRoot(create: false)
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        try rejectSymbolicLink(at: root)
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            // Staging directories intentionally begin with a dot so they do not
            // appear as user-facing model packages. Do not skip hidden files here:
            // interrupted installs must still be discoverable and removable.
            options: []
        )
        var removedCount = 0
        for child in children where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: child)
            removedCount += 1
        }
        return removedCount
    }

    private func installation(
        for profile: LocalEmbeddingModelProfile,
        verifyDigests: Bool
    ) throws -> LocalSemanticModelInstallation? {
        let root = try storageRoot(create: false)
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        try rejectSymbolicLink(at: root)
        let directory = root.appendingPathComponent(directoryName(for: profile), isDirectory: true)
        try recoverInterruptedReplacement(at: directory)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        try rejectSymbolicLink(at: directory)
        let envelopeURL = directory.appendingPathComponent(
            LocalSemanticModelInstallationEnvelope.filename,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: envelopeURL.path) else {
            throw LocalSemanticModelPackageError.corruptedInstallation
        }
        try rejectSymbolicLink(at: envelopeURL)

        let envelope: LocalSemanticModelInstallationEnvelope
        do {
            envelope = try JSONDecoder().decode(
                LocalSemanticModelInstallationEnvelope.self,
                from: Data(contentsOf: envelopeURL)
            )
        } catch let error as LocalSemanticModelPackageError {
            throw error
        } catch {
            throw LocalSemanticModelPackageError.corruptedInstallation
        }
        guard envelope.schemaVersion == LocalSemanticModelInstallationEnvelope.schemaVersion,
              envelope.manifest.profile == profile else {
            throw LocalSemanticModelPackageError.corruptedInstallation
        }
        let installation = LocalSemanticModelInstallation(
            manifest: envelope.manifest,
            directoryURL: directory,
            installedAt: envelope.installedAt
        )
        try validateInstallation(installation, verifyDigests: verifyDigests)
        return installation
    }

    private func validateSourcePackage(
        _ directory: URL,
        against manifest: LocalSemanticModelPackageManifest
    ) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LocalSemanticModelPackageError.packageUnavailable
        }
        let installation = LocalSemanticModelInstallation(
            manifest: manifest,
            directoryURL: directory,
            installedAt: .distantPast
        )
        try validateInstallation(installation, verifyDigests: true)
    }

    private func validateInstallation(
        _ installation: LocalSemanticModelInstallation,
        verifyDigests: Bool
    ) throws {
        try rejectSymbolicLink(at: installation.directoryURL)
        for file in installation.manifest.files {
            let url: URL
            do {
                url = try resolvedFileURL(file.relativePath, in: installation.directoryURL)
            } catch let error as LocalSemanticModelPackageError {
                if error == .packageFileMissing(file.relativePath) {
                    throw LocalSemanticModelPackageError.corruptedInstallation
                }
                throw error
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == file.byteCount else {
                throw LocalSemanticModelPackageError.packageFileInvalid(file.relativePath)
            }
            if verifyDigests {
                guard try FileSHA256.digest(of: url) == file.sha256 else {
                    throw LocalSemanticModelPackageError.packageFileInvalid(file.relativePath)
                }
            }
        }
    }

    private func storageRoot(create: Bool) throws -> URL {
        let applicationSupport: URL
        if let applicationSupportRootOverride {
            applicationSupport = applicationSupportRootOverride
        } else if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            applicationSupport = url
        } else {
            throw LocalSemanticModelPackageError.packageUnavailable
        }
        let root = applicationSupport.appendingPathComponent(Self.directoryName, isDirectory: true)
        if create {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: protectionAttributes
            )
        }
        return root
    }

    private var protectionAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private func directoryName(for profile: LocalEmbeddingModelProfile) -> String {
        let material = [
            profile.modelIdentifier,
            profile.modelRevision,
            profile.quantization,
            String(profile.dimension),
        ].joined(separator: "\u{0}")
        return "model-" + String(FileSHA256.digest(of: Data(material.utf8)).prefix(24))
    }

    private func resolvedFileURL(_ relativePath: String, in directory: URL) throws -> URL {
        var current = directory
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            guard fileManager.fileExists(atPath: current.path) else {
                throw LocalSemanticModelPackageError.packageFileMissing(relativePath)
            }
            try rejectSymbolicLink(at: current)
        }
        return current
    }

    private func destinationFileURL(_ relativePath: String, in directory: URL) throws -> URL {
        let components = relativePath.split(separator: "/")
        guard let last = components.last else {
            throw LocalSemanticModelPackageError.invalidManifest
        }
        var parent = directory
        for component in components.dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
        }
        return parent.appendingPathComponent(String(last), isDirectory: false)
    }

    private func writeEnvelope(
        _ envelope: LocalSemanticModelInstallationEnvelope,
        in directory: URL
    ) throws {
        let url = directory.appendingPathComponent(
            LocalSemanticModelInstallationEnvelope.filename,
            isDirectory: false
        )
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func ensureAvailableSpace(for packageByteCount: Int64, at root: URL) throws {
        let (requiredByteCount, overflow) = packageByteCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw LocalSemanticModelPackageError.invalidManifest }
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < requiredByteCount {
            throw LocalSemanticModelPackageError.insufficientDiskSpace(
                requiredByteCount: requiredByteCount
            )
        }
    }

    /// A replacement moves the prior verified package aside before activating
    /// the fully validated staging directory. If the app is terminated in that
    /// narrow window, restore the known-good backup before reporting status or
    /// accepting another lifecycle operation.
    private func recoverInterruptedReplacement(at target: URL) throws {
        let backup = replacementBackupURL(for: target)
        guard fileManager.fileExists(atPath: backup.path) else { return }
        try rejectSymbolicLink(at: backup)
        if fileManager.fileExists(atPath: target.path) {
            try rejectSymbolicLink(at: target)
            try fileManager.removeItem(at: backup)
        } else {
            try fileManager.moveItem(at: backup, to: target)
        }
    }

    private func replacementBackupURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            Self.replacementBackupPrefix + target.lastPathComponent,
            isDirectory: true
        )
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw LocalSemanticModelPackageError.unsafeStoragePath
        }
    }
}
