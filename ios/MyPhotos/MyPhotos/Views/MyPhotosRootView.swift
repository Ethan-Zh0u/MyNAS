import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case photos
    case people
    case albums
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "照片"
        case .people: "人物"
        case .albums: "相册"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .people: "person.2"
        case .albums: "rectangle.stack"
        case .settings: "gearshape"
        }
    }
}

struct MyPhotosRootView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LocalPhotoLibraryViewModel()
    @StateObject private var backupCoordinator = PhotoBackupCoordinator()
    @State private var section: MainSection = .photos
    @State private var isSearchPresented = false

    var body: some View {
        nativeTabs
        .sheet(isPresented: $isSearchPresented) {
            LocalSearchView(
                photoClient: library.imageClient,
                backupCoordinator: backupCoordinator
            )
                .environmentObject(accountStore)
        }
        .task {
            await library.start()
            backupCoordinator.setAppIsForeground(scenePhase == .active)
            backupCoordinator.synchronizeLibrary(
                assets: library.assets,
                account: accountStore.current
            )
            backupCoordinator.discoverAndAutomaticallyBackUp(
                assets: library.assets,
                account: accountStore.current,
                client: library.imageClient
            )
        }
        .onChange(of: library.assets) { _, assets in
            backupCoordinator.reconcileMetadataOnlyLibraryChanges(
                assetIdentifiers: library.consumeMetadataOnlyChangedAssetIdentifiers(),
                assets: assets,
                accountID: accountStore.current.accountID,
                client: library.imageClient
            )
            backupCoordinator.synchronizeLibrary(
                assets: assets,
                account: accountStore.current
            )
            backupCoordinator.discoverAndAutomaticallyBackUp(
                assets: assets,
                account: accountStore.current,
                client: library.imageClient
            )
        }
        .onChange(of: accountStore.current) { _, account in
            backupCoordinator.synchronizeLibrary(
                assets: library.assets,
                account: account
            )
            backupCoordinator.discoverAndAutomaticallyBackUp(
                assets: library.assets,
                account: account,
                client: library.imageClient
            )
        }
        .onChange(of: scenePhase) { _, phase in
            let isForeground = phase == .active
            backupCoordinator.setAppIsForeground(isForeground)
            guard isForeground else { return }
            backupCoordinator.synchronizeLibrary(
                assets: library.assets,
                account: accountStore.current
            )
            backupCoordinator.discoverAndAutomaticallyBackUp(
                assets: library.assets,
                account: accountStore.current,
                client: library.imageClient
            )
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
                MainSection.people.title,
                systemImage: MainSection.people.symbol,
                value: MainSection.people
            ) {
                LocalAnalysisQueueView(
                    photoClient: library.imageClient,
                    backupCoordinator: backupCoordinator
                )
            }

            Tab(
                MainSection.albums.title,
                systemImage: MainSection.albums.symbol,
                value: MainSection.albums
            ) {
                PhasePlaceholderView(
                    title: "相册",
                    symbol: MainSection.albums.symbol,
                    message: "相册同步和跨设备相册将在 MyNAS 连接后提供。"
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
                    backupCoordinator: backupCoordinator
                )
            }
        }
    }
}

/// The People tab hosts Phase I's explicitly consented local analysis stages.
/// I3 only adds Vision text recognition; it is not person recognition,
/// object classification, embedding generation or a MyNAS service request.
private struct LocalAnalysisQueueView: View {
    @EnvironmentObject private var accountStore: AccountStore
    let photoClient: PhotoLibraryClient
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    @StateObject private var queue = PhotoAnalysisQueueViewModel()
    @StateObject private var textIndex = PhotoTextIndexViewModel()
    @State private var showsDisableConfirmation = false
    @State private var showsClearTextIndexConfirmation = false
    @State private var showsDisableTextIndexConfirmation = false
    @State private var textQuery = ""

