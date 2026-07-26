import AVKit
import SwiftUI

struct RemotePhotoLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: RemotePhotoLibraryViewModel
    @AppStorage("remotePhotoGridColumnCount") private var columnCount = 4
    @State private var pinchStartColumnCount: Int?

    private let minimumColumnCount = 2
    private let maximumColumnCount = 10
    private let gridSpacing: CGFloat = 2

    init(account: AccountContext) {
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
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法读取 MyNAS 图库", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
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
        .task {
            await viewModel.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await viewModel.checkForRemoteChanges()
            }
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
                        NavigationLink {
                            RemotePhotoDetailView(
                                asset: asset,
                                account: viewModel.account,
                                client: viewModel.client
                            )
                        } label: {
                            RemotePhotoGridCell(
                                asset: asset,
                                account: viewModel.account,
                                client: viewModel.client
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

                Text("只读")
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
                    .font(.title2)
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
                image = UIImage(data: result.data)
                didFail = image == nil
            } catch {
                guard !Task.isCancelled else { return }
                didFail = true
            }
        }
    }
}

struct RemotePhotoDetailView: View {
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                mediaPreview
                .aspectRatio(
                    asset.pixelWidth > 0 && asset.pixelHeight > 0
                        ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                        : 1,
                    contentMode: .fit
                )
                .frame(maxHeight: 560)
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

                    if let captureDate = asset.captureDate {
                        LabeledContent("拍摄时间", value: formattedDate(captureDate))
                    }
                }
                .padding(.horizontal)

                RemoteOriginalResourcesCard(resources: asset.resources)
                    .padding(.horizontal)

                Text("当前阶段只读取 MyNAS 中的预览、元数据和视频原件流，不会修改、导出或删除服务器原件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("MyNAS 预览")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var mediaPreview: some View {
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

    private func formattedDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

private struct RemoteVideoPreview: View {
    let resource: ServerPhotoResource?
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    @State private var player: AVPlayer?
    @State private var resourceLoader: MyNASMediaResourceLoader?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if didFail {
                remotePreviewUnavailable(
                    title: "无法从 MyNAS 播放视频",
                    symbol: "video.slash",
                    message: "请检查 Tailscale 连接后重试。视频不会被完整下载到 iPhone。"
                )
            } else {
                remotePreviewProgress("正在从 MyNAS 缓冲视频…")
            }
        }
        .task(id: resource?.id) {
            guard let resource else {
                didFail = true
                return
            }
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
                guard try await urlAsset.load(.isPlayable) else {
                    didFail = true
                    return
                }
                guard !Task.isCancelled else { return }
                resourceLoader = loader
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: urlAsset))
                player = newPlayer
                newPlayer.play()
            } catch {
                guard !Task.isCancelled else { return }
                didFail = true
            }
        }
        .onDisappear { player?.pause() }
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
        .onDisappear { player?.pause() }
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
            guard try await urlAsset.load(.isPlayable) else {
                didFail = true
                return
            }
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
