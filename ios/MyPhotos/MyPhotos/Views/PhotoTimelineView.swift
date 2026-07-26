import SwiftUI

struct PhotoTimelineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var accountStore: AccountStore
    @ObservedObject var viewModel: LocalPhotoLibraryViewModel
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    let showSearch: () -> Void
    @StateObject private var unifiedTimeline = UnifiedPhotoTimelineViewModel()
    @State private var selectedIDs: Set<String> = []
    @State private var selectionMode = false
    @State private var deletionRequest: PhotoDeletionRequest?
    @State private var deletionErrorMessage: String?
    @State private var isDeleting = false
    @AppStorage("photoTimelineShowsUnified") private var showsUnifiedTimeline = true
    @AppStorage("photoGridColumnCount") private var columnCount = 3
    @State private var pinchStartColumnCount: Int?

    private let minimumColumnCount = 2
    private let maximumColumnCount = 10
    private let gridSpacing: CGFloat = 2

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: gridSpacing),
            count: columnCount
        )
    }

    private var thumbnailTargetSize: CGSize {
        let edge = max(120, min(360, 1_080 / CGFloat(columnCount)))
        return CGSize(width: edge, height: edge)
    }

    private var usesUnifiedTimeline: Bool {
        !accountStore.current.isLocalOnly && showsUnifiedTimeline && !selectionMode
    }

    private var completedBackupIdentifiers: Set<String> {
        Set(
            viewModel.assets
                .filter {
                    backupCoordinator.hasCurrentVerifiedBackup(
                        for: $0,
                        accountID: accountStore.current.accountID
                    )
                }
                .map(\.localIdentifier)
        )
    }

    private var localTimelineSections: [PhotoTimelineYearSection<LocalPhotoAsset>] {
        PhotoTimelineYearSection.make(
            items: viewModel.assets,
            date: { $0.creationDate }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.authorization.canReadLibrary {
                    libraryContent
                } else {
                    PhotoPermissionView(
                        authorization: viewModel.authorization,
                        requestAuthorization: { Task { await viewModel.requestAuthorization() } }
                    )
                }
            }
            .navigationTitle(selectionMode ? "已选 \(selectedIDs.count) 项" : "照片")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.authorization.canReadLibrary {
                        Button(selectionMode ? "取消" : "选择") {
                            withAnimation(.snappy) {
                                selectionMode.toggle()
                                if !selectionMode { selectedIDs.removeAll() }
                            }
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selectionMode, !selectedIDs.isEmpty {
                        Button(role: .destructive, action: requestDeletion) {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("删除所选照片")
                    }

                    Button(action: showSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索照片")
                }
            }
        }
        .sheet(item: $deletionRequest) { request in
            PhotoDeletionConfirmationSheet(
                request: request,
                isDeleting: isDeleting,
                confirm: { alsoDeleteMyNASBackups in
                    Task {
                        await delete(
                            request: request,
                            alsoDeleteMyNASBackups: alsoDeleteMyNASBackups
                        )
                    }
                }
            )
        }
        .alert(
            "无法完成删除",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "")
        }
        .task(id: accountStore.current.accountID) {
            unifiedTimeline.synchronizeLocal(
                assets: viewModel.assets,
                jobs: backupCoordinator.jobs,
                accountID: accountStore.current.accountID
            )
            guard usesUnifiedTimeline else { return }
            await unifiedTimeline.refreshRemote(account: accountStore.current)
        }
        .onChange(of: viewModel.assets) { _, assets in
            unifiedTimeline.synchronizeLocal(
                assets: assets,
                jobs: backupCoordinator.jobs,
                accountID: accountStore.current.accountID
            )
        }
        .onChange(of: backupCoordinator.jobs) { _, jobs in
            unifiedTimeline.synchronizeLocal(
                assets: viewModel.assets,
                jobs: jobs,
                accountID: accountStore.current.accountID
            )
        }
        .onChange(of: showsUnifiedTimeline) { _, shouldShowUnified in
            guard shouldShowUnified, !accountStore.current.isLocalOnly else { return }
            selectionMode = false
            selectedIDs.removeAll()
            Task {
                unifiedTimeline.synchronizeLocal(
                    assets: viewModel.assets,
                    jobs: backupCoordinator.jobs,
                    accountID: accountStore.current.accountID
                )
                await unifiedTimeline.refreshRemote(account: accountStore.current)
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch viewModel.state {
        case .loading where viewModel.assets.isEmpty:
            ProgressView("正在读取本地照片…")
        case .empty:
            ContentUnavailableView(
                "没有可访问的照片或视频",
                systemImage: "photo.on.rectangle.angled",
                description: Text("拍摄照片，或在系统设置中选择允许 MyNAS Photos 访问的项目。")
            )
        case .failed(let message):
            ContentUnavailableView("无法读取照片库", systemImage: "exclamationmark.triangle", description: Text(message))
        default:
            ScrollView {
                LazyVStack(spacing: 12) {
                    NavigationLink {
                        PhotoBackupView(
                            coordinator: backupCoordinator,
                            assets: viewModel.assets,
                            client: viewModel.imageClient
                        )
                    } label: {
                        PhotoTimelineBackupBanner(
                            progress: backupCoordinator.progress(
                                for: accountStore.current.accountID,
                                assets: viewModel.assets
                            ),
                            headline: backupCoordinator.headline,
                            isConnected: !accountStore.current.isLocalOnly
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                    if !accountStore.current.isLocalOnly {
                        Picker("显示范围", selection: $showsUnifiedTimeline) {
                            Text("全部").tag(true)
                            Text("本机").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 10)

                        NavigationLink {
                            RemotePhotoLibraryView(account: accountStore.current)
                        } label: {
                            RemoteLibraryEntryRow(
                                serverName: accountStore.current.displayName
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                    }

                    if viewModel.authorization == .limited {
                        LimitedAccessBanner(action: viewModel.showLimitedPicker)
                            .padding(.horizontal)
                    }

                    if usesUnifiedTimeline {
                        UnifiedPhotoTimelineView(
                            viewModel: unifiedTimeline,
                            account: accountStore.current,
                            localClient: viewModel.imageClient,
                            columns: columns,
                            thumbnailTargetSize: thumbnailTargetSize
                        )
                    } else {
                        PhotoTimelineYearGroupedGrid(
                            sections: localTimelineSections,
                            columns: columns,
                            spacing: gridSpacing,
                            date: { $0.creationDate },
                            lastItemID: viewModel.assets.last?.id,
                            onLastItemAppear: {
                                Task { await viewModel.loadNextPage() }
                            }
                        ) { asset in
                            gridItem(for: asset)
                        }
                    }

                    if !usesUnifiedTimeline && viewModel.isLoadingNextPage {
                        ProgressView()
                            .padding(.vertical, 20)
                    }
                }
            }
            .refreshable {
                await viewModel.refresh()
                unifiedTimeline.synchronizeLocal(
                    assets: viewModel.assets,
                    jobs: backupCoordinator.jobs,
                    accountID: accountStore.current.accountID
                )
                if usesUnifiedTimeline {
                    await unifiedTimeline.refreshRemote(account: accountStore.current)
                }
            }
            .simultaneousGesture(gridMagnificationGesture, including: .gesture)
            .sensoryFeedback(.selection, trigger: columnCount)
            .overlayPreferenceValue(PhotoTimelineDateAnchorPreferenceKey.self) { anchors in
                PhotoTimelineVisibleDateOverlay(anchors: anchors)
            }
            .onChange(of: viewModel.assets.map(\.id)) { _, _ in
                prefetchVisibleDensity()
            }
            .onChange(of: columnCount) { _, _ in
                prefetchVisibleDensity()
            }
        }
    }

    @ViewBuilder
    private func gridItem(for asset: LocalPhotoAsset) -> some View {
        if selectionMode {
            PhotoGridCell(
                asset: asset,
                isBackedUp: completedBackupIdentifiers.contains(asset.localIdentifier),
                isSelected: selectedIDs.contains(asset.id),
                targetSize: thumbnailTargetSize,
                client: viewModel.imageClient
            )
                .onTapGesture { toggleSelection(asset) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(accessibilityLabel(for: asset, action: "选择"))
        } else {
            NavigationLink {
                PhotoDetailView(
                    asset: asset,
                    isBackedUp: completedBackupIdentifiers.contains(asset.localIdentifier),
                    client: viewModel.imageClient
                )
            } label: {
                PhotoGridCell(
                    asset: asset,
                    isBackedUp: completedBackupIdentifiers.contains(asset.localIdentifier),
                    isSelected: false,
                    targetSize: thumbnailTargetSize,
                    client: viewModel.imageClient
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel(for: asset, action: "打开"))
        }
    }

    private func accessibilityLabel(for asset: LocalPhotoAsset, action: String) -> String {
        let backupState = completedBackupIdentifiers.contains(asset.localIdentifier)
            ? "，已完成备份"
            : ""
        return "\(action)\(asset.displayMediaName)\(backupState)"
    }

    private func toggleSelection(_ asset: LocalPhotoAsset) {
        if selectedIDs.contains(asset.id) {
            selectedIDs.remove(asset.id)
        } else {
            selectedIDs.insert(asset.id)
        }
    }

    private func requestDeletion() {
        let assets = viewModel.assets.filter { selectedIDs.contains($0.id) }
        guard !assets.isEmpty else { return }
        deletionRequest = PhotoDeletionRequest(
            assets: assets,
            backupCandidates: backupCoordinator.deletionCandidates(
                for: assets,
                accountID: accountStore.current.accountID
            ),
            isConnectedToMyNAS: !accountStore.current.isLocalOnly,
            isMyNASDeletionAvailable: accountStore.current.serverCapabilities.supportsPhotoDeletion == true
        )
    }

    private func delete(
        request: PhotoDeletionRequest,
        alsoDeleteMyNASBackups: Bool
    ) async {
        isDeleting = true
        defer { isDeleting = false }
        let localIdentifiers = request.assets.map(\.localIdentifier)
        do {
            try await viewModel.imageClient.deleteAssets(localIdentifiers: localIdentifiers)

            selectedIDs.subtract(localIdentifiers)
            selectionMode = false
            deletionRequest = nil
            await viewModel.refresh()
            unifiedTimeline.synchronizeLocal(
                assets: viewModel.assets,
                jobs: backupCoordinator.jobs,
                accountID: accountStore.current.accountID
            )
            guard alsoDeleteMyNASBackups else { return }
            guard request.canAlsoDeleteMyNASBackups else {
                deletionErrorMessage = PhotoDeletionFlowError.backupVerificationUnavailable.errorDescription
                return
            }

            do {
                _ = try await unifiedTimeline.remoteClient.deleteBackups(
                    candidates: request.backupCandidates,
                    account: accountStore.current
                )
                await unifiedTimeline.refreshRemote(account: accountStore.current)
            } catch {
                deletionErrorMessage = PhotoDeletionFlowError.localDeletionSucceededMyNASDeletionFailed(
                    error.localizedDescription
                ).errorDescription
            }
        } catch {
            deletionRequest = nil
            deletionErrorMessage = error.localizedDescription
        }
    }

    private var gridMagnificationGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                if pinchStartColumnCount == nil {
                    pinchStartColumnCount = columnCount
                }

                guard let startingColumns = pinchStartColumnCount else { return }
                let proposedColumns = Int(
                    (CGFloat(startingColumns) / value.magnification).rounded()
                )
                let clampedColumns = min(
                    maximumColumnCount,
                    max(minimumColumnCount, proposedColumns)
                )

                guard clampedColumns != columnCount else { return }
                setColumnCount(clampedColumns)
            }
            .onEnded { _ in
                pinchStartColumnCount = nil
            }
    }

    private func setColumnCount(_ proposedCount: Int) {
        let clampedCount = min(
            maximumColumnCount,
            max(minimumColumnCount, proposedCount)
        )
        guard clampedCount != columnCount else { return }

        if reduceMotion {
            columnCount = clampedCount
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                columnCount = clampedCount
            }
        }
    }

    private func prefetchVisibleDensity() {
        viewModel.prefetch(
            assets: viewModel.assets,
            targetSize: thumbnailTargetSize
        )
    }
}

private enum PhotoDeletionFlowError: LocalizedError {
    case backupVerificationUnavailable
    case localDeletionSucceededMyNASDeletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .backupVerificationUnavailable:
            "选择中的项目没有当前、完整且已验证的 MyNAS 备份，因此没有删除 MyNAS 数据。"
        case .localDeletionSucceededMyNASDeletionFailed(let reason):
            "本机项目已移入 iPhone“最近删除”，但 MyNAS 备份未删除：\(reason)"
        }
    }
}

private struct RemoteLibraryEntryRow: View {
    let serverName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("浏览 MyNAS 图库")
                    .font(.subheadline.weight(.semibold))
                Text("\(serverName) · 查看 MyNAS 的原始远端视图与媒体资源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .remoteLibraryEntrySurface()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    @ViewBuilder
    func remoteLibraryEntrySurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }
}

private struct PhotoTimelineBackupBanner: View {
    let progress: PhotoBackupProgressSnapshot
    let headline: String
    let isConnected: Bool

    private var isComplete: Bool {
        progress.totalCount > 0 && progress.completedCount == progress.totalCount
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: progress.isRunning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MyNAS 备份")
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(progress.percentage)%")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            ProgressView(value: progress.fractionCompleted)
                .tint(isComplete ? .green : .accentColor)

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("原件已上传 \(progress.countText) 项")
                    Text(sizeSummary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Text("查看备份详情")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .backupBannerSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "MyNAS 备份，原件已安全上传 \(progress.completedCount) 项，共 \(progress.totalCount) 项，\(progress.percentage)%，\(sizeSummary)"
        )
    }

    private var sizeSummary: String {
        let uploaded = ByteCountFormatter.string(
            fromByteCount: progress.uploadedBytes,
            countStyle: .file
        )
        guard progress.totalBytes > 0 else {
            return progress.totalCount > 0 ? "备份总大小正在计算" : "尚无备份文件"
        }
        let total = ByteCountFormatter.string(
            fromByteCount: progress.totalBytes,
            countStyle: .file
        )
        if progress.hasCompleteSize {
            return "已上传 \(uploaded) / 总计 \(total)"
        }
        return "已上传 \(uploaded) · 已统计 \(total)，\(progress.sizePendingCount) 项计算中"
    }

    private var statusText: String {
        if !isConnected { return "连接 MyNAS 后开始保护照片与视频" }
        if progress.isRunning { return headline }
        if isComplete { return "所有队列项目的原件均已通过完整性校验" }
        return headline
    }

    private var statusSymbol: String {
        if isComplete { return "checkmark.circle.fill" }
        if progress.isRunning { return "arrow.up.circle.fill" }
        return "externaldrive.fill"
    }

    private var statusColor: Color {
        isComplete ? .green : .accentColor
    }
}

private extension View {
    @ViewBuilder
    func backupBannerSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }
}

struct PhotoGridCell: View {
    let asset: LocalPhotoAsset
    let isBackedUp: Bool
    let isSelected: Bool
    let targetSize: CGSize
    let client: PhotoLibraryClient

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PhotoThumbnailView(asset: asset, targetSize: targetSize, client: client)
                    .allowsHitTesting(false)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                if asset.mediaKind == .video {
                    Text(durationText)
                        .font(.system(size: metadataFontSize(for: geometry.size.width), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.48), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(badgeInset(for: geometry.size.width))
                        .accessibilityHidden(true)
                }

                if asset.mediaKind == .livePhoto || asset.isRAW {
                    VStack(alignment: .leading, spacing: 3) {
                        if asset.mediaKind == .livePhoto {
                            Image(systemName: "livephoto")
                                .metadataBadge(fontSize: metadataFontSize(for: geometry.size.width))
                        }
                        if asset.isRAW {
                            HStack(spacing: 2) {
                                Image(systemName: "camera.aperture")
                                if geometry.size.width >= 52 {
                                    Text("RAW")
                                        .fontWeight(.bold)
                                }
                            }
                            .metadataBadge(fontSize: metadataFontSize(for: geometry.size.width))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(badgeInset(for: geometry.size.width))
                    .accessibilityHidden(true)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: statusBadgeSize(for: geometry.size.width), weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(badgeInset(for: geometry.size.width))
                        .accessibilityHidden(true)
                } else if isBackedUp {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: statusBadgeSize(for: geometry.size.width), weight: .semibold))
                        .foregroundStyle(.white, Color.green)
                        .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(badgeInset(for: geometry.size.width))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(Rectangle())
    }

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = asset.duration >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: asset.duration) ?? "视频"
    }

    private func statusBadgeSize(for cellWidth: CGFloat) -> CGFloat {
        min(24, max(14, cellWidth * 0.19))
    }

    private func metadataFontSize(for cellWidth: CGFloat) -> CGFloat {
        min(12, max(8, cellWidth * 0.09))
    }

    private func badgeInset(for cellWidth: CGFloat) -> CGFloat {
        min(7, max(3, cellWidth * 0.05))
    }
}

