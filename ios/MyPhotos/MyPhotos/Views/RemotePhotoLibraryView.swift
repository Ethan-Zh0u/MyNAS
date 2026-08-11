import AVKit
import SwiftUI

nonisolated enum RemotePhotoDownloadPolicy {
    static func offersOriginalDownload(hasConfirmedLocalCopy: Bool) -> Bool {
        !hasConfirmedLocalCopy
    }
}

struct RemotePhotoLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: RemotePhotoLibraryViewModel
    @AppStorage("remotePhotoGridColumnCount") private var columnCount = 4
    @State private var pinchStartColumnCount: Int?
    @State private var presentedRemoteAsset: ServerPhotoAsset?
    @State private var verificationLocalAssets: [LocalPhotoAsset] = []
    @State private var confirmedRemoteAssetIDs: Set<String> = []
    private let localClient: PhotoLibraryClient
    private let backupCoordinator: PhotoBackupCoordinator
    private let localAssets: [LocalPhotoAsset]
    private let backupJobs: [PhotoBackupJob]

    private let minimumColumnCount = 2
    private let maximumColumnCount = 10
    private let gridSpacing: CGFloat = 2

    init(
        account: AccountContext,
        localClient: PhotoLibraryClient,
        backupCoordinator: PhotoBackupCoordinator,
        localAssets: [LocalPhotoAsset],
        backupJobs: [PhotoBackupJob]
    ) {
        self.localClient = localClient
        self.backupCoordinator = backupCoordinator
        self.localAssets = localAssets
        self.backupJobs = backupJobs
        _viewModel = StateObject(
            wrappedValue: RemotePhotoLibraryViewModel(account: account)
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: gridSpacing),
            count: columnCount
        )
    }

    /// The legacy mapping endpoint may not be available on an older MyNAS.
    /// Resolve the persisted job's local identifier directly instead of using
    /// the timeline's first loaded page, which could otherwise miss an older
    /// but still accessible local original.
    private func confirmedLocalCopy(for remoteAsset: ServerPhotoAsset) -> LocalPhotoAsset? {
        return backupJobs
            .filter {
                $0.accountID == viewModel.account.accountID
                    && $0.status == .completed
                    && $0.sourceState == .committed
                    && $0.assetID == remoteAsset.id
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { job in
                guard let localAsset = localClient.accessibleAsset(
                    localIdentifier: job.localIdentifier
                ),
                      job.matchesCurrentLocalAsset(localAsset) else {
                    return nil
                }
                return localAsset
            }
            .first
    }

    private var localAssetsForVerification: [LocalPhotoAsset] {
        verificationLocalAssets.isEmpty ? localAssets : verificationLocalAssets
    }

    private func refreshLocalCopyState() async {
        confirmedRemoteAssetIDs = Set(
            backupJobs.compactMap { job in
                guard job.accountID == viewModel.account.accountID,
                      job.status == .completed,
                      job.sourceState == .committed,
                      let remoteAssetID = job.assetID,
                      let localAsset = localClient.accessibleAsset(
                        localIdentifier: job.localIdentifier
                      ),
                      job.matchesCurrentLocalAsset(localAsset) else {
                    return nil
                }
                return remoteAssetID
            }
        )
        verificationLocalAssets = await localClient.allAccessibleAssets()
        backupCoordinator.reconcileVerifiedRemoteCopies(
            remoteAssets: viewModel.assets,
            localAssets: verificationLocalAssets,
            account: viewModel.account,
            client: localClient
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView("正在读取 MyNAS 图库…")
            case .loading where viewModel.assets.isEmpty:
                ProgressView("正在读取 MyNAS 图库…")
            case .empty:
                ContentUnavailableView(
                    "MyNAS 图库还是空的",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("先完成至少一项备份；衍生预览生成后会自动出现在这里。")
                )
            case .failed:
                ContentUnavailableView {
                    Label("无法读取 MyNAS 图库", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("请检查 Tailscale 连接")
                } actions: {
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            default:
                libraryContent
            }
        }
        .navigationTitle("MyNAS 图库")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .accessibilityLabel("刷新 MyNAS 图库")
            }
        }
        // Keep this presentation boundary UIKit-only. iOS 27's SwiftUI runtime
        // crashes while it constructs the former remote-detail view tree.
        .fullScreenCover(item: $presentedRemoteAsset) { asset in
            RemotePhotoDetailUIKitHost(
                asset: asset,
                account: viewModel.account,
                client: viewModel.client,
                localClient: localClient,
                localAssets: localAssetsForVerification,
                confirmedLocalCopy: confirmedLocalCopy(for: asset),
                onVerifiedLocalCopies: { remoteAsset, localAssets in
                    backupCoordinator.registerVerifiedLocalCopies(
                        localAssets,
                        expectedRemoteAssetID: remoteAsset.id,
                        account: viewModel.account,
                        client: localClient
                    )
                },
                onRemoteDeleted: { assetID, localDisposition in
                    backupCoordinator.markRemoteBackupDeleted(
                        assetID: assetID,
                        accountID: viewModel.account.accountID,
                        localDisposition: localDisposition
                    )
                    viewModel.removeDeletedAsset(id: assetID)
                },
                onDismiss: { presentedRemoteAsset = nil }
            )
        }
        .task {
            await viewModel.start()
            await refreshLocalCopyState()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await viewModel.checkForRemoteChanges()
            }
        }
        .onChange(of: viewModel.assets) { _, assets in
            backupCoordinator.reconcileVerifiedRemoteCopies(
                remoteAssets: assets,
                localAssets: localAssetsForVerification,
                account: viewModel.account,
                client: localClient
            )
        }
    }

    private var libraryContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                RemoteLibraryStatusCard(
                    count: viewModel.assets.count,
                    serverName: viewModel.account.displayName,
                    isUsingOfflineCache: viewModel.isUsingOfflineCache,
                    pendingChangeCount: viewModel.pendingChangeCount,
                    requiresFullRefresh: viewModel.requiresFullRefresh,
                    refresh: { Task { await viewModel.refresh() } }
                )
                .padding(.horizontal, 10)
                .padding(.top, 2)

                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.assets) { asset in
                        Button {
                            presentedRemoteAsset = asset
                        } label: {
                            RemotePhotoGridCell(
                                asset: asset,
                                account: viewModel.account,
                                client: viewModel.client,
                                hasConfirmedLocalCopy: confirmedRemoteAssetIDs.contains(asset.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if asset.id == viewModel.assets.last?.id {
                                Task { await viewModel.loadNextPage() }
                            }
                        }
                        .accessibilityLabel("打开 MyNAS 中的\(asset.displayMediaName)")
                    }
                }
                .padding(.horizontal, gridSpacing)

                if viewModel.isLoadingNextPage {
                    ProgressView()
                        .padding(.vertical, 20)
                } else if let message = viewModel.paginationErrorMessage {
                    VStack(spacing: 8) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试加载下一页") {
                            Task { await viewModel.retryNextPage() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        .simultaneousGesture(gridMagnificationGesture, including: .gesture)
        .sensoryFeedback(.selection, trigger: columnCount)
    }

    private var gridMagnificationGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                if pinchStartColumnCount == nil {
                    pinchStartColumnCount = columnCount
                }
                guard let startingColumns = pinchStartColumnCount else { return }
                let proposed = Int(
                    (CGFloat(startingColumns) / value.magnification).rounded()
                )
                let clamped = min(maximumColumnCount, max(minimumColumnCount, proposed))
                guard clamped != columnCount else { return }
                if reduceMotion {
                    columnCount = clamped
                } else {
                    withAnimation(.snappy(duration: 0.18)) {
                        columnCount = clamped
                    }
                }
            }
            .onEnded { _ in
                pinchStartColumnCount = nil
            }
    }
}

