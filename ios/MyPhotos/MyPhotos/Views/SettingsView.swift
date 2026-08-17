import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    let authorization: PhotoAuthorizationState
    let onManageLimited: () -> Void
    let assets: [LocalPhotoAsset]
    let photoClient: PhotoLibraryClient
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    @ObservedObject var textIndex: PhotoTextIndexViewModel
    @ObservedObject var semanticIndex: LocalSemanticModelViewModel

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
                                Text("个人信息与账号")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityLabel("个人信息，\(accountStore.current.displayName)")
                }

                Section("MyNAS") {
                    NavigationLink {
                        MyNASSettingsView()
                    } label: {
                        SettingsDestinationRow(
                            title: "MyNAS",
                            detail: myNASStatus,
                            systemImage: accountStore.current.isLocalOnly
                                ? "externaldrive"
                                : "externaldrive.fill",
                            tint: accountStore.current.isLocalOnly ? .secondary : .accentColor
                        )
                    }
                }

                Section("照片") {
                    NavigationLink {
                        PhotoBackupView(
                            coordinator: backupCoordinator,
                            assets: assets,
                            client: photoClient
                        )
                    } label: {
                        BackupSettingsSummary(
                            progress: backupProgress,
                            headline: backupCoordinator.headline(
                                for: accountStore.current.accountID,
                                assets: assets
                            )
                        )
                    }
                    .accessibilityLabel(
                        "照片与视频备份，原件已安全上传 \(backupProgress.completedCount) 项，共 \(backupProgress.totalCount) 项，\(backupProgress.percentage)%"
                    )

                    NavigationLink {
                        PhotoLibrarySettingsView(
                            authorization: authorization,
                            onManageLimited: onManageLimited
                        )
                    } label: {
                        SettingsDestinationRow(
                            title: "照片库",
                            detail: permissionText,
                            systemImage: "photo.on.rectangle"
                        )
                    }
                }

                Section("隐私") {
                    NavigationLink {
                        LocalAnalysisSettingsView(
                            photoClient: photoClient,
                            semanticIndex: semanticIndex,
                            textIndex: textIndex
                        )
                    } label: {
                        SettingsDestinationRow(
                            title: "本地分析与搜索",
                            detail: "OCR 与语义模型",
                            systemImage: "hand.raised.square"
                        )
                    }
                }

                Section("存储") {
                    NavigationLink {
                        CacheSettingsView()
                    } label: {
                        SettingsDestinationRow(
                            title: "缓存",
                            detail: "下载、预览与缩略图",
                            systemImage: "internaldrive"
                        )
                    }
                }

                Section("关于") {
                    LabeledContent("应用", value: "MyNAS Photos")
                    LabeledContent("版本", value: appVersionText)
                    LabeledContent("数据位置", value: "iPhone 与你的 MyNAS")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
    }

    private var myNASStatus: String {
        accountStore.current.serverURL?.host() ?? "尚未连接"
    }

    private var backupProgress: PhotoBackupProgressSnapshot {
        backupCoordinator.progress(
            for: accountStore.current.accountID,
            assets: assets
        )
    }

    private var permissionText: String {
        switch authorization {
        case .authorized: "完整访问"
        case .limited: "部分照片"
        case .notDetermined: "未请求"
        case .denied: "已关闭"
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }

}

private struct SettingsDestinationRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    init(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color = .accentColor
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: MyPhotosMetrics.standardSpacing) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct PhotoLibrarySettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    let authorization: PhotoAuthorizationState
    let onManageLimited: () -> Void
    @AppStorage("photoTimelineShowsUnified") private var showsUnifiedTimeline = true

    var body: some View {
        List {
            Section {
                LabeledContent("Photos 权限", value: permissionText)

                if authorization == .limited {
                    Label("当前仅可访问部分照片", systemImage: "rectangle.badge.person.crop")
                        .foregroundStyle(.secondary)
                    Button("管理允许访问的照片", action: onManageLimited)
                }
            } header: {
                Text("访问")
            } footer: {
                Text("MyNAS Photos 只显示系统授权的照片和视频。缩略图不会下载 iCloud 完整原件。")
            }

            if !accountStore.current.isLocalOnly {
                Section {
                    Toggle(isOn: $showsUnifiedTimeline) {
                        Label("统一时间线", systemImage: "rectangle.3.group.bubble.left")
                    }
                } header: {
                    Text("显示")
                } footer: {
                    Text("同时显示本机与 MyNAS 项目。只会合并经 MyNAS 确认且仍匹配当前本机版本的项目；此开关不传输或删除照片。")
                }
            }
        }
        .navigationTitle("照片库")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var permissionText: String {
        switch authorization {
        case .authorized: "完整访问"
        case .limited: "部分照片"
        case .notDetermined: "未请求"
        case .denied: "已关闭"
        }
    }
}

