import SwiftUI

struct PhotoBackupView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @ObservedObject var coordinator: PhotoBackupCoordinator
    let assets: [LocalPhotoAsset]
    let client: PhotoLibraryClient
    @State private var showsAllFailures = false

    private var accountJobs: [PhotoBackupJob] {
        coordinator.jobs(for: accountStore.current.accountID)
    }

    private var failedCount: Int {
        failedJobs.count
    }

    private var failedJobs: [PhotoBackupJob] {
        accountJobs.filter { $0.status == .failed }
    }

    private var retryableFailedCount: Int {
        coordinator.retryableFailedCount(
            for: assets,
            accountID: accountStore.current.accountID
        )
    }

    private var visibleFailedJobs: [PhotoBackupJob] {
        showsAllFailures ? failedJobs : Array(failedJobs.prefix(100))
    }

    private var queueJobs: [PhotoBackupJob] {
        accountJobs.filter { $0.status != .failed }
    }

    private var visibleQueueJobs: [PhotoBackupJob] {
        Array(queueJobs.prefix(50))
    }

    private var backupProgress: PhotoBackupProgressSnapshot {
        coordinator.progress(
            for: accountStore.current.accountID,
            assets: assets
        )
    }

    private var pendingCount: Int {
        coordinator.pendingCount(
            for: assets,
            accountID: accountStore.current.accountID
        )
    }

    private var automationPolicy: PhotoBackupAutomationPolicy {
        coordinator.automationPolicy(for: accountStore.current)
    }

    private var automationStatus: PhotoBackupAutomationStatus {
        coordinator.automationStatus(for: accountStore.current)
    }

    private var automationFooter: String {
        if accountStore.current.serverCapabilities.supportsBackgroundTransfers {
            return "新项目仍只在 App 前台通过 PhotoKit 发现；仅在 iCloud 的原件也由 iPhone 系统照片框架按独立开关下载，MyNAS 不会直连 iCloud。已准备且此账号允许的上传可交给 iOS background URLSession/BGTask 续接；网络、电量和系统调度仍可能延后。"
        }
        return "当前仅在 App 前台通过 PhotoKit 发现项目并准备原件；仅在 iCloud 的原件也由 iPhone 按独立开关下载，MyNAS 不会直连 iCloud。此服务器不支持系统后台传输，锁屏、退出 App 或系统回收后不保证继续上传。"
    }

    var body: some View {
        List {
            Section {
                BackupSummaryCard(
                    headline: coordinator.headline(
                        for: accountStore.current.accountID,
                        assets: assets
                    ),
                    progress: backupProgress
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("手动备份") {
                if accountStore.current.isLocalOnly {
                    Label("请先在“设置”中连接 MyNAS", systemImage: "externaldrive.badge.plus")
                        .foregroundStyle(.secondary)
                } else {
                    startButton
                    if failedCount > 0 {
                        retryFailedButton
                        if retryableFailedCount < failedCount {
                            Label(
                                "\(failedCount - retryableFailedCount) 个失败项目当前不在照片访问范围内",
                                systemImage: "photo.badge.exclamationmark"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                Text("此按钮会立即检查并补充当前可访问的未完成项目。网络中断时会从 MyNAS 已记录的字节位置继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if accountStore.current.isLocalOnly {
                    Label("连接 MyNAS 后可为每个账号单独设置自动备份", systemImage: "externaldrive.badge.plus")
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(
                        "前台自动备份",
                        isOn: Binding(
                            get: { automationPolicy.isEnabled },
                            set: { coordinator.setAutomaticBackupEnabled($0, for: accountStore.current) }
                        )
                    )

                    if automationPolicy.isEnabled {
                        Picker(
                            "自动上传网络",
                            selection: Binding(
                                get: { automationPolicy.networkPolicy },
                                set: { coordinator.setAutomaticNetworkPolicy($0, for: accountStore.current) }
                            )
                        ) {
                            ForEach(PhotoBackupAutomaticNetworkPolicy.allCases, id: \.self) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }

                        Toggle(
                            "低电量模式暂停",
                            isOn: Binding(
                                get: { automationPolicy.pausesInLowPowerMode },
                                set: { coordinator.setAutomaticLowPowerPause($0, for: accountStore.current) }
                            )
                        )

                        Toggle(
                            "自动下载 iCloud 原件",
                            isOn: Binding(
                                get: { automationPolicy.automaticallyDownloadsICloudOriginals },
                                set: {
                                    coordinator.setAutomaticICloudOriginalDownload(
                                        $0,
                                        for: accountStore.current
                                    )
                                }
                            )
                        )

                        Text(
                            automationPolicy.automaticallyDownloadsICloudOriginals
                                ? "需要时，iPhone 会先通过系统照片框架下载完整原件，再交给 MyNAS 备份；不会删除系统相册中的项目。"
                                : "默认关闭。仅在 iCloud 的原件会等待；点“立即备份”仍可手动下载并备份。"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        automationPauseButton
                    }

                    Label(automationStatus.title, systemImage: automationStatus.systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(automationPolicy.isEnabled ? .primary : .secondary)
                    Text(automationStatus.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if automationPolicy.isEnabled {
                        Text(automationPolicy.networkPolicy.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("自动备份")
            } footer: {
                Text(automationFooter)
            }

            if !failedJobs.isEmpty {
                Section {
                    ForEach(visibleFailedJobs) { job in
                        BackupJobRow(job: job)
                    }
                    if failedJobs.count > 100 {
                        Button(showsAllFailures ? "只显示最近 100 项" : "显示全部 \(failedJobs.count) 个失败项目") {
                            showsAllFailures.toggle()
                        }
                    }
                } header: {
                    Label("需要处理（\(failedJobs.count)）", systemImage: "exclamationmark.triangle.fill")
                } footer: {
                    Text("已完成项目不会重新上传；重试会继续使用 MyNAS 已确认的分片位置。")
                }
            }

            Section("原始格式") {
                Label("Live Photo：静态原图与配对视频整组提交", systemImage: "livephoto")
                Label("HDR：保留原始 HEIC/HEVC 与动态范围元数据", systemImage: "sun.max")
                Label("RAW / ProRAW：保留 DNG、辅助照片与调整数据", systemImage: "camera.aperture")
                Text("备份过程不把这些原件转码为 JPEG。整组资源通过 SHA-256 校验后会显示“原件已安全上传”；服务器生成必要预览后，才会成为“完整可浏览备份”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !queueJobs.isEmpty {
                Section {
                    ForEach(visibleQueueJobs) { job in
                        BackupJobRow(job: job)
                    }
                    if queueJobs.count > visibleQueueJobs.count {
                        Text("为保持大图库滚动流畅，这里只显示最近 \(visibleQueueJobs.count) 项；完成统计仍包含全部任务。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("最近任务")
                }
            }
        }
        .navigationTitle("照片备份")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: accountStore.current.accountID) {
            coordinator.resumeInterruptedBackupIfNeeded(
                assets: assets,
                account: accountStore.current,
                client: client
            )
        }
    }

    @ViewBuilder
    private var startButton: some View {
        let button = Button {
            coordinator.startManualBackup(
                assets: assets,
                account: accountStore.current,
                client: client
            )
        } label: {
            HStack {
                Spacer(minLength: 0)
                Label(startButtonTitle, systemImage: "arrow.up.circle.fill")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disabled(coordinator.isRunning || pendingCount == 0)

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var startButtonTitle: String {
        if coordinator.isRunning(for: accountStore.current.accountID) {
            return "正在处理备份队列…"
        }
        if coordinator.isRunning {
            return "等待当前备份完成…"
        }
        if pendingCount == 0 {
            return assets.isEmpty ? "没有可备份的项目" : "全部 \(assets.count) 项均已备份"
        }
        return "立即备份 \(pendingCount) 项"
    }

    @ViewBuilder
    private var retryFailedButton: some View {
        let button = Button {
            coordinator.retryFailed(
                assets: assets,
                account: accountStore.current,
                client: client
            )
        } label: {
            HStack {
                Spacer(minLength: 0)
                Label("仅重试 \(retryableFailedCount) 个失败项目", systemImage: "arrow.clockwise")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disabled(retryableFailedCount == 0)

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var automationPauseButton: some View {
        let button = Button(role: .destructive) {
            coordinator.setAutomaticBackupEnabled(false, for: accountStore.current)
        } label: {
            Label("暂停自动备份", systemImage: "pause.circle")
        }

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

private struct BackupSummaryCard: View {
    let headline: String
    let progress: PhotoBackupProgressSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: progress.isRunning ? "arrow.up.circle.fill" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: progress.isRunning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.headline)
                    Text(
                        progress.totalCount == 0
                            ? "队列为空"
                            : "\(progress.countText) 项原件已安全上传"
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(progress.percentage)%")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }
            if progress.totalCount > 0 {
                ProgressView(value: progress.fractionCompleted)
                if progress.failedCount > 0 {
                    Label(
                        "\(progress.failedCount) 项失败，其他已完成项目保持不变",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                }
                Text(sizeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var sizeSummary: String {
        let uploaded = ByteCountFormatter.string(
            fromByteCount: progress.uploadedBytes,
            countStyle: .file
        )
        guard progress.totalBytes > 0 else {
            return "备份总大小正在读取原始资源后计算"
        }
        let total = ByteCountFormatter.string(
            fromByteCount: progress.totalBytes,
            countStyle: .file
        )
        if progress.hasProvisionalBytes {
            let provisional = ByteCountFormatter.string(
                fromByteCount: progress.provisionalBytes,
                countStyle: .file
            )
            return "iOS 已发送 \(uploaded) / 总计 \(total)；其中 \(provisional) 等待 MyNAS 确认"
        }
        if progress.hasCompleteSize {
            return "已上传 \(uploaded) / 总计 \(total)"
        }
        return "已上传 \(uploaded) · 已统计 \(total)，还有 \(progress.sizePendingCount) 项待计算"
    }
}

private struct BackupJobRow: View {
    let job: PhotoBackupJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.status.systemImage)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.mediaKind.displayName)
                        .font(.headline)
                    Spacer()
                    Text(job.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                if job.status == .uploading || job.status == .preparing || job.status == .waiting {
                    ProgressView(value: job.progress)
                }
                HStack {
                    if job.totalBytes > 0 {
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: job.uploadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file))"
                        )
                    }
                    if job.resourceCount > 0 {
                        Text("· \(job.resourceCount) 个资源")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let message = job.message {
                    if job.status != .failed || job.failure == nil {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(job.status == .failed ? Color.red : Color.secondary)
                    }
                }
                if let failure = job.failure {
                    Label(failure.kind.title, systemImage: failure.kind.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(failure.detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(failure.kind.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if failure.kind.isLikelyTransient {
                        Text("这类错误通常可以从断点继续。")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                if job.status == .completed && !job.isBrowseReady {
                    Label("尚未成为完整可浏览备份", systemImage: "photo.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .uploading: .accentColor
        case .waiting, .waitingForICloud, .preparing: .secondary
        }
    }
}
