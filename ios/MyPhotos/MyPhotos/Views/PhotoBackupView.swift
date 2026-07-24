import SwiftUI

struct PhotoBackupView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @ObservedObject var coordinator: PhotoBackupCoordinator
    let assets: [LocalPhotoAsset]
    let client: PhotoLibraryClient

    private var accountJobs: [PhotoBackupJob] {
        coordinator.jobs(for: accountStore.current.accountID)
    }

    private var failedCount: Int {
        accountJobs.filter { $0.status == .failed }.count
    }

    private var backupProgress: PhotoBackupProgressSnapshot {
        coordinator.progress(
            for: accountStore.current.accountID,
            fallbackTotalCount: assets.count
        )
    }

    var body: some View {
        List {
            Section {
                BackupSummaryCard(
                    headline: coordinator.headline,
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
                        Button {
                            coordinator.retryFailed(
                                assets: assets,
                                account: accountStore.current,
                                client: client
                            )
                        } label: {
                            Label("重试 \(failedCount) 个失败项目", systemImage: "arrow.clockwise")
                        }
                        .disabled(coordinator.isRunning)
                    }
                }
                Text("第一版只在你点击后开始。网络中断时，MyNAS 会保留已完成分片；App 会从服务器记录的字节位置继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("原始格式") {
                Label("Live Photo：静态原图与配对视频整组提交", systemImage: "livephoto")
                Label("HDR：保留原始 HEIC/HEVC 与动态范围元数据", systemImage: "sun.max")
                Label("RAW / ProRAW：保留 DNG、辅助照片与调整数据", systemImage: "camera.aperture")
                Text("备份过程不把这些原件转码为 JPEG。整组资源通过 SHA-256 校验后会显示“原件已安全上传”；阶段 E 生成必要预览后，才会成为“完整可浏览备份”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !accountJobs.isEmpty {
                Section("备份队列") {
                    ForEach(accountJobs) { job in
                        BackupJobRow(job: job)
                    }
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
            Label(
                coordinator.isRunning ? "正在备份…" : "立即备份 \(assets.count) 项",
                systemImage: "arrow.up.circle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .disabled(coordinator.isRunning || assets.isEmpty)

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
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
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(job.status == .failed ? Color.red : Color.secondary)
                }
                if job.status == .completed && !job.isBrowseReady {
                    Label("尚未成为完整可浏览备份", systemImage: "photo.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .uploading: .accentColor
        case .waiting, .preparing: .secondary
        }
    }
}
