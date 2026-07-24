import SwiftUI

struct PhotoTimelineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var accountStore: AccountStore
    @ObservedObject var viewModel: LocalPhotoLibraryViewModel
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    let showSearch: () -> Void
    @State private var selectedIDs: Set<String> = []
    @State private var selectionMode = false
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

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: showSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索照片")
                }
            }
            .navigationDestination(for: LocalPhotoAsset.self) { asset in
                PhotoDetailView(asset: asset, client: viewModel.imageClient)
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
                LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
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
                                fallbackTotalCount: viewModel.assets.count
                            ),
                            headline: backupCoordinator.headline,
                            isConnected: !accountStore.current.isLocalOnly
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                    if viewModel.authorization == .limited {
                        LimitedAccessBanner(action: viewModel.showLimitedPicker)
                            .padding(.horizontal)
                    }

                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(viewModel.assets) { asset in
                            gridItem(for: asset)
                                .onAppear {
                                    if asset.id == viewModel.assets.last?.id {
                                        Task { await viewModel.loadNextPage() }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, gridSpacing)

                    if viewModel.isLoadingNextPage {
                        ProgressView()
                            .padding(.vertical, 20)
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
            .simultaneousGesture(gridMagnificationGesture)
            .sensoryFeedback(.selection, trigger: columnCount)
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
                isSelected: selectedIDs.contains(asset.id),
                isSelectionMode: true,
                targetSize: thumbnailTargetSize,
                client: viewModel.imageClient
            )
                .onTapGesture { toggleSelection(asset) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("选择 \(asset.mediaKind.displayName)")
        } else {
            NavigationLink(value: asset) {
                PhotoGridCell(
                    asset: asset,
                    isSelected: false,
                    isSelectionMode: false,
                    targetSize: thumbnailTargetSize,
                    client: viewModel.imageClient
                )
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                selectionMode = true
                selectedIDs.insert(asset.id)
            })
            .accessibilityLabel("打开\(asset.mediaKind.displayName)")
        }
    }

    private func toggleSelection(_ asset: LocalPhotoAsset) {
        if selectedIDs.contains(asset.id) {
            selectedIDs.remove(asset.id)
        } else {
            selectedIDs.insert(asset.id)
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

private struct PhotoGridCell: View {
    let asset: LocalPhotoAsset
    let isSelected: Bool
    let isSelectionMode: Bool
    let targetSize: CGSize
    let client: PhotoLibraryClient

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                PhotoThumbnailView(asset: asset, targetSize: targetSize, client: client)
                    .allowsHitTesting(!isSelectionMode)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                if asset.mediaKind == .video {
                    Text(durationText)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(6)
                        .accessibilityHidden(true)
                } else if asset.mediaKind == .livePhoto {
                    Image(systemName: "livephoto")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .accessibilityHidden(true)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(7)
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
}

struct PhotoThumbnailView: View {
    let asset: LocalPhotoAsset
    let targetSize: CGSize
    let client: PhotoLibraryClient
    @State private var image: UIImage?
    @State private var isCloudOnly = false
    @State private var didFail = false
    @State private var reloadID = UUID()

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
        .task(id: "\(asset.id)-\(Int(targetSize.width))-\(reloadID)") {
            let result = await client.thumbnail(for: asset.localIdentifier, targetSize: targetSize)
            guard !Task.isCancelled else { return }
            image = result.image
            isCloudOnly = result.isCloudOnly
            didFail = result.image == nil && !result.isCloudOnly
        }
        .simultaneousGesture(TapGesture().onEnded {
            if didFail {
                reloadID = UUID()
            }
        })
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
