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
    @StateObject private var library = LocalPhotoLibraryViewModel()
    @StateObject private var backupCoordinator = PhotoBackupCoordinator()
    @State private var section: MainSection = .photos
    @State private var isSearchPresented = false

    var body: some View {
        nativeTabs
        .sheet(isPresented: $isSearchPresented) {
            LocalSearchView(assets: library.assets)
        }
        .task {
            await library.start()
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
                PhasePlaceholderView(
                    title: "人物",
                    symbol: MainSection.people.symbol,
                    message: "人物分组会在本地 AI 阶段提供。MyNAS Photos 不会自动猜测真实人物姓名。"
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
    @FocusState private var searchIsFocused: Bool
    let assets: [LocalPhotoAsset]
    @State private var query = ""

    private var results: [LocalPhotoAsset] {
        guard !query.isEmpty else { return [] }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return assets.filter { asset in
            asset.mediaKind.displayName.contains(normalized)
                || asset.creationDate.map { Self.dayFormatter.string(from: $0).contains(normalized) } == true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("本地图库") {
                        Text("可按“照片”“视频”或日期搜索当前允许访问的本地项目。")
                    }
                    Section("将在后续阶段提供") {
                        Label("人物与动漫角色", systemImage: "person.2")
                        Label("地点与 OCR 文字", systemImage: "text.viewfinder")
                        Label("语义与重复照片", systemImage: "sparkles")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section("本地结果") {
                        ForEach(results) { asset in
                            HStack {
                                Image(systemName: asset.mediaKind.systemImage)
                                Text(asset.creationDate.map { Self.dayFormatter.string(from: $0) } ?? "未知日期")
                                Spacer()
                                Text(asset.mediaKind.displayName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "人物、日期、地点或文字")
            .onAppear { searchIsFocused = true }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
