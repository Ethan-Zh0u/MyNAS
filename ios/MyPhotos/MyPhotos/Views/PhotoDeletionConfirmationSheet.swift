import SwiftUI

struct PhotoDeletionRequest: Identifiable {
    let assets: [LocalPhotoAsset]
    let backupCandidates: [PhotoBackupTrashCandidate]
    let isConnectedToMyNAS: Bool
    let isMyNASTrashAvailable: Bool

    var id: String {
        assets.map(\.localIdentifier).sorted().joined(separator: "|")
    }

    var canAlsoMoveMyNASBackups: Bool {
        isConnectedToMyNAS
            && isMyNASTrashAvailable
            && !assets.isEmpty
            && backupCandidates.count == assets.count
    }

    var myNASUnavailableExplanation: String {
        if !isConnectedToMyNAS {
            return "未连接 MyNAS；本次只能移入 iPhone 的“最近删除”。"
        }
        if !isMyNASTrashAvailable {
            return "当前 MyNAS 尚未部署照片回收站；本次只能移入 iPhone 的“最近删除”。"
        }
        return "选择中含有未完成备份、旧版本或无法验证的照片；为保护原件，不能同步删除 MyNAS 备份。"
    }
}

struct PhotoDeletionConfirmationSheet: View {
    let request: PhotoDeletionRequest
    let isDeleting: Bool
    let confirm: (_ alsoMoveMyNASBackups: Bool) -> Void

    @State private var alsoMoveMyNASBackups = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.red)

                Text("移除 \(request.assets.count) 项照片或视频？")
                    .font(.title3.weight(.semibold))

                Text("本机项目会由 iOS 移入系统“最近删除”。MyNAS Photos 不会直接访问或擦除系统照片文件。")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("同时移入 MyNAS 回收站", isOn: $alsoMoveMyNASBackups)
                        .disabled(!request.canAlsoMoveMyNASBackups || isDeleting)

                    if request.canAlsoMoveMyNASBackups {
                        Text("默认关闭。开启后，MyNAS 会再次确认每一项仍是当前已验证的完整备份，且没有被其他设备共用；通过后才会移动整个资源组。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(request.myNASUnavailableExplanation, systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    confirm(alsoMoveMyNASBackups && request.canAlsoMoveMyNASBackups)
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(alsoMoveMyNASBackups && request.canAlsoMoveMyNASBackups
                                ? "移入两个回收站"
                                : "移入最近删除")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDeleting)
            }
            .padding(24)
            .navigationTitle("删除确认")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isDeleting)
    }
}
