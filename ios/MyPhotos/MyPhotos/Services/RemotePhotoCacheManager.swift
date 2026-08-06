import Foundation

/// A summary of one account's app-private remote-media cache. The values never
/// include Photos-library media or any file stored by MyNAS.
nonisolated struct RemotePhotoCacheUsage: Equatable, Sendable {
    let totalByteCount: Int64
    let entryCount: Int
    let byteCountByKind: [CacheDirectoryKind: Int64]

    static let empty = RemotePhotoCacheUsage(
        totalByteCount: 0,
        entryCount: 0,
        byteCountByKind: [:]
    )

    func byteCount(for kind: CacheDirectoryKind) -> Int64 {
        byteCountByKind[kind] ?? 0
    }
}

nonisolated struct RemotePhotoCacheTrimResult: Equatable, Sendable {
    let removedByteCount: Int64
    let removedEntryCount: Int
    let remainingUsage: RemotePhotoCacheUsage
}

/// Owns cache inspection and eviction for exactly one account namespace at a
/// time. The manager only sees files below `AppCache/<server>/<user>` and never
/// reaches into PhotoKit, the share sheet, or MyNAS storage.
actor RemotePhotoCacheManager {
    private struct CacheEntry {
        let urls: [URL]
        let kind: CacheDirectoryKind
        let byteCount: Int64
        let lastAccessDate: Date
    }

    private let directories: CacheDirectoryProvider
    private let fileManager: FileManager

    init(
        directories: CacheDirectoryProvider = CacheDirectoryProvider(),
        fileManager: FileManager = .default
    ) {
        self.directories = directories
        self.fileManager = fileManager
    }

    func usage(for account: AccountContext) throws -> RemotePhotoCacheUsage {
        guard let root = try directories.existingRootDirectory(for: account) else {
            return .empty
        }

        var totalByteCount: Int64 = 0
        var entryCount = 0
        var byteCountByKind: [CacheDirectoryKind: Int64] = [:]
        for kind in CacheDirectoryKind.allCases {
            let entries = try cacheEntries(in: root, kind: kind)
            let kindByteCount = entries.reduce(Int64(0)) { $0 + $1.byteCount }
            totalByteCount += kindByteCount
            entryCount += entries.count
            if kindByteCount > 0 {
                byteCountByKind[kind] = kindByteCount
            }
        }
        return RemotePhotoCacheUsage(
            totalByteCount: totalByteCount,
            entryCount: entryCount,
            byteCountByKind: byteCountByKind
        )
    }

    /// Keeps the newest cache entries up to `maximumByteCount`. Complete
    /// temporary downloads are removed first, then previews, thumbnails and
    /// finally metadata. Within each class the least-recently-used entry wins.
    func trim(
        account: AccountContext,
        maximumByteCount: Int64
    ) throws -> RemotePhotoCacheTrimResult {
        guard maximumByteCount >= 0 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard let root = try directories.existingRootDirectory(for: account) else {
            return RemotePhotoCacheTrimResult(
                removedByteCount: 0,
                removedEntryCount: 0,
                remainingUsage: .empty
            )
        }

        var entries: [CacheEntry] = []
        for kind in CacheDirectoryKind.allCases {
            entries.append(contentsOf: try cacheEntries(in: root, kind: kind))
        }
        var remainingByteCount = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard remainingByteCount > maximumByteCount else {
            return RemotePhotoCacheTrimResult(
                removedByteCount: 0,
                removedEntryCount: 0,
                remainingUsage: try usage(for: account)
            )
        }

        var removedByteCount: Int64 = 0
        var removedEntryCount = 0
        for entry in entries.sorted(by: evictionOrder) where remainingByteCount > maximumByteCount {
            for url in entry.urls {
                try fileManager.removeItem(at: url)
            }
            remainingByteCount -= entry.byteCount
            removedByteCount += entry.byteCount
            removedEntryCount += 1
        }
        return RemotePhotoCacheTrimResult(
            removedByteCount: removedByteCount,
            removedEntryCount: removedEntryCount,
            remainingUsage: try usage(for: account)
        )
    }

    /// Clears only the selected account's app cache. A local Photos asset, a
    /// user-exported file, and every MyNAS original sit outside this root and
    /// are therefore unaffected.
    func clear(account: AccountContext) throws -> RemotePhotoCacheTrimResult {
        let before = try usage(for: account)
        guard let root = try directories.existingRootDirectory(for: account) else {
            return RemotePhotoCacheTrimResult(
                removedByteCount: 0,
                removedEntryCount: 0,
                remainingUsage: .empty
            )
        }
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
        return RemotePhotoCacheTrimResult(
            removedByteCount: before.totalByteCount,
            removedEntryCount: before.entryCount,
            remainingUsage: .empty
        )
    }

    /// A verified original download is useful only while its import or share
    /// activity is alive. Neither operation can survive a process restart, so
    /// every non-symlink child left in this account's temporary-downloads
    /// directory at the next launch is an orphan. Keep this narrower than
    /// `clear(account:)`: previews, thumbnails and metadata remain untouched.
    func discardOrphanedTemporaryDownloads(
        account: AccountContext
    ) throws -> RemotePhotoCacheTrimResult {
        guard let root = try directories.existingRootDirectory(for: account) else {
            return RemotePhotoCacheTrimResult(
                removedByteCount: 0,
                removedEntryCount: 0,
                remainingUsage: .empty
            )
        }
        let directory = root.appendingPathComponent(
            CacheDirectoryKind.temporaryDownloads.rawValue,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return RemotePhotoCacheTrimResult(
                removedByteCount: 0,
                removedEntryCount: 0,
                remainingUsage: try usage(for: account)
            )
        }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        )
        var removedByteCount: Int64 = 0
        var removedEntryCount = 0
        for child in children {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            removedByteCount += try cacheEntry(
                urls: [child],
                kind: .temporaryDownloads
            )?.byteCount ?? 0
            try fileManager.removeItem(at: child)
            removedEntryCount += 1
        }
        return RemotePhotoCacheTrimResult(
            removedByteCount: removedByteCount,
            removedEntryCount: removedEntryCount,
            remainingUsage: try usage(for: account)
        )
    }

    private func cacheEntries(
        in root: URL,
        kind: CacheDirectoryKind
    ) throws -> [CacheEntry] {
        let directory = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        if kind == .temporaryDownloads {
            return try temporaryDownloadEntries(in: directory)
        }

        let files = try regularFiles(in: directory)
        var grouped: [String: [URL]] = [:]
        for file in files {
            let key = file.deletingLastPathComponent().path + "/" + file.deletingPathExtension().lastPathComponent
            grouped[key, default: []].append(file)
        }
        return try grouped.values.compactMap { urls in
            try cacheEntry(urls: urls, kind: kind)
        }
    }

    private func temporaryDownloadEntries(in directory: URL) throws -> [CacheEntry] {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try children.compactMap { child in
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return nil }
            return try cacheEntry(urls: [child], kind: .temporaryDownloads)
        }
    }

    private func cacheEntry(
        urls: [URL],
        kind: CacheDirectoryKind
    ) throws -> CacheEntry? {
        var byteCount: Int64 = 0
        var newestAccess = Date.distantPast
        var hasFiles = false
        for url in urls {
            let files: [URL]
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                files = try regularFiles(in: url)
            } else {
                files = [url]
            }
            for file in files {
                let fileValues = try file.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
                ])
                guard fileValues.isRegularFile == true else { continue }
                byteCount += Int64(fileValues.fileSize ?? 0)
                newestAccess = max(newestAccess, fileValues.contentModificationDate ?? .distantPast)
                hasFiles = true
            }
        }
        guard hasFiles else { return nil }
        return CacheEntry(
            urls: urls,
            kind: kind,
            byteCount: byteCount,
            lastAccessDate: newestAccess
        )
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true else {
                continue
            }
            files.append(url)
        }
        return files
    }

    private func evictionOrder(_ left: CacheEntry, _ right: CacheEntry) -> Bool {
        let leftPriority = evictionPriority(for: left.kind)
        let rightPriority = evictionPriority(for: right.kind)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        if left.lastAccessDate != right.lastAccessDate {
            return left.lastAccessDate < right.lastAccessDate
        }
        return left.urls.map(\.path).joined(separator: "|") < right.urls.map(\.path).joined(separator: "|")
    }

    private func evictionPriority(for kind: CacheDirectoryKind) -> Int {
        switch kind {
        case .temporaryDownloads: 0
        case .previews, .livePhotos: 1
        case .thumbnails: 2
        case .metadata: 3
        case .searchIndex: 4
        case .analysisQueue: 5
        }
    }
}
