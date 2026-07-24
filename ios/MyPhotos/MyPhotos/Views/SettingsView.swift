import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    let authorization: PhotoAuthorizationState
    let onManageLimited: () -> Void
    let assets: [LocalPhotoAsset]
    let photoClient: PhotoLibraryClient
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    private let cacheDirectories = CacheDirectoryProvider()
    private let connectionService = MyNASConnectionService()
    @State private var isConnectionPresented = false
    @State private var serverTemperatureC: Double?
    @State private var isTemperatureLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AccountDetailView(account: accountStore.current)
                    } label: {
                        HStack(spacing: 14) {
                            AccountAvatar(name: accountStore.current.displayName, diameter: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(accountStore.current.displayName)
                                    .font(.headline)
                                Text("个人信息与 MyNAS 账号")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityLabel("个人信息，\(accountStore.current.displayName)")
                }

                Section("主要功能") {
                    NavigationLink {
                        PhotoBackupView(
                            coordinator: backupCoordinator,
                            assets: assets,
                            client: photoClient
                        )
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .symbolEffect(.pulse, isActive: backupProgress.isRunning)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("照片与视频备份")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(backupProgress.percentage)%")
                                        .font(.headline)
                                        .monospacedDigit()
                                }
                                ProgressView(value: backupProgress.fractionCompleted)
                                Text(
                                    "原件已上传 \(backupProgress.countText) 项 · \(backupCoordinator.headline)"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityLabel(
                        "照片与视频备份，原件已安全上传 \(backupProgress.completedCount) 项，共 \(backupProgress.totalCount) 项，\(backupProgress.percentage)%"
                    )

                    Text("保留 Live Photo、HDR、RAW / ProRAW 原始资源；点击进入备份队列。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("MyNAS") {
                    LabeledContent("当前服务器") {
                        HStack(spacing: 8) {
                            Text(currentServerName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !accountStore.current.isLocalOnly {
                                ServerTemperatureBadge(
                                    temperatureC: serverTemperatureC,
                                    isLoading: isTemperatureLoading
                                )
                            }
                        }
                    }
                    LabeledContent("当前账号", value: accountStore.current.displayName)
                    LabeledContent("存储盘", value: selectedVolumeName)

                    Button {
                        isConnectionPresented = true
                    } label: {
                        Label(
                            accountStore.current.isLocalOnly ? "连接 MyNAS" : "添加另一台 MyNAS",
                            systemImage: "externaldrive.badge.plus"
                        )
                    }
                }

                if accountStore.accounts.count > 1 {
                    Section("账号与服务器") {
                        ForEach(accountStore.accounts) { account in
                            Button {
                                accountStore.activate(account)
                            } label: {
                                HStack {
                                    AccountAvatar(name: account.displayName, diameter: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                            .foregroundStyle(.primary)
                                        Text(account.serverURL?.host() ?? "仅本地图库")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if account.accountID == accountStore.current.accountID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityLabel(
                                "\(account.displayName)，\(account.accountID == accountStore.current.accountID ? "当前账号" : "切换账号")"
                            )
                        }
                    }
                }

                Section("本地照片") {
                    LabeledContent("Photos 权限", value: permissionText)
                    if authorization == .limited {
                        Button("管理允许访问的照片", action: onManageLimited)
                    }
                    Text("缩略图请求不会隐式从 iCloud 下载完整资源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("存储与缓存") {
                    LabeledContent("当前缓存命名空间", value: accountStore.current.cacheNamespace)
                    Text(cachePathText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("缓存统计、清理和 LRU 会在 MyNAS 连接与下载阶段提供。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("应用", value: "MyNAS Photos")
                    LabeledContent("当前开发目标", value: "阶段 E · 可浏览备份")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $isConnectionPresented) {
                MyNASConnectionView()
                    .environmentObject(accountStore)
            }
            .task(id: accountStore.current.accountID) {
                await monitorServerTemperature()
            }
        }
    }

    private var currentServerName: String {
        accountStore.current.serverURL?.host() ?? "尚未连接"
    }

    private var backupProgress: PhotoBackupProgressSnapshot {
        backupCoordinator.progress(
            for: accountStore.current.accountID,
            fallbackTotalCount: assets.count
        )
    }

    private var selectedVolumeName: String {
        guard let selectedID = accountStore.current.selectedVolumeID else {
            return accountStore.current.isLocalOnly ? "将在连接后选择" : "尚未选择"
        }
        return accountStore.current.availableVolumes.first { $0.id == selectedID }?.name ?? selectedID
    }

    private var permissionText: String {
        switch authorization {
        case .authorized: "完整访问"
        case .limited: "部分照片"
        case .notDetermined: "未请求"
        case .denied: "已关闭"
        }
    }

    private var cachePathText: String {
        let path = try? cacheDirectories.rootDirectory(for: accountStore.current).path
        return path ?? "将在首次写入缓存时创建"
    }

    private func monitorServerTemperature() async {
        serverTemperatureC = nil
        guard let serverURL = accountStore.current.serverURL else {
            isTemperatureLoading = false
            return
        }

        isTemperatureLoading = true
        while !Task.isCancelled {
            do {
                let health = try await connectionService.health(from: serverURL)
                serverTemperatureC = health.temperatureC
            } catch {
                serverTemperatureC = nil
            }
            isTemperatureLoading = false
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }
}

private struct ServerTemperatureBadge: View {
    let temperatureC: Double?
    let isLoading: Bool

    var body: some View {
        if #available(iOS 26.0, *) {
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Image(systemName: "thermometer.medium")
            Text(displayText)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("树莓派实时温度，\(accessibilityText)")
    }

    private var displayText: String {
        if let temperatureC {
            return temperatureC.formatted(
                .number.precision(.fractionLength(1))
            ) + "°C"
        }
        return isLoading ? "读取中" : "—"
    }

    private var accessibilityText: String {
        if let temperatureC {
            return temperatureC.formatted(
                .number.precision(.fractionLength(1))
            ) + " 摄氏度"
        }
        return isLoading ? "正在读取" : "暂不可用"
    }

    private var tint: Color {
        guard let temperatureC else { return .secondary }
        if temperatureC >= 80 { return .red }
        if temperatureC >= 70 { return .orange }
        return .accentColor
    }
}

struct AccountAvatar: View {
    let name: String
    let diameter: CGFloat

    var body: some View {
        Text(initial)
            .font(.system(size: diameter * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Color.accentColor.gradient, in: Circle())
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)?.uppercased() ?? "M"
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let account: AccountContext

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AccountAvatar(name: liveAccount.displayName, diameter: 54)
                    VStack(alignment: .leading) {
                        Text(liveAccount.displayName)
                            .font(.headline)
                        Text(liveAccount.isLocalOnly ? "本地图库模式" : "Tailscale 身份已验证")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("连接") {
                LabeledContent(
                    "MyNAS 用户",
                    value: liveAccount.isLocalOnly ? "尚未连接" : liveAccount.authenticationIdentity
                )
                LabeledContent("服务器", value: liveAccount.serverURL?.host() ?? "尚未连接")
                if liveAccount.availableVolumes.isEmpty {
                    LabeledContent("存储盘", value: "尚未选择")
                } else {
                    Picker(
                        "存储盘",
                        selection: Binding(
                            get: { liveAccount.selectedVolumeID ?? "" },
                            set: { accountStore.selectVolume($0, for: liveAccount.accountID) }
                        )
                    ) {
                        ForEach(liveAccount.availableVolumes) { volume in
                            Text(volumeLabel(volume)).tag(volume.id)
                        }
                    }
                }
            }

            Section {
                Text(
                    liveAccount.isLocalOnly
                        ? "连接 MyNAS 后，Tailscale 会负责网络与登录；MyNAS Photos 不保存你的 Tailscale 密码。"
                        : "缓存和后续传输都绑定到 \(liveAccount.cacheNamespace)，切换账号不会共用缓存。"
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !liveAccount.isLocalOnly {
                Section {
                    Button("移除此连接", role: .destructive) {
                        accountStore.remove(liveAccount)
                        dismiss()
                    }
                } footer: {
                    Text("只移除本机保存的连接信息，不会退出 Tailscale，也不会删除 NAS 上的内容。")
                }
            }
        }
        .navigationTitle("个人信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var liveAccount: AccountContext {
        accountStore.accounts.first { $0.accountID == account.accountID } ?? account
    }

    private func volumeLabel(_ volume: MyNASVolume) -> String {
        let status = volume.isOnline ? ByteCountFormatter.string(
            fromByteCount: Int64(clamping: volume.availableBytes),
            countStyle: .file
        ) + " 可用" : "离线"
        return "\(volume.name) · \(status)"
    }
}