    var body: some View {
        NavigationStack {
            List {
                if !queue.status.isPixelAnalysisAllowed {
                    Section("阶段 I · I2 端侧分析许可") {
                        Label("默认关闭", systemImage: "hand.raised.fill")
                            .foregroundStyle(.secondary)
                        Text("I2 只会读取当前 Photos 权限范围内的元数据，以建立待分析项目清单；不会读取照片或视频像素、不会下载 iCloud 原件、不会调用 Vision/Core ML，也不会上传到 MyNAS 或其他服务。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("明确允许后，许可和队列只属于当前 MyNAS 账号；关闭许可或清理当前账号缓存会删除它们。I3 OCR 仍需单独允许；物体、人物和语义结果仍未交付。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await enableAndPrepareQueue() }
                        } label: {
                            Label("允许端侧像素分析并建立队列", systemImage: "checkmark.shield")
                        }
                        .disabled(queue.isWorking)
                    }
                } else {
                    Section("端侧像素分析许可") {
                        LabeledContent("状态", value: "已允许")
                        LabeledContent("当前账号", value: accountStore.current.displayName)
                        LabeledContent("待分析项目", value: "\(queue.status.pendingAssetCount)")
                        LabeledContent("最近准备", value: lastPreparedText)

                        if queue.isWorking {
                            HStack(spacing: 9) {
                                ProgressView()
                                Text("正在读取本地图库元数据…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                Task { await prepareQueue() }
                            } label: {
                                Label("更新待分析队列", systemImage: "arrow.clockwise")
                            }
                        }

                        if let statusMessage = queue.statusMessage {
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("I2 当前边界") {
                        Label("仅保存标识符和源版本", systemImage: "list.bullet.rectangle")
                        Text("I2 的队列本身不会读取、缓存或上传像素。I3 OCR 有独立许可和可删除文字索引；物体标签、人物聚类、embedding 和语义结果仍未交付。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !textIndex.status.isEnabled {
                        Section("阶段 I · I3 本地 OCR 文字索引") {
                            Label("默认关闭", systemImage: "text.viewfinder")
                                .foregroundStyle(.secondary)
                            Text("这是独立于 I2 的文字保留许可。明确允许后，只对本机可取得的静态图片调用 Apple Vision；不会读取视频、不会下载 iCloud 原件、不会上传到 MyNAS 或其他服务。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("识别出的文字会仅保存在当前 MyNAS 账号的受保护本地索引中，可随时清空或关闭删除。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await enableAndIndexText() }
                            } label: {
                                Label("允许本地 OCR 并建立文字索引", systemImage: "text.badge.checkmark")
                            }
                            .disabled(queue.isWorking || textIndex.isWorking)
                        }
                    } else {
                        Section("I3 本地 OCR 文字索引") {
                            LabeledContent("状态", value: "已允许")
                            LabeledContent("当前账号", value: accountStore.current.displayName)
                            LabeledContent("已处理静态图片", value: "\(textIndex.status.indexedAssetCount)")
                            LabeledContent("最近更新", value: lastTextIndexUpdatedText)

                            if textIndex.isWorking {
                                HStack(spacing: 9) {
                                    ProgressView()
                                    Text("正在本机识别图片文字…")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    Task { await indexText() }
                                } label: {
                                    Label("更新 OCR 文字索引", systemImage: "arrow.clockwise")
                                }
                                .disabled(queue.isWorking)
                            }

                            if let statusMessage = textIndex.statusMessage {
                                Text(statusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("OCR 文字搜索") {
                            TextField("搜索已识别的本地文字", text: $textQuery)
                                .textInputAutocapitalization(.never)
                                .onChange(of: textQuery) { _, query in
                                    Task { await textIndex.updateQuery(query, account: accountStore.current) }
                                }

                            if !textQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                if textIndex.results.isEmpty {
                                    ContentUnavailableView {
                                        Label("没有找到文字结果", systemImage: "text.magnifyingglass")
                                    } description: {
                                        Text("没有与“\(textQuery)”匹配的已识别本地文字。")
                                    }
                                } else {
                                    LazyVGrid(
                                        columns: Array(
                                            repeating: GridItem(.flexible(), spacing: 8),
                                            count: 3
                                        ),
                                        spacing: 8
                                    ) {
                                        ForEach(textIndex.results) { record in
                                            NavigationLink {
                                                textSearchResultDestination(for: record)
                                            } label: {
                                                textSearchResultTile(for: record)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .listRowInsets(
                                        EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
                                    )
                                }
                            }
                        }

                        Section("OCR 索引控制") {
                            Button(role: .destructive) {
                                showsClearTextIndexConfirmation = true
                            } label: {
                                Label("清空 OCR 文字索引", systemImage: "trash")
                            }
                            .disabled(queue.isWorking || textIndex.isWorking || textIndex.status.indexedAssetCount == 0)
                            .confirmationDialog(
                                "清空 OCR 文字索引？",
                                isPresented: $showsClearTextIndexConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("清空索引", role: .destructive) {
                                    Task { await textIndex.clear(account: accountStore.current) }
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("只删除当前账号的本地 OCR 文字记录；端侧像素分析许可、系统照片和 MyNAS 原件不会受到影响。")
                            }

                            Button(role: .destructive) {
                                showsDisableTextIndexConfirmation = true
                            } label: {
                                Label("关闭并删除 OCR 文字索引", systemImage: "text.badge.xmark")
                            }
                            .disabled(queue.isWorking || textIndex.isWorking)
                            .confirmationDialog(
                                "关闭本地 OCR 文字索引？",
                                isPresented: $showsDisableTextIndexConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("关闭并删除", role: .destructive) {
                                    Task { await textIndex.disableAndDelete(account: accountStore.current) }
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("会删除当前账号的全部本地 OCR 文字记录；I2 的端侧像素分析许可、系统照片和 MyNAS 原件不会受到影响。")
                            }
                        }
                    }

                    Section("许可控制") {
                        Button(role: .destructive) {
                            showsDisableConfirmation = true
                        } label: {
                            Label("关闭许可并删除本地队列与 OCR 索引", systemImage: "hand.raised.slash")
                        }
                        .disabled(queue.isWorking)
                        .confirmationDialog(
                            "关闭端侧像素分析？",
                            isPresented: $showsDisableConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("关闭并删除", role: .destructive) {
                                Task {
                                    await queue.disableAndDelete(account: accountStore.current)
                                    await textIndex.load(account: accountStore.current)
                                }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("会撤回当前账号的端侧像素分析许可，并删除待分析队列和 OCR 文字索引。不会删除系统照片、MyNAS 原件或 I1 本地搜索索引。")
                        }
                    }
                }
            }
            .navigationTitle("人物")
            .task(id: accountIdentity) {
                await queue.load(account: accountStore.current)
                await textIndex.load(account: accountStore.current)
            }
            .alert(
                "端侧分析队列不可用",
                isPresented: Binding(
                    get: { queue.errorMessage != nil },
                    set: { if !$0 { queue.errorMessage = nil } }
                )
            ) {
                Button("删除不可读队列", role: .destructive) {
                    Task { await queue.resetCorruptedQueue(account: accountStore.current) }
                }
                Button("取消", role: .cancel) { queue.errorMessage = nil }
            } message: {
                Text(queue.errorMessage ?? "")
            }
            .alert(
                "OCR 文字索引不可用",
                isPresented: Binding(
                    get: { textIndex.errorMessage != nil },
                    set: { if !$0 { textIndex.errorMessage = nil } }
                )
            ) {
                Button("删除不可读 OCR 索引", role: .destructive) {
                    Task { await textIndex.resetCorruptedIndex(account: accountStore.current) }
                }
                Button("取消", role: .cancel) { textIndex.errorMessage = nil }
            } message: {
                Text(textIndex.errorMessage ?? "")
            }
        }
    }

    private var accountIdentity: String {
        "\(accountStore.current.accountID)|\(accountStore.current.serverID)|\(accountStore.current.userID)"
    }

    private var lastPreparedText: String {
        queue.status.lastPreparedAt.map { Self.timestampFormatter.string(from: $0) } ?? "尚未建立"
    }

    private var lastTextIndexUpdatedText: String {
        textIndex.status.lastSynchronizedAt.map { Self.timestampFormatter.string(from: $0) } ?? "尚未建立"
    }

    private func enableAndPrepareQueue() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        await queue.enableAndPrepare(assets: assets, account: account)
    }

    private func prepareQueue() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
        await queue.prepare(assets: assets, account: account)
    }

    private func enableAndIndexText() async {
        let account = accountStore.current
        let assets = await photoClient.allAccessibleAssets()
        guard accountIdentity == "\(account.accountID)|\(account.serverID)|\(account.userID)" else { return }
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

    @ViewBuilder
    private func textSearchResultDestination(for record: PhotoTextIndexRecord) -> some View {
        if let asset = photoClient.accessibleAsset(localIdentifier: record.assetID) {
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
                description: Text("它可能已被删除或不再属于当前 Photos 权限范围；更新 OCR 索引后会从结果中移除。")
            )
        }
    }

    private func textSearchResultTile(for record: PhotoTextIndexRecord) -> some View {
        GeometryReader { proxy in
            PhotoThumbnailView(
                localIdentifier: record.assetID,
                mediaKind: .photo,
                targetSize: CGSize(width: 360, height: 360),
                client: photoClient
            )
            .frame(width: proxy.size.width, height: proxy.size.width)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("OCR 搜索结果照片，点按查看详情")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct PhasePlaceholderView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(message)
            }
            .navigationTitle(title)
        }
    }
}

private struct LocalSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accountStore: AccountStore
    @FocusState private var searchIsFocused: Bool
    let photoClient: PhotoLibraryClient
    @ObservedObject var backupCoordinator: PhotoBackupCoordinator
    @StateObject private var index = PhotoSearchIndexViewModel()
    @State private var query = ""
    @State private var showsClearConfirmation = false
    @State private var showsDisableConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if !index.status.isEnabled {
                    Section("阶段 I · 本地索引") {
                        Label("默认关闭", systemImage: "hand.raised.fill")
                            .foregroundStyle(.secondary)
                        Text("启用与更新索引时只读取当前 Photos 权限范围内的类型、日期、收藏和尺寸。搜索结果只按需显示本地缩略图，缩略图不写入索引、不下载 iCloud 原件，也不上传到 MyNAS 或任何中心化服务。")
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
                        Section { Text(statusMessage).foregroundStyle(.secondary) }
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("当前账号索引") {
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

                        if let statusMessage = index.statusMessage {
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("I1 搜索范围") {
                        Label("媒体类型、日期、收藏与尺寸", systemImage: "text.magnifyingglass")
                        Text("OCR 文字索引在 I3 独立启用；人物、物体与语义模型仍未交付，人物结果不会自动命名。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("索引控制") {
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
                    }
                } else if index.results.isEmpty {
                    ContentUnavailableView {
                        Label("没有找到结果", systemImage: "magnifyingglass")
                    } description: {
                        Text("没有与“\(query)”匹配的本地项目。请检查输入或尝试其他搜索。")
                    }
                } else {
                    Section("本地结果（\(index.results.count)）") {
                        ForEach(index.results) { record in
                            NavigationLink {
                                searchResultDestination(for: record)
                            } label: {
                                HStack(spacing: 12) {
                                    PhotoThumbnailView(
                                        localIdentifier: record.assetID,
                                        mediaKind: record.mediaKind,
                                        targetSize: CGSize(width: 180, height: 180),
                                        client: photoClient
                                    )
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Text(record.displayMediaName)
                                                .font(.headline)
                                            if record.isFavorite {
                                                Image(systemName: "heart.fill")
                                                    .foregroundStyle(.pink)
                                                    .accessibilityLabel("已收藏")
                                            }
                                        }
                                        Text(resultMetadata(for: record))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "照片、视频、日期或收藏")
            .onChange(of: query) { _, newValue in
                Task { await index.updateQuery(newValue, account: accountStore.current) }
            }
            .task(id: accountIdentity) {
                query = ""
                await index.load(account: accountStore.current)
                if index.status.isEnabled {
                    await indexCurrentLibrary()
                }
                searchIsFocused = index.status.isEnabled
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
        }
    }

    private var accountIdentity: String {
        "\(accountStore.current.accountID)|\(accountStore.current.serverID)|\(accountStore.current.userID)"
    }

    private var lastUpdatedText: String {
        index.status.lastSynchronizedAt.map { Self.timestampFormatter.string(from: $0) } ?? "尚未建立"
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

    private func resultMetadata(for record: PhotoSearchIndexRecord) -> String {
        let date = record.creationDate.map { Self.dayFormatter.string(from: $0) } ?? "未知日期"
        return "\(date) · \(record.pixelWidth) × \(record.pixelHeight)"
    }

    @ViewBuilder
    private func searchResultDestination(for record: PhotoSearchIndexRecord) -> some View {
        if let asset = photoClient.accessibleAsset(localIdentifier: record.assetID) {
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
