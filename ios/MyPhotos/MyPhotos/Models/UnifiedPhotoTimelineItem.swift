import Foundation

/// A read-only presentation record for the main timeline. A local and a remote
/// asset are joined only when this device's server-confirmed backup job names
/// the same MyNAS asset ID and still refers to the current local source version.
/// It deliberately does not infer a match from dates, filenames, or thumbnails.
enum UnifiedPhotoTimelineAvailability: Equatable, Sendable {
    case localOnly
    case waitingForBackup
    case preparingBackup
    case uploading
    case backupFailed(PhotoBackupFailureKind)
    case originalsVerified
    case browseReady
    case remoteOnly(isBrowseReady: Bool)

    var title: String {
        switch self {
        case .localOnly: "仅在本机"
        case .waitingForBackup: "等待备份"
        case .preparingBackup: "正在读取原件"
        case .uploading: "正在备份"
        case .backupFailed(let failure): failure.title
        case .originalsVerified: "原件已安全入库"
        case .browseReady: "已备份 · 可浏览"
        case .remoteOnly(let isBrowseReady): isBrowseReady ? "仅 MyNAS" : "MyNAS 正在处理"
        }
    }

    var systemImage: String {
        switch self {
        case .localOnly: "iphone"
        case .waitingForBackup: "clock"
        case .preparingBackup: "doc.badge.gearshape"
        case .uploading: "arrow.up.circle.fill"
        case .backupFailed: "exclamationmark.triangle.fill"
        case .originalsVerified: "checkmark.shield.fill"
        case .browseReady: "checkmark.circle.fill"
        case .remoteOnly(let isBrowseReady): isBrowseReady ? "externaldrive.fill" : "clock.badge.exclamationmark"
        }
    }

    var hasVerifiedOriginals: Bool {
        switch self {
        case .originalsVerified, .browseReady:
            true
        default:
            false
        }
    }
}

struct UnifiedPhotoTimelineItem: Identifiable, Sendable {
    let localAsset: LocalPhotoAsset?
    let remoteAsset: ServerPhotoAsset?
    let backupJob: PhotoBackupJob?
    let availability: UnifiedPhotoTimelineAvailability
    /// More than one physical Photos item can be deliberately associated with
    /// this exact MyNAS resource group (for example, a historical restore
    /// duplicate). The unified grid presents that group once; it never deletes
    /// or mutates the additional Photos items.
    let localCopyCount: Int

    var id: String {
        if let remoteAsset { return "linked-\(remoteAsset.id)" }
        if let localAsset { return "local-\(localAsset.localIdentifier)" }
        return "remote-\(remoteAsset?.id ?? "unknown")"
    }

    var displayMediaName: String {
        localAsset?.displayMediaName ?? remoteAsset?.displayMediaName ?? "照片"
    }

    var captureDate: Date? {
        if let date = localAsset?.creationDate { return date }
        guard let value = remoteAsset?.captureDate else { return nil }
        return Self.date(fromServerValue: value)
    }

    static func merge(
        localAssets: [LocalPhotoAsset],
        jobs: [PhotoBackupJob],
        accountID: String,
        remoteAssets: [ServerPhotoAsset]
    ) -> [UnifiedPhotoTimelineItem] {
        let currentJobsByLocalIdentifier = Dictionary(
            jobs
                .filter { $0.accountID == accountID }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteAssets.map { ($0.id, $0) })
        var matchedRemoteIDs = Set<String>()

        struct CurrentLocalRecord {
            let localAsset: LocalPhotoAsset
            let job: PhotoBackupJob?
            let remoteAsset: ServerPhotoAsset?
        }

        let currentLocalRecords = localAssets.map { localAsset -> CurrentLocalRecord in
            let job = currentJobsByLocalIdentifier[localAsset.localIdentifier]
            let isCurrentSource = job?.matchesCurrentLocalAsset(localAsset) == true
            let currentJob = isCurrentSource ? job : nil
            let remoteAsset = currentJob?.assetID.flatMap { remoteByID[$0] }
            return CurrentLocalRecord(
                localAsset: localAsset,
                job: currentJob,
                remoteAsset: remoteAsset
            )
        }

        let linkedRecordsByRemoteID = Dictionary(grouping: currentLocalRecords.compactMap { record in
            record.remoteAsset.map { ($0.id, record) }
        }, by: { $0.0 })

        linkedRecordsByRemoteID.keys.forEach { matchedRemoteIDs.insert($0) }
        var result = currentLocalRecords
            .filter { record in
                if case nil = record.remoteAsset { return true }
                return false
            }
            .map { record -> UnifiedPhotoTimelineItem in
                UnifiedPhotoTimelineItem(
                    localAsset: record.localAsset,
                    remoteAsset: nil,
                    backupJob: record.job,
                    availability: Self.availability(for: record.job, remoteAsset: nil),
                    localCopyCount: 1
                )
            }

        result.append(
            contentsOf: linkedRecordsByRemoteID.values.compactMap { linkedRecords in
                guard let remoteAsset = linkedRecords.first?.1.remoteAsset else { return nil }
                let primary = linkedRecords
                    .map(\.1)
                    .sorted {
                        if $0.job?.updatedAt != $1.job?.updatedAt {
                            return ($0.job?.updatedAt ?? .distantPast) > ($1.job?.updatedAt ?? .distantPast)
                        }
                        return $0.localAsset.localIdentifier < $1.localAsset.localIdentifier
                    }
                    .first
                guard let primary else { return nil }

                return UnifiedPhotoTimelineItem(
                    localAsset: primary.localAsset,
                    remoteAsset: remoteAsset,
                    backupJob: primary.job,
                    availability: Self.availability(for: primary.job, remoteAsset: remoteAsset),
                    localCopyCount: linkedRecords.count
                )
            }
        )

        result.append(
            contentsOf: remoteAssets
                .filter { !matchedRemoteIDs.contains($0.id) }
                .map {
                    UnifiedPhotoTimelineItem(
                        localAsset: nil,
                        remoteAsset: $0,
                        backupJob: nil,
                        availability: .remoteOnly(isBrowseReady: $0.browseReady),
                        localCopyCount: 0
                    )
                }
        )

        return result.sorted {
            switch ($0.captureDate, $1.captureDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.id < $1.id
            }
        }
    }

    private static func availability(
        for job: PhotoBackupJob?,
        remoteAsset: ServerPhotoAsset?
    ) -> UnifiedPhotoTimelineAvailability {
        guard let job else { return .localOnly }
        switch job.status {
        case .waiting:
            return .waitingForBackup
        case .preparing:
            return .preparingBackup
        case .uploading:
            return .uploading
        case .failed:
            return .backupFailed(job.failure?.kind ?? .unknown)
        case .completed:
            guard job.sourceState == .committed else { return .waitingForBackup }
            if remoteAsset?.browseReady == true { return .browseReady }
            return .originalsVerified
        }
    }

    private static func date(fromServerValue value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
