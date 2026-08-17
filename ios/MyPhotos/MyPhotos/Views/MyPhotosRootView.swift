import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case photos
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "照片"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct MyPhotosRootView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LocalPhotoLibraryViewModel()
    @StateObject private var backupCoordinator = PhotoBackupCoordinator()
    @StateObject private var textIndex = PhotoTextIndexViewModel()
    @StateObject private var semanticIndex = LocalSemanticModelViewModel()
    @State private var section: MainSection = .photos
    @State private var isSearchPresented = false

    var body: some View {
        nativeTabs
        .sheet(isPresented: $isSearchPresented) {
            LocalSearchView(
                photoClient: library.imageClient,
                backupCoordinator: backupCoordinator,
                textIndex: textIndex
            )
                .environmentObject(accountStore)
        }
        .task {
            await library.start()
            backupCoordinator.setAppIsForeground(scenePhase == .active)
            synchronizeBackupState(
                assets: library.assets,
                account: accountStore.current
            )
            requestAutomaticOCRSynchronization(for: accountStore.current)
            requestAutomaticSemanticSynchronization(for: accountStore.current)
        }
        .onChange(of: library.assets) { _, assets in
            synchronizeBackupState(
                assets: assets,
                account: accountStore.current,
                metadataOnlyChangedAssetIdentifiers: library.consumeMetadataOnlyChangedAssetIdentifiers()
            )
        }
        // A pull-to-refresh must request OCR even when the PhotoKit snapshot
        // contains the same assets as before. `refreshGeneration` advances
        // only after the library refresh has reached its completion boundary,
        // avoiding the transient empty page emitted while pagination resets.
        .onChange(of: library.refreshGeneration) { _, _ in
            requestAutomaticOCRSynchronization(for: accountStore.current)
            requestAutomaticSemanticSynchronization(for: accountStore.current)
        }
        .onChange(of: accountStore.current) { _, account in
            synchronizeBackupState(
                assets: library.assets,
                account: account
            )
            requestAutomaticOCRSynchronization(for: account)
            requestAutomaticSemanticSynchronization(for: account)
        }
        .onChange(of: scenePhase) { _, phase in
            let isForeground = phase == .active
            backupCoordinator.setAppIsForeground(isForeground)
            guard isForeground else { return }
            synchronizeBackupState(
                assets: library.assets,
                account: accountStore.current
            )
            requestAutomaticOCRSynchronization(for: accountStore.current)
            requestAutomaticSemanticSynchronization(for: accountStore.current)
        }
    }

    @ViewBuilder
    private var nativeTabs: some View {
        if #available(iOS 26.0, *) {
            tabView
                .tabBarMinimizeBehavior(.never)
        } else {
            tabView
        }
    }

    private var tabView: some View {
        TabView(selection: $section) {
            Tab(
                MainSection.photos.title,
                systemImage: MainSection.photos.symbol,
                value: MainSection.photos
            ) {
                PhotoTimelineView(
                    viewModel: library,
                    backupCoordinator: backupCoordinator,
                    showSearch: { isSearchPresented = true }
                )
            }

            Tab(
                MainSection.settings.title,
                systemImage: MainSection.settings.symbol,
                value: MainSection.settings
            ) {
                SettingsView(
                    authorization: library.authorization,
                    onManageLimited: library.showLimitedPicker,
                    assets: library.assets,
                    photoClient: library.imageClient,
                    backupCoordinator: backupCoordinator,
                    textIndex: textIndex,
                    semanticIndex: semanticIndex
                )
            }
        }
    }

    private func synchronizeBackupState(
        assets: [LocalPhotoAsset],
        account: AccountContext,
        metadataOnlyChangedAssetIdentifiers: Set<String>? = nil
    ) {
        if let metadataOnlyChangedAssetIdentifiers {
            backupCoordinator.reconcileMetadataOnlyLibraryChanges(
                assetIdentifiers: metadataOnlyChangedAssetIdentifiers,
                assets: assets,
                accountID: account.accountID,
                client: library.imageClient
            )
        }
        backupCoordinator.synchronizeLibrary(assets: assets, account: account)
        backupCoordinator.discoverAndAutomaticallyBackUp(
            assets: assets,
            account: account,
            client: library.imageClient
        )
    }

    private func requestAutomaticOCRSynchronization(for account: AccountContext) {
        guard scenePhase == .active else { return }
        textIndex.requestAutomaticSynchronization(
            account: account,
            photoClient: library.imageClient
        )
    }

    private func requestAutomaticSemanticSynchronization(for account: AccountContext) {
        guard scenePhase == .active else { return }
        semanticIndex.requestAutomaticSynchronization(
            account: account,
            library: library.imageClient
        )
    }
}

