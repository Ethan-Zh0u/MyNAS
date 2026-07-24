import SwiftUI

struct PhotoDetailView: View {
    let asset: LocalPhotoAsset
    let client: PhotoLibraryClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhotoThumbnailView(asset: asset, targetSize: CGSize(width: 2_000, height: 2_000), client: client)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? "拍摄日期未知")
                        .font(.title3.weight(.semibold))

                    LabeledContent("类型", value: asset.mediaKind.displayName)
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

                Label(
                    "本阶段仅显示本地项目；尚未上传到 MyNAS。",
                    systemImage: "iphone"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(asset.mediaKind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = asset.duration >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: asset.duration) ?? "未知"
    }
}