private struct MyNASSettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    private let connectionService = MyNASConnectionService()
    @State private var isConnectionPresented = false
    @State private var serverTemperatureC: Double?
    @State private var isTemperatureLoading = false
    @State private var isRefreshingConnection = false
    @State private var connectionRefreshError: String?

    var body: some View {
        List {
            Section {
                MyNASConnectionSummary(
                    serverName: currentServerName,
                    accountName: accountStore.current.displayName,
                    volumeName: selectedVolumeName,
                    isConnected: !accountStore.current.isLocalOnly,
                    temperatureC: serverTemperatureC,
                    isTemperatureLoading: isTemperatureLoading
                )
            }

            Section("连接") {
                if accountStore.current.isLocalOnly {
                    Button {
                        isConnectionPresented = true
                    } label: {
                        Label("连接 MyNAS", systemImage: "externaldrive.badge.plus")
                    }
                } else {
                    Button {
                        Task { await refreshConnection() }
                    } label: {
                        Label(
                            isRefreshingConnection ? "正在刷新连接信息…" : "刷新连接信息",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isRefreshingConnection)

                    Button {
                        isConnectionPresented = true
                    } label: {
                        Label("添加另一台 MyNAS", systemImage: "externaldrive.badge.plus")
                    }
                }

                if let connectionRefreshError {
                    MyPhotosInlineNotice(
                        title: "连接信息未更新",
                        message: connectionRefreshError,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                }
            }

            if accountStore.accounts.count > 1 {
                Section("切换账号") {
                    ForEach(accountStore.accounts) { account in
                        AccountSwitcherRow(
                            account: account,
                            isCurrent: account.accountID == accountStore.current.accountID,
                            onActivate: { accountStore.activate(account) }
                        )
                    }
                }
            }
        }
        .navigationTitle("MyNAS")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isConnectionPresented) {
            MyNASConnectionView()
                .environmentObject(accountStore)
        }
        .task(id: accountStore.current.accountID) {
            await monitorServerTemperature()
        }
    }

    private var currentServerName: String {
        accountStore.current.serverURL?.host() ?? "尚未连接"
    }

    private var selectedVolumeName: String {
        guard let selectedID = accountStore.current.selectedVolumeID else {
            return accountStore.current.isLocalOnly ? "将在连接后选择" : "尚未选择"
        }
        return accountStore.current.availableVolumes.first { $0.id == selectedID }?.name ?? selectedID
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

private struct CacheSettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    private let cacheManager = RemotePhotoCacheManager()
    private let retainedCacheLimit: Int64 = 256 * 1024 * 1024
    @State private var cacheUsage: RemotePhotoCacheUsage = .empty
    @State private var isLoadingCacheUsage = false
    @State private var isManagingCache = false
    @State private var showsClearCacheConfirmation = false
    @State private var cacheStatusMessage: String?
    @State private var cacheError: String?

    var body: some View {
        List {
            Section("当前账号") {
                LabeledContent("缓存占用", value: cacheUsageText)
                LabeledContent("缓存条目", value: "\(cacheUsage.entryCount)")

                if isLoadingCacheUsage || isManagingCache {
                    HStack(spacing: 9) {
                        ProgressView()
                        Text(isManagingCache ? "正在管理缓存…" : "正在统计缓存…")
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await refreshCacheUsage() }
                } label: {
                    Label("刷新缓存统计", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingCacheUsage || isManagingCache)
            }

            Section {
                Button {
                    Task { await trimCacheToRetainedLimit() }
                } label: {
                    Label("清理至 256 MB", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
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
            } header: {
                Text("清理")
            } footer: {
                Text("只清理可重新下载的预览、缩略图和元数据，不会删除系统照片、MyNAS 原件或本地索引。")
            }
        }
        .navigationTitle("缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "cache-\(accountStore.current.accountID)") {
            await refreshCacheUsage()
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
            Text("会清除临时下载、预览、缩略图和元数据缓存；系统照片、MyNAS 原件与本地索引不会受到影响。")
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
                ? "缓存已在保留范围内。"
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
}

private struct AccountSwitcherRow: View {
    let account: AccountContext
    let isCurrent: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
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
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityLabel("\(account.displayName)，\(isCurrent ? "当前账号" : "切换账号")")
    }
}

private struct BackupSettingsSummary: View {
    let progress: PhotoBackupProgressSnapshot
    let headline: String

    var body: some View {
        HStack(alignment: .top, spacing: MyPhotosMetrics.standardSpacing) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: progress.isRunning)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: MyPhotosMetrics.compactSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("照片与视频备份")
                        .font(.headline)
                    Spacer(minLength: MyPhotosMetrics.compactSpacing)
                    Text("\(progress.percentage)%")
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                ProgressView(value: progress.fractionCompleted)

                Text("原件已安全上传 \(progress.countText) 项")
                    .font(.subheadline)
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MyNASConnectionSummary: View {
    let serverName: String
    let accountName: String
    let volumeName: String
    let isConnected: Bool
    let temperatureC: Double?
    let isTemperatureLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MyPhotosMetrics.standardSpacing) {
            Image(systemName: isConnected ? "externaldrive.fill" : "externaldrive")
                .font(.title2)
                .foregroundStyle(isConnected ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(serverName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: MyPhotosMetrics.compactSpacing)
                    MyPhotosStatusBadge(
                        title: isConnected ? "已连接" : "仅本机",
                        systemImage: isConnected ? "checkmark.circle.fill" : "iphone",
                        tone: isConnected ? .success : .neutral
                    )
                }

                Text(accountName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("存储盘：\(volumeName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isConnected {
                    ServerTemperatureBadge(
                        temperatureC: temperatureC,
                        isLoading: isTemperatureLoading
                    )
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
