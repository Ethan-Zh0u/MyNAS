import SwiftUI

/// The first Stage F surface. It presents local PhotoKit records and MyNAS
/// records in one chronological grid, while keeping source-specific previews
/// and detail views intact. There is no export, deletion, or inferred matching.
struct UnifiedPhotoTimelineView: View {
    @ObservedObject var viewModel: UnifiedPhotoTimelineViewModel
    let account: AccountContext
    let localClient: PhotoLibraryClient
    let columns: [GridItem]
    let thumbnailTargetSize: CGSize

    private var timelineSections: [PhotoTimelineYearSection<UnifiedPhotoTimelineItem>] {
        PhotoTimelineYearSection.make(
            items: viewModel.items,
            date: { $0.captureDate }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            UnifiedTimelineStatusCard(
                items: viewModel.items,
                remoteState: viewModel.remoteState,
                isUsingOfflineCache: viewModel.isUsingOfflineCache,
                refresh: { Task { await viewModel.refreshRemote(account: account) } }
            )
            .padding(.horizontal, 10)

            PhotoTimelineYearGroupedGrid(
                sections: timelineSections,
                columns: columns,
                spacing: 2,
                date: { $0.captureDate },
                lastItemID: viewModel.items.last?.id,
                onLastItemAppear: {
                    Task { await viewModel.loadNextRemotePage(account: account) }
                }
            ) { item in
                timelineItem(item)
            }

            if viewModel.isLoadingNextPage {
                ProgressView("正在读取更多 MyNAS 项目…")
                    .font(.footnote)
                    .padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private func timelineItem(_ item: UnifiedPhotoTimelineItem) -> some View {
        if let localAsset = item.localAsset {
            NavigationLink {
                PhotoDetailView(
                    asset: localAsset,
                    isBackedUp: item.availability.hasVerifiedOriginals,
                    client: localClient,
                    contentRelationshipDescription: item.remoteAsset?.exactContentRelationshipDescription,
                    versionRelationshipDescription: item.remoteAsset?.versionTransitionRelationshipDescription
                )
            } label: {
                UnifiedTimelineCell(
                    item: item,
                    localClient: localClient,
                    remoteClient: viewModel.remoteClient,
                    account: account,
                    thumbnailTargetSize: thumbnailTargetSize
                )
            }
            .buttonStyle(.plain)
        } else if let remoteAsset = item.remoteAsset {
            NavigationLink {
                RemotePhotoDetailView(
                    asset: remoteAsset,
                    account: account,
                    client: viewModel.remoteClient
                )
            } label: {
                UnifiedTimelineCell(
                    item: item,
                    localClient: localClient,
                    remoteClient: viewModel.remoteClient,
                    account: account,
                    thumbnailTargetSize: thumbnailTargetSize
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct UnifiedTimelineStatusCard: View {
    let items: [UnifiedPhotoTimelineItem]
    let remoteState: UnifiedPhotoTimelineViewModel.RemoteState
    let isUsingOfflineCache: Bool
    let refresh: () -> Void

    private var localCount: Int { items.filter { $0.localAsset != nil }.count }
    private var remoteOnlyCount: Int { items.filter { $0.localAsset == nil && $0.remoteAsset != nil }.count }
    private var browseReadyCount: Int {
        items.filter { $0.availability == .browseReady }.count
    }
    private var exactContentRelationCount: Int {
        Set<String>(
            items.compactMap { item in
                guard let remoteAsset = item.remoteAsset,
                      remoteAsset.hasExactContentRelationship else {
                    return nil
                }
                return remoteAsset.id
            }
        ).count
    }
    private var versionTransitionRelationCount: Int {
        Set<String>(
            items.compactMap { item in
                guard let remoteAsset = item.remoteAsset,
                      remoteAsset.hasVersionTransitionRelationship else {
                    return nil
                }
                return remoteAsset.id
            }
        ).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.bubble.left")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("统一时间线")
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("刷新统一时间线中的 MyNAS 项目")
            }

            switch remoteState {
            case .loading:
                Label("正在合并 MyNAS 图库…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .ready where isUsingOfflineCache:
                Label("MyNAS 暂时不可达，正在使用已校验的离线目录", systemImage: "externaldrive.badge.icloud")
                    .font(.caption)
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
        .padding(14)
        .unifiedTimelineSurface()
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts = ["本机 \(localCount) 项", "可浏览备份 \(browseReadyCount) 项"]
        if remoteOnlyCount > 0 { parts.append("仅 MyNAS \(remoteOnlyCount) 项") }
        if exactContentRelationCount > 0 { parts.append("跨设备关联 \(exactContentRelationCount) 项") }
        if versionTransitionRelationCount > 0 { parts.append("版本关系 \(versionTransitionRelationCount) 项") }
        return parts.joined(separator: " · ")
    }
}

private struct UnifiedTimelineCell: View {
    let item: UnifiedPhotoTimelineItem
    let localClient: PhotoLibraryClient
    let remoteClient: RemotePhotoLibraryClient
    let account: AccountContext
    let thumbnailTargetSize: CGSize

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let localAsset = item.localAsset {
                PhotoGridCell(
                    asset: localAsset,
                    isBackedUp: item.availability.hasVerifiedOriginals,
                    isSelected: false,
                    targetSize: thumbnailTargetSize,
                    client: localClient
                )
            } else if let remoteAsset = item.remoteAsset {
                RemotePhotoGridCell(
                    asset: remoteAsset,
                    account: account,
                    client: remoteClient
                )
            }

            if shouldShowAvailabilityBadge {
                UnifiedTimelineAvailabilityBadge(availability: item.availability)
                    .padding(5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A verified local item already has the green check owned by
    /// `PhotoGridCell`. Showing the same success state in the unified wrapper
    /// would duplicate the meaning, while transitional and error states still
    /// need the top-right status badge.
    private var shouldShowAvailabilityBadge: Bool {
        guard item.localAsset != nil else { return true }
        switch item.availability {
        case .originalsVerified, .browseReady:
            return false
        default:
            return true
        }
    }

    private var accessibilityLabel: String {
        let relationshipDescriptions = [
            item.remoteAsset?.exactContentRelationshipDescription,
            item.remoteAsset?.versionTransitionRelationshipDescription,
        ]
        .compactMap { $0 }
        let relationshipSuffix = relationshipDescriptions.isEmpty
            ? ""
            : "，" + relationshipDescriptions.joined(separator: "，")
        return "\(item.displayMediaName)，\(item.availability.title)\(relationshipSuffix)"
    }
}

private struct UnifiedTimelineAvailabilityBadge: View {
    let availability: UnifiedPhotoTimelineAvailability

    var body: some View {
        Image(systemName: availability.systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(color.opacity(0.9), in: Circle())
            .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch availability {
        case .localOnly, .waitingForBackup, .preparingBackup:
            .gray
        case .uploading:
            .accentColor
        case .backupFailed:
            .red
        case .originalsVerified, .browseReady:
            .green
        case .remoteOnly(let isBrowseReady):
            isBrowseReady ? .teal : .orange
        }
    }
}

private extension View {
    @ViewBuilder
    func unifiedTimelineSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
