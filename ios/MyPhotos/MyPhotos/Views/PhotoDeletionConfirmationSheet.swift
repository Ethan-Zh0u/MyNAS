import SwiftUI

struct PhotoDeletionRequest: Identifiable {
    let assets: [LocalPhotoAsset]
    let backupCandidates: [PhotoBackupDeletionCandidate]
    let isConnectedToMyNAS: Bool
    let isMyNASDeletionAvailable: Bool

    var id: String {
        assets.map(\.localIdentifier).sorted().joined(separator: "|")
    }

    func canAlsoDeleteMyNASBackups(
        when remoteMutationAvailability: MyNASRemoteMutationAvailability
    ) -> Bool {
        isConnectedToMyNAS
            && remoteMutationAvailability.allowsRemoteMutation
            && isMyNASDeletionAvailable
            && !assets.isEmpty
            && backupCandidates.count == assets.count
    }

    func myNASUnavailableExplanation(
        when remoteMutationAvailability: MyNASRemoteMutationAvailability
    ) -> String {
        if !isConnectedToMyNAS {
            return "未连接 MyNAS；本次只能移入 iPhone 的“最近删除”。"
        }
        if let statusText = remoteMutationAvailability.statusText {
            return "\(statusText) 本次仍可只将本机项目移入 iPhone 的“最近删除”。"
        }
        if !isMyNASDeletionAvailable {
            return "当前 MyNAS 尚未支持永久删除照片备份；本次只能移入 iPhone 的“最近删除”。"
        }
        return "选择中含有未完成备份、旧版本或无法验证的照片；为保护原件，不能同步删除 MyNAS 备份。"
    }
}

struct PhotoDeletionConfirmationSheet: View {
    let request: PhotoDeletionRequest
    let isDeleting: Bool
    let remoteMutationAvailability: MyNASRemoteMutationAvailability
    let confirm: (_ alsoDeleteMyNASBackups: Bool) -> Void

    @State private var alsoDeleteMyNASBackups = false

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
                    Toggle("同时永久删除 MyNAS 备份", isOn: $alsoDeleteMyNASBackups)
                        .disabled(
                            !request.canAlsoDeleteMyNASBackups(when: remoteMutationAvailability)
                                || isDeleting
                        )

                    if request.canAlsoDeleteMyNASBackups(when: remoteMutationAvailability) {
                        Text("默认关闭。开启后，MyNAS 会再次确认每一项仍是当前已验证的完整备份，且没有被其他设备共用；确认后将永久删除整个资源组。若想找回，请先在 iPhone“最近删除”中恢复，再重新备份。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            request.myNASUnavailableExplanation(when: remoteMutationAvailability),
                            systemImage: remoteMutationAvailability == .tailscaleUnavailable
                                ? "wifi.exclamationmark"
                                : "lock.fill"
                        )
                            .font(.footnote)
                            .foregroundStyle(
                                remoteMutationAvailability == .tailscaleUnavailable
                                    ? Color.orange
                                    : Color.secondary
                            )
                    }
                }
                .padding()
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    confirm(
                        alsoDeleteMyNASBackups
                            && request.canAlsoDeleteMyNASBackups(when: remoteMutationAvailability)
                    )
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(alsoDeleteMyNASBackups
                                && request.canAlsoDeleteMyNASBackups(when: remoteMutationAvailability)
                                ? "删除本机和 MyNAS 备份"
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
        .onChange(of: remoteMutationAvailability) { _, availability in
            if !availability.allowsRemoteMutation {
                alsoDeleteMyNASBackups = false
            }
        }
    }
}
