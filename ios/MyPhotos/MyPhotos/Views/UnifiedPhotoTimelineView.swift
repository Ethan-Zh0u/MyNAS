import SwiftUI

/// The first Stage F surface. It presents local PhotoKit records and MyNAS
/// records in one chronological grid, while keeping source-specific previews
/// and detail views intact. There is no export, deletion, or inferred matching.
struct UnifiedPhotoTimelineView: View {
    @ObservedObject var viewModel: UnifiedPhotoTimelineViewModel
    let account: AccountContext
    let localClient: PhotoLibraryClient
    let backupCoordinator: PhotoBackupCoordinator
    let columns: [GridItem]
    let thumbnailTargetSize: CGSize
    @State private var presentedRemoteAsset: ServerPhotoAsset?
    /// The visible local grid is paged, but duplicate prevention must also see
    /// older Photos items. This reads metadata only; resource export starts
    /// solely after the user explicitly chooses verification in remote detail.
    @State private var verificationLocalAssets: [LocalPhotoAsset] = []

    private var localAssetsForVerification: [LocalPhotoAsset] {
        verificationLocalAssets.isEmpty
            ? viewModel.currentLocalAssets
            : verificationLocalAssets
    }

    private var timelineSections: [PhotoTimelineYearSection<UnifiedPhotoTimelineItem>] {
        PhotoTimelineYearSection.make(
            items: viewModel.items,
            date: { $0.captureDate }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            remoteAvailabilityNotice

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
        // See RemotePhotoLibraryView: keep remote detail UIKit-only on iOS 27.
        .fullScreenCover(item: $presentedRemoteAsset) { asset in
            RemotePhotoDetailUIKitHost(
                asset: asset,
                account: account,
                client: viewModel.remoteClient,
                localClient: localClient,
                localAssets: localAssetsForVerification,
                confirmedLocalCopy: nil,
                onVerifiedLocalCopies: { remoteAsset, localAssets in
                    backupCoordinator.registerVerifiedLocalCopies(
                        localAssets,
                        expectedRemoteAssetID: remoteAsset.id,
                        account: account,
                        client: localClient
                    )
                },
                onRemoteDeleted: { assetID, localDisposition in
                    backupCoordinator.markRemoteBackupDeleted(
                        assetID: assetID,
                        accountID: account.accountID,
                        localDisposition: localDisposition
                    )
                    Task { await viewModel.refreshRemote(account: account) }
                },
                onDismiss: { presentedRemoteAsset = nil }
            )
        }
        .task(id: account.accountID) {
            verificationLocalAssets = await localClient.allAccessibleAssets()
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
            Button {
                presentedRemoteAsset = remoteAsset
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

    @ViewBuilder
    private var remoteAvailabilityNotice: some View {
        switch viewModel.remoteState {
        case .failed:
            Label("请检查 Tailscale 连接", systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        case .ready where viewModel.isUsingOfflineCache:
            Label("MyNAS 暂时不可达，正在使用已校验的离线目录", systemImage: "externaldrive.badge.icloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        default:
            EmptyView()
        }
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
                    client: remoteClient,
                    hasConfirmedLocalCopy: false
                )
            }

            if shouldShowAvailabilityBadge {
                UnifiedTimelineAvailabilityBadge(availability: item.availability)
                    .padding(5)
            }

            if item.localCopyCount > 1 {
                Text("\(item.localCopyCount) 份")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .accessibilityHidden(true)
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
        let localCopySuffix = item.localCopyCount > 1
            ? "，已合并 \(item.localCopyCount) 份同一原件的本机副本"
            : ""
        return "\(item.displayMediaName)，\(item.availability.title)\(localCopySuffix)\(relationshipSuffix)"
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
