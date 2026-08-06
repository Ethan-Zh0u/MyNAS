import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    let authorization: PhotoAuthorizationState
    let onManageLimited: () -> Void
    let assets: [LocalPhotoAsset]
    let photoClient: PhotoLibraryClient
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    @AppStorage("photoTimelineShowsUnified") private var showsUnifiedTimeline = true
    private let cacheDirectories = CacheDirectoryProvider()
    private let cacheManager = RemotePhotoCacheManager()
    private let connectionService = MyNASConnectionService()
    @State private var isConnectionPresented = false
    @State private var serverTemperatureC: Double?
    @State private var isTemperatureLoading = false
    @State private var isRefreshingConnection = false
    @State private var connectionRefreshError: String?
    @State private var cacheUsage: RemotePhotoCacheUsage = .empty
    @State private var isLoadingCacheUsage = false
    @State private var isManagingCache = false
    @State private var showsClearCacheConfirmation = false
    @State private var cacheStatusMessage: String?
    @State private var cacheError: String?

    private let retainedCacheLimit: Int64 = 256 * 1024 * 1024

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
                                    "原件已上传 \(backupProgress.countText) 项 · \(backupCoordinator.headline(for: accountStore.current.accountID, assets: assets))"
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

                    if !accountStore.current.isLocalOnly {
                        Button {
                            Task { await refreshConnection() }
                        } label: {
                            Label(
                                isRefreshingConnection ? "正在刷新连接信息…" : "刷新连接信息",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(isRefreshingConnection)

                        if let connectionRefreshError {
                            Label(connectionRefreshError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

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
                        Label("当前仅可访问部分图片", systemImage: "rectangle.badge.person.crop")
                            .foregroundStyle(.secondary)
                        Text("MyNAS Photos 只会显示系统授权给它的照片和视频，不会声称已访问完整照片库。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("管理允许访问的照片", action: onManageLimited)
                    }
                    Text("缩略图请求不会隐式从 iCloud 下载完整资源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("隐私与本地分析") {
                    NavigationLink {
                        LocalAnalysisSettingsView(photoClient: photoClient)
                    } label: {
                        Label("端侧分析与本地索引", systemImage: "hand.raised.square")
                    }
                    Text("在此管理端侧像素分析和 OCR 的独立许可与可删除索引；文字与内容检索统一从“照片”主页的搜索入口使用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !accountStore.current.isLocalOnly {
                    Section("照片显示") {
                        Toggle(isOn: $showsUnifiedTimeline) {
                            Label("统一时间线", systemImage: "rectangle.3.group.bubble.left")
                        }
                        Text("在“照片”中按拍摄时间同时显示本机照片和仅在 MyNAS 的项目。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("只有 MyNAS 已确认、且仍对应当前本机版本的备份才会合并；不会按文件名、日期或缩略图猜测同一项目。此开关只改变显示，不会上传、下载、合并或删除照片。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("存储与缓存") {
                    LabeledContent("当前缓存命名空间", value: accountStore.current.cacheNamespace)
                    Text(cachePathText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LabeledContent("缓存占用", value: cacheUsageText)
                    LabeledContent("缓存条目", value: "\(cacheUsage.entryCount)")

                    if isLoadingCacheUsage || isManagingCache {
                        HStack(spacing: 9) {
                            ProgressView()
                            Text(isManagingCache ? "正在管理当前账号缓存…" : "正在统计当前账号缓存…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await refreshCacheUsage() }
                    } label: {
                        Label("刷新缓存统计", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoadingCacheUsage || isManagingCache)

                    Button {
                        Task { await trimCacheToRetainedLimit() }
                    } label: {
                        Label("按最近使用清理至 256 MB", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .disabled(isLoadingCacheUsage || isManagingCache || cacheUsage.totalByteCount <= retainedCacheLimit)

                    Button(role: .destructive) {
                        showsClearCacheConfirmation = true
                    } label: {
                        Label("清除当前账号缓存", systemImage: "trash")
                    }
                    .disabled(isLoadingCacheUsage || isManagingCache || cacheUsage.totalByteCount == 0)

                    if let cacheStatusMessage {
                        Text(cacheStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("只会清理这个账号的应用缓存：先处理临时下载，再按最近使用顺序处理预览、缩略图和元数据；不会删除系统照片或 MyNAS 原件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("应用", value: "MyNAS Photos")
                    LabeledContent("当前开发目标", value: "阶段 I · 本地可删除搜索索引")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $isConnectionPresented) {
                MyNASConnectionView()
                    .environmentObject(accountStore)
            }
            .confirmationDialog(
                "清除当前账号缓存？",
                isPresented: $showsClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("清除缓存", role: .destructive) {
                    Task { await clearCurrentAccountCache() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会清除当前账号的临时下载、预览、缩略图和元数据缓存。系统照片和 MyNAS 原件不会受到影响。")
            }
            .alert(
                "无法管理缓存",
                isPresented: Binding(
                    get: { cacheError != nil },
                    set: { if !$0 { cacheError = nil } }
                )
            ) {
                Button("好", role: .cancel) { cacheError = nil }
            } message: {
                Text(cacheError ?? "")
            }
            .task(id: accountStore.current.accountID) {
                await monitorServerTemperature()
            }
            .task(id: "cache-\(accountStore.current.accountID)") {
                await refreshCacheUsage()
            }
        }
    }

    private var currentServerName: String {
        accountStore.current.serverURL?.host() ?? "尚未连接"
    }

    private var backupProgress: PhotoBackupProgressSnapshot {
        backupCoordinator.progress(
            for: accountStore.current.accountID,
            assets: assets
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
        do {
            return try cacheDirectories.existingRootDirectory(for: accountStore.current)?.path
                ?? "将在首次写入缓存时创建"
        } catch {
            return "缓存目录暂不可用"
        }
    }

    private var cacheUsageText: String {
        ByteCountFormatter.string(
            fromByteCount: cacheUsage.totalByteCount,
            countStyle: .file
        )
    }

    private func refreshCacheUsage() async {
        guard !isLoadingCacheUsage, !isManagingCache else { return }
        let account = accountStore.current
        isLoadingCacheUsage = true
        cacheStatusMessage = nil
        defer {
            if account.accountID == accountStore.current.accountID {
                isLoadingCacheUsage = false
            }
        }
        do {
            let usage = try await cacheManager.usage(for: account)
            guard account.accountID == accountStore.current.accountID else { return }
            cacheUsage = usage
        } catch {
            guard account.accountID == accountStore.current.accountID else { return }
            cacheError = error.localizedDescription
        }
    }

    private func trimCacheToRetainedLimit() async {
        guard !isManagingCache, !isLoadingCacheUsage else { return }
        let account = accountStore.current
        isManagingCache = true
        cacheStatusMessage = nil
        defer {
            if account.accountID == accountStore.current.accountID {
                isManagingCache = false
            }
        }
        do {
            let result = try await cacheManager.trim(
                account: account,
                maximumByteCount: retainedCacheLimit
            )
            guard account.accountID == accountStore.current.accountID else { return }
            cacheUsage = result.remainingUsage
            cacheStatusMessage = result.removedEntryCount == 0
                ? "缓存已在 256 MB 保留范围内。"
                : "已清理 \(result.removedEntryCount) 项旧缓存，释放 \(ByteCountFormatter.string(fromByteCount: result.removedByteCount, countStyle: .file))。"
        } catch {
            guard account.accountID == accountStore.current.accountID else { return }
            cacheError = error.localizedDescription
        }
    }

    private func clearCurrentAccountCache() async {
        guard !isManagingCache, !isLoadingCacheUsage else { return }
        let account = accountStore.current
        isManagingCache = true
        cacheStatusMessage = nil
        defer {
            if account.accountID == accountStore.current.accountID {
                isManagingCache = false
            }
        }
        do {
            let result = try await cacheManager.clear(account: account)
            guard account.accountID == accountStore.current.accountID else { return }
            cacheUsage = result.remainingUsage
            cacheStatusMessage = result.removedEntryCount == 0
                ? "当前账号没有可清理的缓存。"
                : "已清除 \(result.removedEntryCount) 项缓存，释放 \(ByteCountFormatter.string(fromByteCount: result.removedByteCount, countStyle: .file))。"
        } catch {
            guard account.accountID == accountStore.current.accountID else { return }
            cacheError = error.localizedDescription
        }
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

    private func refreshConnection() async {
        guard let serverURL = accountStore.current.serverURL else { return }

        isRefreshingConnection = true
        connectionRefreshError = nil
        defer { isRefreshingConnection = false }

        do {
            let result = try await connectionService.connect(
                address: serverURL.absoluteString,
                expectedServerID: accountStore.current.serverID
            )
            accountStore.saveConnectedAccount(result.account)
        } catch {
            connectionRefreshError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
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