/// Remote-item details are presented outside the grid's scroll and magnify
/// gesture tree. This keeps a problematic remote item from blocking the
/// MyNAS gallery's navigation interaction on iOS 27.
struct RemotePhotoDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    let localClient: PhotoLibraryClient
    let onRemoteDeleted: (String, PhotoBackupRemoteDeletionLocalDisposition) -> Void

    /// Keep the presentation boundary erased. On iOS 27 this avoids a Swift
    /// runtime generic-metadata crash while the full-screen detail is built.
    var body: AnyView {
        AnyView(
            NavigationStack {
                RemotePhotoDetailView(
                    asset: asset,
                    account: account,
                    client: client,
                    localClient: localClient,
                    onRemoteDeleted: onRemoteDeleted
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", action: dismiss.callAsFunction)
                    }
                }
            }
        )
    }
}

private struct RemoteLibraryStatusCard: View {
    let count: Int
    let serverName: String
    let isUsingOfflineCache: Bool
    let pendingChangeCount: Int
    let requiresFullRefresh: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isUsingOfflineCache ? "externaldrive.badge.icloud" : "externaldrive.fill.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(isUsingOfflineCache ? .orange : .green)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isUsingOfflineCache ? "正在显示离线缓存" : "来自你的 MyNAS")
                        .font(.subheadline.weight(.semibold))
                    Text("\(serverName) · 已读取 \(count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("受控操作")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
            if pendingChangeCount > 0 {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: requiresFullRefresh ? "arrow.triangle.2.circlepath" : "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text(changeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("刷新", action: refresh)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .remoteLibrarySurface(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }

    private var changeText: String {
        if requiresFullRefresh { return "MyNAS 图库记录已更新，请刷新" }
        return "MyNAS 有 \(pendingChangeCount) 项更新"
    }
}

struct RemotePhotoGridCell: View {
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    let hasConfirmedLocalCopy: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RemotePhotoImageView(
                    asset: asset,
                    preferredKind: "grid",
                    fillsContainer: true,
                    account: account,
                    client: client
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()

                if asset.mediaType == .video {
                    Text(durationText)
                        .font(.system(size: metadataFontSize(for: geometry.size.width), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.48), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(badgeInset(for: geometry.size.width))
                }

                if asset.mediaType == .livePhoto || asset.isRAW {
                    VStack(alignment: .leading, spacing: 3) {
                        if asset.mediaType == .livePhoto {
                            Image(systemName: "livephoto")
                                .remoteMetadataBadge(fontSize: metadataFontSize(for: geometry.size.width))
                        }
                        if asset.isRAW {
                            HStack(spacing: 2) {
                                Image(systemName: "camera.aperture")
                                if geometry.size.width >= 52 {
                                    Text("RAW").fontWeight(.bold)
                                }
                            }
                            .remoteMetadataBadge(fontSize: metadataFontSize(for: geometry.size.width))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(badgeInset(for: geometry.size.width))
                }

                if !asset.browseReady {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: statusBadgeSize(for: geometry.size.width), weight: .semibold))
                        .foregroundStyle(.white, Color.orange)
                        .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(badgeInset(for: geometry.size.width))
                        .accessibilityLabel("预览正在生成")
                }

                if hasConfirmedLocalCopy {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: localCopyBadgeSize(for: geometry.size.width), weight: .semibold))
                        .foregroundStyle(.white, Color.green)
                        .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(badgeInset(for: geometry.size.width))
                        .accessibilityLabel("本机已有同一原件")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = asset.duration >= 3_600
            ? [.hour, .minute, .second]
            : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: asset.duration) ?? "视频"
    }

    private func statusBadgeSize(for width: CGFloat) -> CGFloat {
        min(24, max(14, width * 0.19))
    }

    private func localCopyBadgeSize(for width: CGFloat) -> CGFloat {
        min(20, max(13, width * 0.15))
    }

    private func metadataFontSize(for width: CGFloat) -> CGFloat {
        min(12, max(8, width * 0.09))
    }

    private func badgeInset(for width: CGFloat) -> CGFloat {
        min(7, max(3, width * 0.05))
    }
}

private struct RemotePhotoImageView: View {
    let asset: ServerPhotoAsset
    let preferredKind: String
    let fillsContainer: Bool
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    @State private var image: UIImage?
    @State private var didFail = false

