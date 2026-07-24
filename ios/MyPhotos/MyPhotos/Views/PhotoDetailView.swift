import AVKit
import PhotosUI
import SwiftUI

struct PhotoDetailView: View {
    let asset: LocalPhotoAsset
    let isBackedUp: Bool
    let client: PhotoLibraryClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mediaPreview
                    .frame(maxWidth: .infinity)
                    .aspectRatio(mediaAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? "拍摄日期未知")
                        .font(.title3.weight(.semibold))

                    LabeledContent("类型", value: asset.displayMediaName)
                    if asset.isRAW {
                        Label("保留 DNG 原始数据与完整动态范围", systemImage: "camera.aperture")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("尺寸", value: asset.pixelSizeText)
                    if asset.mediaKind == .video {
                        LabeledContent("时长", value: durationText)
                    }
                    if asset.isFavorite {
                        Label("已在系统照片中收藏", systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                }
                .padding(.horizontal)

                Label(backupStatusText, systemImage: backupStatusSymbol)
                    .font(.footnote)
                    .foregroundStyle(isBackedUp ? .green : .secondary)
                    .padding()
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(asset.displayMediaName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var mediaPreview: some View {
        switch asset.mediaKind {
        case .photo:
            LocalPhotoPreview(asset: asset, client: client)
        case .video:
            LocalVideoPreview(asset: asset, client: client)
        case .livePhoto:
            LocalLivePhotoPreview(asset: asset, client: client)
        }
    }

    private var mediaAspectRatio: CGFloat {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return 1 }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    private var backupStatusText: String {
        isBackedUp
            ? "原始资源已经由 MyNAS 完整性校验并安全提交。"
            : "这个本地项目尚未完成 MyNAS 原件备份。"
    }

    private var backupStatusSymbol: String {
        isBackedUp ? "checkmark.circle.fill" : "iphone"
    }

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = asset.duration >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: asset.duration) ?? "未知"
    }
}

private struct LocalPhotoPreview: View {
    let asset: LocalPhotoAsset
    let client: PhotoLibraryClient
    @State private var image: UIImage?
    @State private var isCloudOnly = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isCloudOnly {
                previewUnavailable(
                    title: "原件仍在 iCloud",
                    symbol: "icloud",
                    message: "检查网络后重新打开此照片。"
                )
            } else {
                previewProgress("正在读取照片…")
            }
        }
        .task(id: asset.localIdentifier) {
            let result = await client.previewImage(
                for: asset.localIdentifier,
                targetSize: CGSize(width: 2_560, height: 2_560)
            )
            image = result.image
            isCloudOnly = result.isCloudOnly
        }
    }
}

private struct LocalVideoPreview: View {
    let asset: LocalPhotoAsset
    let client: PhotoLibraryClient
    @State private var player: AVPlayer?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if didFail {
                previewUnavailable(
                    title: "无法读取视频",
                    symbol: "video.slash",
                    message: "原件可能仍在 iCloud，或当前网络不可用。"
                )
            } else {
                previewProgress("正在读取视频…")
            }
        }
        .task(id: asset.localIdentifier) {
            guard let item = await client.playerItem(for: asset.localIdentifier) else {
                didFail = true
                return
            }
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct LocalLivePhotoPreview: View {
    let asset: LocalPhotoAsset
    let client: PhotoLibraryClient
    @State private var livePhoto: PHLivePhoto?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black
            if let livePhoto {
                LivePhotoPlayer(livePhoto: livePhoto)
            } else if didFail {
                previewUnavailable(
                    title: "无法读取 Live Photo",
                    symbol: "livephoto.slash",
                    message: "请检查 iCloud 和网络状态。"
                )
            } else {
                previewProgress("正在读取 Live Photo…")
            }
        }
        .task(id: asset.localIdentifier) {
            livePhoto = await client.livePhoto(
                for: asset.localIdentifier,
                targetSize: CGSize(width: 2_560, height: 2_560)
            )
            didFail = livePhoto == nil
        }
    }
}

private struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        guard view.livePhoto !== livePhoto else { return }
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
    }
}

@ViewBuilder
private func previewProgress(_ title: String) -> some View {
    ProgressView(title)
        .tint(.white)
        .foregroundStyle(.white)
}

@ViewBuilder
private func previewUnavailable(
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