/// Privacy controls for Phase I's explicitly consented on-device analysis.
/// This is intentionally reached from Settings. I3 text search belongs in the
/// Photos home search entry; future person-recognition work is not exposed as an
/// empty top-level destination before it is usable.
struct LocalAnalysisSettingsView: View {
    @EnvironmentObject private var accountStore: AccountStore
    let photoClient: PhotoLibraryClient
    @StateObject private var queue = PhotoAnalysisQueueViewModel()
    @ObservedObject var semanticIndex: LocalSemanticModelViewModel
    @ObservedObject var textIndex: PhotoTextIndexViewModel
    @State private var showsEnableTextIndexConfirmation = false
    @State private var showsClearTextIndexConfirmation = false
    @State private var showsDisableTextIndexConfirmation = false
    @State private var showsEnableSemanticIndexConfirmation = false
    @State private var showsClearSemanticIndexConfirmation = false
    @State private var showsDisableSemanticIndexConfirmation = false

    var body: some View {
        settingsList
        .navigationTitle("本地分析与搜索")
        .task(id: accountIdentity) {
            await queue.load(account: accountStore.current)
            await textIndex.load(account: accountStore.current)
            await semanticIndex.load(account: accountStore.current)
        }
        .confirmationDialog(
            "开启照片文字搜索？",
            isPresented: $showsEnableTextIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("开启") {
                Task { await enableAndIndexText() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("iPhone 会读取可访问的静态照片，包括 iCloud 照片。识别结果不会上传。")
        }
        .confirmationDialog(
            "关闭照片文字搜索？",
            isPresented: $showsDisableTextIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("关闭并删除", role: .destructive) {
                Task { await disableTextSearch() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前账号识别出的文字。照片不会删除。")
        }
        .confirmationDialog(
            "清除照片文字？",
            isPresented: $showsClearTextIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                Task { await textIndex.clear(account: accountStore.current) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文字搜索保持开启，下次更新会重新识别。")
        }
        .confirmationDialog(
            "开启画面内容搜索？",
            isPresented: $showsEnableSemanticIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("开启") {
                Task { await enableSemanticIndex() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只分析已在此 iPhone 上的静态照片。照片和结果不会上传。")
        }
        .confirmationDialog(
            "关闭画面内容搜索？",
            isPresented: $showsDisableSemanticIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("关闭并删除", role: .destructive) {
                Task { await disableSemanticSearch() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前账号的画面搜索数据。本地模型会保留。")
        }
        .confirmationDialog(
            "清除画面内容？",
            isPresented: $showsClearSemanticIndexConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                Task { await semanticIndex.clearSemanticIndex(account: accountStore.current) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("画面内容搜索保持开启，下次更新会重新分析。")
        }
        .alert(
            "本地分析数据不可用",
            isPresented: queueErrorIsPresented
        ) {
            Button("删除损坏数据", role: .destructive) {
                Task { await queue.resetCorruptedQueue(account: accountStore.current) }
            }
            Button("取消", role: .cancel) { queue.errorMessage = nil }
        } message: {
            Text(queue.errorMessage ?? "")
        }
        .alert(
            "照片文字不可用",
            isPresented: textIndexErrorIsPresented
        ) {
            Button("删除损坏的文字数据", role: .destructive) {
                Task { await textIndex.resetCorruptedIndex(account: accountStore.current) }
            }
            Button("取消", role: .cancel) { textIndex.errorMessage = nil }
        } message: {
            Text(textIndex.errorMessage ?? "")
        }
        .alert(
            "画面内容搜索不可用",
            isPresented: semanticIndexErrorIsPresented
        ) {
            Button("好", role: .cancel) { semanticIndex.errorMessage = nil }
        } message: {
            Text(semanticIndex.errorMessage ?? "")
        }
    }

    private var settingsList: some View {
        List {
            semanticModelSection
            searchFeatureSection
            enabledSearchSections
            clearDataSection
        }
    }

    private var semanticModelSection: some View {
        Section {
            NavigationLink {
                LocalSemanticModelSettingsView(model: semanticIndex)
            } label: {
                HStack {
                    Label("本地语义模型", systemImage: "cpu")
                    Spacer()
                    Text(semanticModelStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchFeatureSection: some View {
        Section {
            Toggle(isOn: textRecognitionBinding) {
                Label("搜索照片中的文字", systemImage: "text.viewfinder")
            }
            .disabled(isAnyAnalysisWorking)

            Toggle(isOn: semanticSearchBinding) {
                Label("按画面内容搜索", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(isSemanticSearchToggleDisabled)
        } header: {
            Text("搜索功能")
        } footer: {
            if let semanticSearchAvailabilityText {
                Text(semanticSearchAvailabilityText)
            }
        }
    }

    @ViewBuilder
    private var enabledSearchSections: some View {
        if hasEnabledSearchFeature {
            Section("已建立的搜索内容") {
                if textIndex.status.isEnabled {
                    LabeledContent("照片文字", value: textIndexStatusText)
                }

                if semanticIndex.semanticStatus.isEnabled {
                    LabeledContent("画面内容", value: semanticIndexStatusText)
                }

                if isAnyAnalysisWorking {
                    HStack(spacing: 9) {
                        ProgressView()
                        Text(workingStatusText)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("更新") {
                if textIndex.status.isEnabled {
                    Button {
                        Task { await indexText() }
                    } label: {
                        Label("更新照片文字", systemImage: "arrow.clockwise")
                    }
                    .disabled(isAnyAnalysisWorking)
                }

                if semanticIndex.semanticStatus.isEnabled {
                    Button {
                        Task { await synchronizeSemanticIndex() }
                    } label: {
                        Label("更新画面内容", systemImage: "arrow.clockwise")
                    }
                    .disabled(isAnyAnalysisWorking || !semanticIndex.canEnableSemanticIndex)
                }
            }
        }
    }

    @ViewBuilder
    private var clearDataSection: some View {
        if textIndex.status.indexedAssetCount > 0 || semanticIndex.semanticStatus.indexedAssetCount > 0 {
            Section("清除数据") {
                if textIndex.status.indexedAssetCount > 0 {
                    Button(role: .destructive) {
                        showsClearTextIndexConfirmation = true
                    } label: {
                        Label("清除照片文字", systemImage: "trash")
                    }
                    .disabled(isAnyAnalysisWorking)
                }

                if semanticIndex.semanticStatus.indexedAssetCount > 0 {
                    Button(role: .destructive) {
                        showsClearSemanticIndexConfirmation = true
                    } label: {
                        Label("清除画面内容", systemImage: "trash")
                    }
                    .disabled(isAnyAnalysisWorking)
                }
            }
        }
    }

    private var accountIdentity: String {
        "\(accountStore.current.accountID)|\(accountStore.current.serverID)|\(accountStore.current.userID)"
    }

    private var queueErrorIsPresented: Binding<Bool> {
        Binding(
            get: { queue.errorMessage != nil },
            set: { if !$0 { queue.errorMessage = nil } }
        )
    }

    private var textIndexErrorIsPresented: Binding<Bool> {
        Binding(
            get: { textIndex.errorMessage != nil },
            set: { if !$0 { textIndex.errorMessage = nil } }
        )
    }

    private var semanticIndexErrorIsPresented: Binding<Bool> {
        Binding(
            get: { semanticIndex.errorMessage != nil },
            set: { if !$0 { semanticIndex.errorMessage = nil } }
        )
    }

    private var textRecognitionBinding: Binding<Bool> {
        Binding(
            get: { textIndex.status.isEnabled },
            set: { isEnabled in
                if isEnabled {
                    showsEnableTextIndexConfirmation = true
                } else {
                    showsDisableTextIndexConfirmation = true
                }
            }
        )
    }

    private var semanticSearchBinding: Binding<Bool> {
        Binding(
            get: { semanticIndex.semanticStatus.isEnabled },
            set: { isEnabled in
                if isEnabled {
                    guard semanticIndex.canEnableSemanticIndex else { return }
                    showsEnableSemanticIndexConfirmation = true
                } else {
                    showsDisableSemanticIndexConfirmation = true
                }
            }
        )
    }

    private var isAnyAnalysisWorking: Bool {
        queue.isWorking || textIndex.isWorking || semanticIndex.isWorking
    }

    private var hasEnabledSearchFeature: Bool {
        textIndex.status.isEnabled || semanticIndex.semanticStatus.isEnabled
    }

    private var isSemanticSearchToggleDisabled: Bool {
        if semanticIndex.semanticStatus.isEnabled { return isAnyAnalysisWorking }
        return !semanticIndex.canEnableSemanticIndex || isAnyAnalysisWorking
    }

    private var semanticModelStatusText: String {
        if semanticIndex.isWorking { return "处理中" }
        return semanticIndex.installationStatus.isInstalled ? "已安装" : "未安装"
    }

    private var textIndexStatusText: String {
        if textIndex.status.requiresICloudDownloadConsent { return "需重新开启" }
        return textIndex.status.isEnabled
            ? "\(textIndex.status.indexedAssetCount) 张"
            : "已关闭"
    }

    private var semanticIndexStatusText: String {
        semanticIndex.semanticStatus.isEnabled
            ? "\(semanticIndex.semanticStatus.indexedAssetCount) 张"
            : "已关闭"
    }

    private var workingStatusText: String {
        if textIndex.isWorking { return "正在识别照片文字…" }
        if semanticIndex.isWorking { return "正在分析画面内容…" }
        return "正在读取照片…"
    }

    private var semanticSearchAvailabilityText: String? {
        if !semanticIndex.installationStatus.isInstalled {
            return "安装本地语义模型后可开启画面内容搜索。"
        }
        if !semanticIndex.isRuntimeAvailable {
            return "此设备不支持画面内容搜索。"
        }
        return nil
    }

    private func enableAndIndexText() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        guard await enableAnalysisIfNeeded(assets: assets, account: account) else { return }
        await textIndex.enableAndSynchronize(
            assets: assets,
            account: account,
            photoClient: photoClient
        )
    }

    private func indexText() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        await textIndex.synchronize(
            assets: assets,
            account: account,
            photoClient: photoClient
        )
    }

    private func enableSemanticIndex() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        guard await enableAnalysisIfNeeded(assets: assets, account: account) else { return }
        await semanticIndex.enableAndSynchronizeSemanticIndex(
            assets: assets,
            account: account,
            imageSource: photoClient
        )
    }

    private func enableAnalysisIfNeeded(
        assets: [LocalPhotoAsset],
        account: AccountContext
    ) async -> Bool {
        if queue.status.isPixelAnalysisAllowed { return true }
        await queue.enableAndPrepare(assets: assets, account: account)
        return queue.status.isPixelAnalysisAllowed && queue.errorMessage == nil
    }

    private func disableTextSearch() async {
        let account = accountStore.current
        await textIndex.disableAndDelete(account: account)
        if !textIndex.status.isEnabled && !semanticIndex.semanticStatus.isEnabled {
            await queue.disableAndDelete(account: account)
        }
    }

    private func disableSemanticSearch() async {
        let account = accountStore.current
        await semanticIndex.disableAndDeleteSemanticIndex(account: account)
        if !semanticIndex.semanticStatus.isEnabled && !textIndex.status.isEnabled {
            await queue.disableAndDelete(account: account)
        }
    }

    private func synchronizeSemanticIndex() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        await semanticIndex.synchronizeSemanticIndex(
            assets: assets,
            account: account,
            imageSource: photoClient
        )
    }
}

private struct LocalSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accountStore: AccountStore
    @FocusState private var searchIsFocused: Bool
    let photoClient: PhotoLibraryClient
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    @StateObject private var index = PhotoSearchIndexViewModel()
    @StateObject private var semanticSearch = LocalSemanticSearchViewModel()
    @ObservedObject var textIndex: PhotoTextIndexViewModel
    @State private var query = ""
    @State private var showsClearConfirmation = false
    @State private var showsDisableConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if !hasQuery {
                    Section(index.status.isEnabled ? "本地元数据索引" : "阶段 I · 本地元数据索引") {
                        if index.status.isEnabled {
                            LabeledContent("账号", value: accountStore.current.displayName)
                            LabeledContent("已索引项目", value: "\(index.status.indexedAssetCount)")
                            LabeledContent("最近更新", value: lastUpdatedText)

                            if index.isWorking {
                                HStack(spacing: 9) {
                                    ProgressView()
                                    Text("正在读取本地图库元数据…")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    Task { await indexCurrentLibrary() }
                                } label: {
                                    Label("更新本地索引", systemImage: "arrow.clockwise")
                                }
                            }

                            Button(role: .destructive) {
                                showsClearConfirmation = true
                            } label: {
                                Label("清空当前账号索引", systemImage: "trash")
                            }
                            .disabled(index.isWorking || index.status.indexedAssetCount == 0)

                            Button(role: .destructive) {
                                showsDisableConfirmation = true
                            } label: {
                                Label("关闭并删除本地索引", systemImage: "hand.raised")
                            }
                            .disabled(index.isWorking)
                        } else {
                            Label("默认关闭", systemImage: "hand.raised.fill")
                                .foregroundStyle(.secondary)
                            Text("启用与更新索引时只读取当前 Photos 权限范围内的类型、日期、收藏和尺寸。搜索结果只按需显示本地缩略图，缩略图不写入索引、不下载 iCloud 原件，也不上传到 MyNAS 或任何中心化服务。OCR 与语义索引可在“设置 > 本地分析与搜索”中分别开启；三个来源共用本页的一个搜索框。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await enableAndIndexCurrentLibrary() }
                            } label: {
                                Label("启用并建立本地索引", systemImage: "sparkles")
                            }
                            .disabled(index.isWorking)
                        }

                        if let statusMessage = index.statusMessage {
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("OCR 文字索引") {
                        if textIndex.status.isEnabled {
                            LabeledContent("已处理静态图片", value: "\(textIndex.status.indexedAssetCount)")
                            LabeledContent("最近更新", value: lastTextIndexUpdatedText)
                        } else {
                            Label("尚未启用", systemImage: "text.viewfinder")
                                .foregroundStyle(.secondary)
                        }
                        Text("OCR 与元数据使用同一个搜索框。管理位置：设置 > 本地分析与搜索。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("本地语义索引") {
                        if semanticSearch.status.isEnabled {
                            LabeledContent("已建立向量", value: "\(semanticSearch.status.indexedAssetCount)")
                            LabeledContent("最近更新", value: lastSemanticIndexUpdatedText)
                            Text("语义结果使用同一个搜索框。管理位置：设置 > 本地分析与搜索。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("尚未启用", systemImage: "sparkle.magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text("需先安装本地 Qwen 模型，并单独允许当前账号建立本地语义索引；不会使用 Apple Intelligence 或上传照片。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if unifiedResults.isEmpty {
                    if isSearching {
                        ContentUnavailableView {
                            ProgressView()
                        } description: {
                            Text("正在此 iPhone 上搜索照片…")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("没有找到结果", systemImage: "magnifyingglass")
                        } description: {
                            Text("没有与“\(query)”匹配的本地照片或视频。请检查输入或尝试其他搜索。")
                        }
                    }
                } else {
                    if isSearching {
                        Section {
                            HStack(spacing: 9) {
                                ProgressView()
                                Text("正在补充本地语义结果…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 8),
                                count: 3
                            ),
                            spacing: 8
                        ) {
                            ForEach(unifiedResults) { result in
                                NavigationLink {
                                    searchResultDestination(for: result)
                                } label: {
                                    searchResultTile(for: result)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "搜索照片、文字、内容、日期或收藏")
            .searchFocused($searchIsFocused)
            .onChange(of: query) { _, newValue in
                Task { await index.updateQuery(newValue, account: accountStore.current) }
                Task { await textIndex.updateQuery(newValue, account: accountStore.current) }
                semanticSearch.updateQuery(newValue, account: accountStore.current)
            }
            .task(id: accountIdentity) {
                query = ""
                await index.load(account: accountStore.current)
                await textIndex.load(account: accountStore.current)
                await semanticSearch.load(account: accountStore.current)
                if index.status.isEnabled {
                    await indexCurrentLibrary()
                }
                searchIsFocused = index.status.isEnabled
                    || textIndex.status.isEnabled
                    || semanticSearch.status.isEnabled
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "清空当前账号索引？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空索引", role: .destructive) {
                    Task { await index.clear(account: accountStore.current) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除当前账号的本地搜索记录，不会删除系统照片或 MyNAS 原件；本地索引仍保持启用。")
            }
            .confirmationDialog(
                "关闭本地索引？",
                isPresented: $showsDisableConfirmation,
                titleVisibility: .visible
            ) {
                Button("关闭并删除", role: .destructive) {
                    Task { await index.disableAndDelete(account: accountStore.current) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除当前账号的全部本地搜索记录。系统照片与 MyNAS 原件不会受到影响。")
            }
            .alert(
                "本地索引不可用",
                isPresented: Binding(
                    get: { index.errorMessage != nil },
                    set: { if !$0 { index.errorMessage = nil } }
                )
            ) {
                Button("移除不可读索引", role: .destructive) {
                    Task { await index.resetCorruptedIndex(account: accountStore.current) }
                }
                Button("取消", role: .cancel) { index.errorMessage = nil }
            } message: {
                Text(index.errorMessage ?? "")
            }
            .alert(
                "本地语义搜索不可用",
                isPresented: Binding(
                    get: { semanticSearch.errorMessage != nil },
                    set: { if !$0 { semanticSearch.clearError() } }
                )
            ) {
                Button("好", role: .cancel) { semanticSearch.clearError() }
            } message: {
                Text(semanticSearch.errorMessage ?? "")
            }
        }
    }

    private var accountIdentity: String {
        "\(accountStore.current.accountID)|\(accountStore.current.serverID)|\(accountStore.current.userID)"
    }

    private var lastUpdatedText: String {
        index.status.lastSynchronizedAt.map { Self.timestampFormatter.string(from: $0) } ?? "尚未建立"
    }

    private var lastTextIndexUpdatedText: String {
        textIndex.status.lastSynchronizedAt.map { Self.timestampFormatter.string(from: $0) } ?? "尚未建立"
    }

    private var lastSemanticIndexUpdatedText: String {
        semanticSearch.status.lastSynchronizedAt.map { Self.timestampFormatter.string(from: $0) } ?? "尚未建立"
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unifiedResults: [LocalUnifiedSearchResult] {
        LocalUnifiedSearchResultMerger.merge(
            metadata: index.results,
            recognizedText: textIndex.results,
            semantic: semanticSearch.results
        )
    }

    private var isSearching: Bool {
        index.isWorking || textIndex.isWorking || semanticSearch.isWorking
    }

    private func enableAndIndexCurrentLibrary() async {
        guard await index.enable(account: accountStore.current) else { return }
        await indexCurrentLibrary()
        searchIsFocused = true
    }

    private func indexCurrentLibrary() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        await index.synchronize(assets: assets, account: account)
    }

    @ViewBuilder
    private func searchResultDestination(for result: LocalUnifiedSearchResult) -> some View {
        if let asset = photoClient.accessibleAsset(localIdentifier: result.assetID) {
            PhotoDetailView(
                asset: asset,
                isBackedUp: backupCoordinator.hasCurrentVerifiedBackup(
                    for: asset,
                    accountID: accountStore.current.accountID
                ),
                client: photoClient
            )
        } else {
            ContentUnavailableView(
                "照片已不可访问",
                systemImage: "photo.badge.exclamationmark",
                description: Text("它可能已被删除或不再属于当前 Photos 权限范围；更新索引后会从结果中移除。")
            )
        }
    }

    private func searchResultTile(for result: LocalUnifiedSearchResult) -> some View {
        GeometryReader { proxy in
            PhotoThumbnailView(
                localIdentifier: result.assetID,
                mediaKind: result.mediaKind,
                targetSize: CGSize(width: 360, height: 360),
                client: photoClient
            )
            .frame(width: proxy.size.width, height: proxy.size.width)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("搜索结果照片，点按查看详情")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