    private var effectiveKind: String? {
        if asset.derivative(preferredKind) != nil { return preferredKind }
        if asset.derivative("grid") != nil { return "grid" }
        return asset.derivatives.first?.kind
    }

    private var maximumPreviewPixelSize: Int {
        effectiveKind == "preview" ? 1_920 : 768
    }

    var body: some View {
        ZStack {
            if let image {
                if fillsContainer {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                Image(systemName: didFail ? "exclamationmark.icloud" : asset.mediaType.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(asset.id)-\(asset.version)-\(preferredKind)") {
            guard let effectiveKind else {
                didFail = true
                return
            }
            do {
                let result = try await client.image(
                    for: asset,
                    kind: effectiveKind,
                    account: account
                )
                guard !Task.isCancelled else { return }
                image = await RemotePreviewImageDecoder.decode(
                    result.data,
                    maximumPixelSize: maximumPreviewPixelSize
                )
                guard !Task.isCancelled else { return }
                didFail = image == nil
            } catch {
                guard !Task.isCancelled else { return }
                didFail = true
            }
        }
    }
}

struct RemotePhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    let localClient: PhotoLibraryClient
    /// A local PhotoKit asset whose current source version has already been
    /// confirmed as this exact MyNAS asset. Do not infer this from metadata.
    let confirmedLocalCopy: LocalPhotoAsset? = nil
    let onRemoteDeleted: (String, PhotoBackupRemoteDeletionLocalDisposition) -> Void
    @State private var isCheckingForDuplicate = false
    @State private var isCheckingDeletionTarget = false
    @State private var isDownloading = false
    @State private var isImportingDownloadedResources = false
    @State private var isExportingOriginals = false
    @State private var downloadProgress: RemotePhotoDownloadProgress?
    @State private var exportDownload: RemotePhotoOriginalDownload?
    @State private var showsOriginalExportSheet = false
    @State private var isDeleting = false
    @State private var hasDiscoveredAccessibleLocalCopy = false
    @State private var showsRemoteDeleteConfirmation = false
    @State private var showsFinalRemoteDeleteConfirmation = false
    @State private var showsFinalPairedDeleteConfirmation = false
    @State private var localDeletionCandidate: PhotoBackupDeletionCandidate?
    @State private var localDeletionUnavailableReason: String?
    @State private var resultMessage: String?
    @State private var completionToastMessage: String?
    @State private var shouldLoadMediaPreview = false
    @State private var remoteMutationAvailability: MyNASRemoteMutationAvailability = .checking
    private let remoteMutationPreflight = MyNASRemoteMutationPreflight()

    /// `Body == AnyView` is deliberate. The former statically composed body
    /// contains media, dialogs, and action branches; iOS 27 crashes while
    /// resolving its generic metadata during presentation.
    var body: AnyView {
        AnyView(detailBody)
    }

    private var detailBody: some View {
        ScrollView {
            VStack(spacing: 18) {
                mediaPreview
                .aspectRatio(
                    asset.pixelWidth > 0 && asset.pixelHeight > 0
                        ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                        : 1,
                    contentMode: .fit
                )
                // During a presentation transition SwiftUI can briefly offer
                // this subtree a zero-height proposal. Keep the media slot
                // non-zero so CoreAnimation never asks ImageIO for a 1206×0
                // backing image.
                .frame(minHeight: 240, maxHeight: 560)
                .background(Color.black.opacity(0.04))

                VStack(alignment: .leading, spacing: 12) {
                    Label(asset.displayMediaName, systemImage: asset.mediaType.systemImage)
                        .font(.headline)

                    LabeledContent("尺寸", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                    LabeledContent(
                        "原件",
                        value: ByteCountFormatter.string(
                            fromByteCount: asset.resources.reduce(0) { $0 + $1.byteSize },
                            countStyle: .file
                        )
                    )
                    LabeledContent(
                        "MyNAS 状态",
                        value: asset.browseReady ? "可浏览" : "正在生成预览"
                    )
                    if let contentRelationshipDescription = asset.exactContentRelationshipDescription {
                        LabeledContent("内容关联", value: contentRelationshipDescription)
                    }
                    if let versionRelationshipDescription = asset.versionTransitionRelationshipDescription {
                        LabeledContent("版本关系", value: versionRelationshipDescription)
                    }

                    if let captureDate = asset.captureDate {
                        LabeledContent("拍摄时间", value: formattedDate(captureDate))
                    }
                }
                .padding(.horizontal)

                RemoteOriginalResourcesCard(resources: asset.resources)
                    .padding(.horizontal)

                if hasConfirmedLocalCopy {
                    confirmedLocalCopyNotice
                        .padding(.horizontal)
                }

                detailActions
                    .padding(.horizontal)

                Text(
                    hasConfirmedLocalCopy
                        ? "原件同时保存在本机和 MyNAS。删除时可只删除 MyNAS，或同时将已验证的本机原件移入系统“最近删除”。"
                        : "下载会先核验每个原件资源的大小和 SHA-256，再通过系统 Photos 导入。"
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("MyNAS 预览")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let completionToastMessage {
                Label(completionToastMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: completionToastMessage)
        .sheet(
            isPresented: $showsOriginalExportSheet,
            onDismiss: releaseExportDownload
        ) {
            if let exportDownload {
                RemotePhotoOriginalExportSheet(
                    fileURLs: exportDownload.resources.map(\.fileURL)
                ) { didComplete in
                    Task { @MainActor in
                        if didComplete {
                            showDownloadCompletionToast(
                                "已将 \(exportDownload.resources.count) 个原件交给系统分享"
                            )
                        }
                        showsOriginalExportSheet = false
                    }
                }
            }
        }
        .confirmationDialog(
            "选择删除范围",
            isPresented: $showsRemoteDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if localDeletionCandidate != nil {
                Button("同时删除本机照片（移入“最近删除”）") {
                    showsFinalPairedDeleteConfirmation = true
                }
                .disabled(!remoteMutationAvailability.allowsRemoteMutation)
            }
            Button("仅删除 MyNAS 项目") {
                showsFinalRemoteDeleteConfirmation = true
            }
            .disabled(!remoteMutationAvailability.allowsRemoteMutation)
            Button("取消", role: .cancel) {}
        } message: {
            if localDeletionCandidate != nil {
                Text("“仅删除 MyNAS 项目”不会改动本机照片。另一项会先由 iOS 将本机照片移入“最近删除”，再永久删除 MyNAS 原件、预览和备份记录；若 MyNAS 拒绝删除，本机照片仍可在系统“最近删除”中恢复。")
            } else if let localDeletionUnavailableReason {
                Text("\(localDeletionUnavailableReason) 因此这次只能删除 MyNAS 项目，本机照片不会被删除。")
            } else {
                Text("这会永久删除 MyNAS 中的原件、预览和备份记录，不能撤销。本机照片不会被删除。")
            }
        }
        .alert(
            "永久删除 MyNAS 项目？",
            isPresented: $showsFinalRemoteDeleteConfirmation
        ) {
            Button("永久删除 MyNAS 项目", role: .destructive) {
                Task { await deleteRemoteAsset() }
            }
            .disabled(!remoteMutationAvailability.allowsRemoteMutation)
            Button("取消", role: .cancel) {}
        } message: {
            Text("MyNAS 中的原件、预览和备份记录将永久删除，不能撤销。本机照片不会被删除。")
        }
        .alert(
            "同时删除本机与 MyNAS？",
            isPresented: $showsFinalPairedDeleteConfirmation
        ) {
            Button("继续删除", role: .destructive) {
                guard let localDeletionCandidate else { return }
                Task { await deleteLocalAndRemoteAsset(localDeletionCandidate) }
            }
            .disabled(!remoteMutationAvailability.allowsRemoteMutation)
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机照片会先移入系统“最近删除”，随后 MyNAS 原件会被永久删除。请确认这是你要删除的项目。")
        }
        .alert(
            "MyNAS 图库",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .task(id: account.accountID) {
            await refreshRemoteMutationAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshRemoteMutationAvailability() }
        }
    }

    private var isPerformingAction: Bool {
        isCheckingForDuplicate || isCheckingDeletionTarget || isDownloading || isExportingOriginals || isDeleting
    }

    private var hasConfirmedLocalCopy: Bool {
        if hasDiscoveredAccessibleLocalCopy { return true }
        guard let confirmedLocalCopy else { return false }
        return localClient.hasAccessibleAsset(localIdentifier: confirmedLocalCopy.localIdentifier)
    }

    private var confirmedLocalCopyNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("本机已有同一原件")
                    .font(.subheadline.weight(.semibold))
                Text("原件同时保存在本机和 MyNAS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    @ViewBuilder
    private var detailActions: some View {
        VStack(spacing: 10) {
            if RemotePhotoDownloadPolicy.offersOriginalDownload(
                hasConfirmedLocalCopy: hasConfirmedLocalCopy
            ) {
                Button {
                    Task { await prepareOriginalDownload() }
                } label: {
                    Label(
                        downloadActionTitle,
                        systemImage: "arrow.down.to.line.compact"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(isPerformingAction)
                remotePrimaryActionStyle()
            }

            Button {
                Task { await exportVerifiedOriginals() }
            } label: {
                Label(
                    isExportingOriginals ? "正在准备导出…" : "导出已核验原件…",
                    systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .disabled(isPerformingAction || exportDownload != nil)
            .buttonStyle(.bordered)

            if isDownloading || isExportingOriginals {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: downloadProgress?.fractionCompleted ?? 0)
                        .tint(.accentColor)
                    Text(downloadProgressDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }

            Button(role: .destructive) {
                Task { await prepareRemoteDeletion() }
            } label: {
                Label(
                    isCheckingDeletionTarget || isDeleting ? "正在准备删除…" : "删除…",
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity)
            }
            .disabled(
                isPerformingAction
                    || !remoteMutationAvailability.allowsRemoteMutation
            )
            .buttonStyle(.bordered)

            if let statusText = remoteMutationAvailability.statusText {
                Label(
                    statusText,
                    systemImage: remoteMutationAvailability == .tailscaleUnavailable
                        ? "wifi.exclamationmark"
                        : "network"
                )
                .font(.footnote)
                .foregroundStyle(
                    remoteMutationAvailability == .tailscaleUnavailable
                        ? Color.orange
                        : Color.secondary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(
                    (remoteMutationAvailability == .tailscaleUnavailable
                        ? Color.orange
                        : Color.secondary).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }
    }

    private func refreshRemoteMutationAvailability() async {
        remoteMutationAvailability = .checking
        remoteMutationAvailability = await remoteMutationPreflight.availability(for: account)
    }

    private func confirmRemoteMutationAvailability() async -> Bool {
        let availability = await remoteMutationPreflight.availability(for: account)
        guard !Task.isCancelled else { return false }
        remoteMutationAvailability = availability
        guard availability.allowsRemoteMutation else {
            resultMessage = MyNASRemoteMutationPreflightError
                .tailscaleUnavailable.localizedDescription
            return false
        }
        return true
    }

    private func prepareOriginalDownload() async {
        guard !isPerformingAction else { return }
        guard RemotePhotoDownloadPolicy.offersOriginalDownload(
            hasConfirmedLocalCopy: hasConfirmedLocalCopy
        ) else { return }
        isCheckingForDuplicate = true
        defer { isCheckingForDuplicate = false }
        do {
            let mapping = try await client.fetchDeviceAssetMapping(
                account: account,
                deviceID: PhotoBackupDeviceIdentity.currentID(),
                assetID: asset.id
            )
            guard !Task.isCancelled else { return }
            if let mapping,
               localClient.hasAccessibleAsset(localIdentifier: mapping.localIdentifier) {
                hasDiscoveredAccessibleLocalCopy = true
            } else {
                await downloadOriginalsToPhotos()
            }
        } catch let error as RemotePhotoLibraryError
            where error.permitsDownloadWithoutDeviceMappingCheck {
            // A server without the optional device-mapping endpoint can still
            // safely provide originals: the resource download verifies URL,
            // byte count, and SHA-256 before Photos receives anything.
            await downloadOriginalsToPhotos()
        } catch {
            guard !Task.isCancelled else { return }
            resultMessage = "下载未开始：无法确认这台 iPhone 是否已有同一 MyNAS 项目。\n\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func downloadOriginalsToPhotos() async {
        guard !isDownloading && !isDeleting else { return }
        isDownloading = true
        isImportingDownloadedResources = false
        downloadProgress = nil
        defer {
            isDownloading = false
            isImportingDownloadedResources = false
        }
        do {
            let download = try await client.downloadOriginalResources(
                for: asset,
                account: account
            ) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
            defer { download.removeTemporaryFiles() }
            isImportingDownloadedResources = true
            _ = try await localClient.importDownloadedRemoteResources(download.resources)
            guard !Task.isCancelled else { return }
            showDownloadCompletionToast("已导入 \(download.resources.count) 个 MyNAS 原件资源")
        } catch {
            guard !Task.isCancelled else { return }
            resultMessage = "下载或导入未完成：\n\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// The same original-resource download used by import performs same-origin,
    /// size, and SHA-256 validation before iOS receives a shareable file URL.
    private func exportVerifiedOriginals() async {
        guard !isPerformingAction, exportDownload == nil else { return }
        isExportingOriginals = true
        downloadProgress = nil
        defer { isExportingOriginals = false }
        do {
            let download = try await client.downloadOriginalResources(
                for: asset,
                account: account
            ) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
            guard !Task.isCancelled else {
                download.removeTemporaryFiles()
                return
            }
            exportDownload = download
            showsOriginalExportSheet = true
        } catch {
            guard !Task.isCancelled else { return }
            resultMessage = "导出未完成：\n\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func releaseExportDownload() {
        exportDownload?.removeTemporaryFiles()
        exportDownload = nil
    }

    private var downloadActionTitle: String {
        if isCheckingForDuplicate { return "正在准备下载…" }
        if isImportingDownloadedResources { return "正在导入系统照片…" }
        if isDownloading { return "正在下载原件…" }
        return "下载原件到本机"
    }

    private var downloadProgressDescription: String {
        if isImportingDownloadedResources {
            return "原件已核验，正在导入系统照片…"
        }
        if isExportingOriginals, downloadProgress == nil {
            return "正在准备可导出的已核验原件…"
        }
        guard let downloadProgress else {
            return "正在准备下载原件…"
        }
        let completed = ByteCountFormatter.string(
            fromByteCount: downloadProgress.completedByteCount,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: downloadProgress.totalByteCount,
            countStyle: .file
        )
        return "正在下载 \(downloadProgress.resourceIndex + 1) / \(downloadProgress.resourceCount) · \(completed) / \(total)"
    }

    private func showDownloadCompletionToast(_ message: String) {
        withAnimation {
            completionToastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled, completionToastMessage == message else { return }
            withAnimation {
                completionToastMessage = nil
            }
        }
    }

    /// The paired action is offered only with an exact, current device mapping
    /// and a locally accessible PhotoKit asset. The server repeats validation
    /// when the paired H0 deletion request arrives; this UI check exists solely
    /// to keep the local and remote choices understandable and safe.
    private func prepareRemoteDeletion() async {
        guard !isPerformingAction else { return }
        guard remoteMutationAvailability.allowsRemoteMutation else {
            resultMessage = MyNASRemoteMutationPreflightError
                .tailscaleUnavailable.localizedDescription
            return
        }
        isCheckingDeletionTarget = true
        defer { isCheckingDeletionTarget = false }
        guard await confirmRemoteMutationAvailability() else { return }
        localDeletionCandidate = nil
        localDeletionUnavailableReason = nil

        do {
            let mapping = try await client.fetchDeviceAssetMapping(
                account: account,
                deviceID: PhotoBackupDeviceIdentity.currentID(),
                assetID: asset.id
            )
            guard !Task.isCancelled else { return }
            guard let mapping else {
                localDeletionUnavailableReason = "MyNAS 没有找到这台 iPhone 的已验证本机对应项。"
                showsRemoteDeleteConfirmation = true
                return
            }
            guard mapping.sourceState == PhotoSourceState.committed.rawValue,
                  let sourceModificationDate = mapping.sourceModificationDate,
                  !sourceModificationDate.isEmpty else {
                localDeletionUnavailableReason = "这台 iPhone 的对应备份状态不是可安全删除的已提交版本。"
                showsRemoteDeleteConfirmation = true
                return
            }
            guard localClient.hasAccessibleAsset(localIdentifier: mapping.localIdentifier) else {
                localDeletionUnavailableReason = "这台 iPhone 已无法访问对应的本机照片。"
                showsRemoteDeleteConfirmation = true
                return
            }

            localDeletionCandidate = PhotoBackupDeletionCandidate(
                assetID: asset.id,
                deviceID: PhotoBackupDeviceIdentity.currentID(),
                localIdentifier: mapping.localIdentifier,
                sourceModificationDate: sourceModificationDate
            )
            showsRemoteDeleteConfirmation = true
        } catch {
            guard !Task.isCancelled else { return }
            // Direct MyNAS-only deletion remains available even if a mapping
            // lookup is unavailable. Never guess a local Photos identifier.
            localDeletionUnavailableReason = "无法确认这台 iPhone 的本机对应项。"
            showsRemoteDeleteConfirmation = true
        }
    }

    private func deleteRemoteAsset() async {
        guard !isPerformingAction else { return }
        isDeleting = true
        defer { isDeleting = false }
        guard await confirmRemoteMutationAvailability() else { return }
        do {
            let result = try await client.deleteRemoteAsset(asset, account: account)
            guard !Task.isCancelled else { return }
            onRemoteDeleted(result.assetID, .retained)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            resultMessage = "MyNAS 未删除该项目：\n\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// PhotoKit always owns the local deletion. Only after it confirms the
    /// item moved to Recently Deleted do we ask MyNAS to remove the matching,
    /// server-verified backup. A MyNAS rejection deliberately leaves the
    /// remote item visible and explains how to recover the local item.
    private func deleteLocalAndRemoteAsset(_ candidate: PhotoBackupDeletionCandidate) async {
        guard !isPerformingAction else { return }
        isDeleting = true
        defer { isDeleting = false }

        // Never move the local item to Recently Deleted unless the remote
        // mutation is still reachable at the final action boundary.
        guard await confirmRemoteMutationAvailability() else { return }

        do {
            try await localClient.deleteAssets(localIdentifiers: [candidate.localIdentifier])
        } catch {
            guard !Task.isCancelled else { return }
            resultMessage = "本机照片没有删除，MyNAS 也没有删除该项目：\n\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return
        }

        do {
            let result = try await client.deleteBackups(candidates: [candidate], account: account)
            guard result.items.count == 1,
                  result.items[0].assetID == asset.id else {
                throw RemotePhotoLibraryError.invalidResponse
            }
            guard !Task.isCancelled else { return }
            onRemoteDeleted(asset.id, .movedToRecentlyDeleted)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            resultMessage = "本机照片已移入系统“最近删除”，但 MyNAS 没有删除该项目。若要恢复本机照片，请在系统照片的“最近删除”中恢复；MyNAS 项目仍保留。\n\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var mediaPreview: some View {
        if !shouldLoadMediaPreview {
            RemoteMediaPreviewPlaceholder(asset: asset) {
                shouldLoadMediaPreview = true
            }
        } else {
            switch asset.mediaType {
            case .video:
                RemoteVideoPreview(
                    resource: asset.videoResource,
                    asset: asset,
                    account: account,
                    client: client
                )
            case .livePhoto:
                RemoteLivePhotoPreview(
                    resource: asset.pairedVideoResource,
                    asset: asset,
                    account: account,
                    client: client
                )
            case .photo, .unknown:
                RemotePhotoImageView(
                    asset: asset,
                    preferredKind: "preview",
                    fillsContainer: false,
                    account: account,
                    client: client
                )
            }
        }
    }

    private func formattedDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

/// Opening a MyNAS detail must be safe even when its remote derivative is slow,
/// malformed, or too expensive to decode. The grid already shows a compact
/// thumbnail, so defer the larger remote preview until the user asks for it.
private struct RemoteMediaPreviewPlaceholder: View {
    let asset: ServerPhotoAsset
    let loadPreview: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            VStack(spacing: 12) {
                Image(systemName: asset.mediaType.systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("远端预览尚未加载")
                    .font(.subheadline.weight(.semibold))
                Text("打开详情不会自动读取 MyNAS 媒体。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("加载预览", action: loadPreview)
                    .buttonStyle(.borderedProminent)
            }
            .multilineTextAlignment(.center)
            .padding()
        }
    }
}

private struct RemoteVideoPreview: View {
    let resource: ServerPhotoResource?
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    @State private var player: AVPlayer?
    @State private var resourceLoader: MyNASMediaResourceLoader?
    @State private var isPreparingPlayback = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else {
                RemotePhotoImageView(
                    asset: asset,
                    preferredKind: "preview",
                    fillsContainer: false,
                    account: account,
                    client: client
                )
                .allowsHitTesting(false)

                Color.black.opacity(0.28)

                VStack(spacing: 10) {
                    if didFail {
                        Text("无法从 MyNAS 播放视频")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("请检查 Tailscale 连接后重试。视频不会完整下载到 iPhone。")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.84))
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await startPlayback() }
                    } label: {
                        Label(
                            isPreparingPlayback ? "正在连接 MyNAS…" : "播放视频",
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingPlayback)
                }
                .padding()
            }
        }
        .onDisappear(perform: stopPlayback)
    }

    private func startPlayback() async {
        guard !isPreparingPlayback, let resource else {
            didFail = resource == nil
            return
        }
        isPreparingPlayback = true
        didFail = false
        defer { isPreparingPlayback = false }
        do {
            let url = try await client.streamingURL(
                for: resource,
                in: asset,
                account: account
            )
            let loader = MyNASMediaResourceLoader(
                sourceURL: url,
                resource: resource,
                asset: asset,
                account: account,
                client: client
            )
            let urlAsset = try loader.makeAsset()
            guard !Task.isCancelled else {
                loader.invalidate()
                return
            }
            resourceLoader = loader
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: urlAsset))
            player = newPlayer
            newPlayer.play()
        } catch {
            guard !Task.isCancelled else { return }
            didFail = true
        }
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        resourceLoader?.invalidate()
        resourceLoader = nil
    }
}

private struct RemoteLivePhotoPreview: View {
    let resource: ServerPhotoResource?
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    @State private var player: AVPlayer?
    @State private var resourceLoader: MyNASMediaResourceLoader?
    @State private var isPreparingPlayback = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black
            RemotePhotoImageView(
                asset: asset,
                preferredKind: "preview",
                fillsContainer: false,
                account: account,
                client: client
            )

            if let player {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 10) {
                    if didFail {
                        Text("无法播放实况片段")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Button {
                        Task { await startPlayback() }
                    } label: {
                        Label(
                            isPreparingPlayback ? "正在缓冲…" : "播放实况片段",
                            systemImage: "livephoto.play"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingPlayback)
                }
            }
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            resourceLoader?.invalidate()
            resourceLoader = nil
        }
    }

    private func startPlayback() async {
        guard let resource else {
            didFail = true
            return
        }
        isPreparingPlayback = true
        didFail = false
        defer { isPreparingPlayback = false }
        do {
            let url = try await client.streamingURL(
                for: resource,
                in: asset,
                account: account
            )
            let loader = MyNASMediaResourceLoader(
                sourceURL: url,
                resource: resource,
                asset: asset,
                account: account,
                client: client
            )
            let urlAsset = try loader.makeAsset()
            guard !Task.isCancelled else { return }
            resourceLoader = loader
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: urlAsset))
            player = newPlayer
            newPlayer.play()
        } catch {
            didFail = true
        }
    }
}

private struct RemoteOriginalResourcesCard: View {
    let resources: [ServerPhotoResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("MyNAS 原件资源", systemImage: "externaldrive")
                .font(.headline)

            ForEach(resources) { resource in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: resource.isVideo ? "video" : "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(resource.originalFilename)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text("\(resource.displayRole) · \(ByteCountFormatter.string(fromByteCount: resource.byteSize, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if resource.isVideo {
                            Text("可在上方从 MyNAS 流式播放")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

@ViewBuilder
private func remotePreviewProgress(_ title: String) -> some View {
    ProgressView(title)
        .tint(.white)
        .foregroundStyle(.white)
}

@ViewBuilder
private func remotePreviewUnavailable(
    title: String,
    symbol: String,
    message: String
) -> some View {
    ContentUnavailableView(
        title,
        systemImage: symbol,
        description: Text(message)
    )
    .foregroundStyle(.white)
}

private extension View {
    @ViewBuilder
    func remotePrimaryActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    func remoteMetadataBadge(fontSize: CGFloat) -> some View {
        self
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(.black.opacity(0.48), in: Capsule())
    }

    @ViewBuilder
    func remoteLibrarySurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}
