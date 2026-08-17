import SwiftUI
import UniformTypeIdentifiers

/// Installs or removes the optional on-device Qwen model package. Search and
/// indexing controls live on the parent settings screen.
struct LocalSemanticModelSettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @ObservedObject var model: LocalSemanticModelViewModel
    @State private var showsImportConfirmation = false
    @State private var showsDownloadConfirmation = false
    @State private var showsUninstallConfirmation = false
    @State private var showsPackageImporter = false

    var body: some View {
        List {
            Section("模型") {
                LabeledContent("状态", value: installationStatusText)
                LabeledContent("名称", value: model.manifest.profile.modelIdentifier)
                LabeledContent("大小", value: byteCountText(model.manifest.totalByteCount))

                if model.installationStatus.isInstalled {
                    LabeledContent("安装时间", value: installedAtText)

                    Button(role: .destructive) {
                        showsUninstallConfirmation = true
                    } label: {
                        Label("删除模型", systemImage: "trash")
                    }
                    .disabled(model.isWorking)
                } else {
                    LabeledContent("从 MyNAS 下载需要空间", value: byteCountText(model.minimumDownloadAvailableByteCount))
                    LabeledContent("可用空间", value: availableCapacityText)

                    Button {
                        showsDownloadConfirmation = true
                    } label: {
                        Label("从 MyNAS 下载模型", systemImage: "arrow.down.circle")
                    }
                    .disabled(accountStore.current.serverURL == nil || !model.canDownloadFromMyNAS)

                    Button {
                        showsImportConfirmation = true
                    } label: {
                        Label("从“文件”安装模型", systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canImportPackage)
                }

                if model.isWorking {
                    HStack(spacing: 9) {
                        ProgressView()
                        Text(model.operationStatusText ?? "正在处理模型…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(model.operationStatusText ?? "正在处理模型")
                } else if !model.isRuntimeAvailable {
                    Label("当前设备不支持语义模型", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("数据") {
                LabeledContent("运行位置", value: "此 iPhone")
                LabeledContent("模型文件", value: "所有账号共用")
                LabeledContent("语义索引", value: "按账号分开")
                LabeledContent("上传到 MyNAS", value: "不会")
            }
        }
        .navigationTitle("本地语义模型")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: accountIdentity) {
            await model.load(account: accountStore.current)
        }
        .confirmationDialog(
            "从 MyNAS 下载本地语义模型？",
            isPresented: $showsDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("下载") {
                Task { await model.downloadPinnedPackageFromMyNAS(account: accountStore.current) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("模型约 \(byteCountText(model.manifest.totalByteCount))。仅从当前已配对的 MyNAS 私有地址下载，并在安装前校验全部文件。")
        }
        .confirmationDialog(
            "导入本地语义模型？",
            isPresented: $showsImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("选择模型文件夹") {
                showsPackageImporter = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将复制并校验约 \(byteCountText(model.manifest.totalByteCount)) 的模型文件。安装过程不会读取照片。")
        }
        .fileImporter(
            isPresented: $showsPackageImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let directoryURL = urls.first else { return }
                Task {
                    await model.importPinnedPackage(
                        from: directoryURL,
                        account: accountStore.current
                    )
                }
            case let .failure(error):
                model.reportImportError(error)
            }
        }
        .confirmationDialog(
            "删除本地语义模型？",
            isPresented: $showsUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除模型", role: .destructive) {
                Task { await model.uninstallModel(account: accountStore.current) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除约 \(byteCountText(model.installationStatus.byteCount)) 的模型文件。语义索引仍会保留，但重新安装模型前无法使用。")
        }
        .alert(
            "无法使用本地语义模型",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var accountIdentity: String {
        "\(accountStore.current.accountID)|\(accountStore.current.serverID)|\(accountStore.current.userID)"
    }

    private var availableCapacityText: String {
        guard let availableCapacity = model.availableCapacity else { return "无法读取" }
        return byteCountText(availableCapacity)
    }

    private var installationStatusText: String {
        if model.isWorking { return "处理中" }
        return model.installationStatus.isInstalled ? "已安装" : "未安装"
    }

    private var installedAtText: String {
        guard let installedAt = model.installationStatus.installedAt else { return "—" }
        return Self.timestampFormatter.string(from: installedAt)
    }

    private func byteCountText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