private extension View {
    func metadataBadge(fontSize: CGFloat) -> some View {
        self
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(.black.opacity(0.48), in: Capsule())
    }
}

struct PhotoThumbnailView: View {
    let asset: LocalPhotoAsset
    let targetSize: CGSize
    let client: PhotoLibraryClient
    @State private var image: UIImage?
    @State private var isCloudOnly = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            if isCloudOnly {
                Image(systemName: "icloud")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.55), in: Circle())
                .accessibilityLabel("仅在 iCloud 中，未自动下载")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(asset.id)-\(Int(targetSize.width))") {
            let result = await client.thumbnail(for: asset.localIdentifier, targetSize: targetSize)
            guard !Task.isCancelled else { return }
            image = result.image
            isCloudOnly = result.isCloudOnly
            didFail = result.image == nil && !result.isCloudOnly
        }
        .accessibilityLabel(accessibilityDescription)
    }

    private var placeholderSymbol: String {
        if isCloudOnly { return "icloud" }
        if didFail { return "arrow.clockwise" }
        return asset.mediaKind.systemImage
    }

    private var accessibilityDescription: String {
        if isCloudOnly { return "\(asset.mediaKind.displayName)，仅在 iCloud 中，未自动下载" }
        return asset.mediaKind.displayName
    }
}

private struct LimitedAccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.badge.person.crop")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("当前仅可访问部分照片")
                    .font(.subheadline.weight(.semibold))
                Text("MyNAS Photos 只会显示系统授权给它的项目，不会声称已访问完整照片库。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("管理") { action() }
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}
