import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 「我的媒体」：以大卡片网格列出服务器上的媒体库（与 Android 版 `MyMedia` 一致：iPhone 两列，卡片 1.2:1，下方名称与条目数）。
struct MyMediaView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var views: LoadState<[MediaItem]> = .idle

    var body: some View {
        NavigationStack {
            Group {
                switch views {
                case .loaded(let items) where items.isEmpty:
                    ContentUnavailableView("没有媒体库", systemImage: "square.stack")
                case .loaded(let items):
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: VelaTheme.Spacing.xl) {
                            ForEach(items) { library in
                                NavigationLink(value: LibraryRoute(library: library)) {
                                    LibraryCard(library: library, imageURL: app.imageURL(for: library, kind: .primary, maxWidth: 600))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, VelaTheme.Spacing.l)
                    }
                case .failed(let message):
                    LoadFailureView(message: message) { Task { await load() } }
                case .idle, .loading:
                    ProgressView()
                }
            }
            .navigationTitle("我的媒体")
            #if os(iOS)
            .navigationSubtitle(views.value.map { "\($0.count) 个媒体库" } ?? "")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ServerSwitcherMenu() }
            }
            .navigationDestination(for: LibraryRoute.self) { LibraryItemsView(library: $0.library) }
            .detailDestinations()
            .refreshable { await load() }
            .task(id: app.servers.activeServer?.baseURL) { await load() }
        }
    }

    private var columns: [GridItem] {
        isCompact
            ? Array(repeating: GridItem(.flexible(), spacing: VelaTheme.Spacing.l, alignment: .top), count: 2)
            : [GridItem(.adaptive(minimum: 220), spacing: VelaTheme.Spacing.l, alignment: .top)]
    }

    private func load() async {
        // 没有可用客户端（服务器记录损坏、凭据丢失）时给出原因，不能停在无限转圈。
        guard let client = app.activeClient else {
            views = .failed("无法连接当前服务器，请在设置中检查服务器与登录状态。")
            return
        }
        if views.value == nil { views = .loading }
        views = LoadState(await capture { try await client.userViews() }.map { $0.filter(Self.isBrowsable) })
    }

    /// 播放列表、直播不是按条目浏览的媒体库，不在这里列出。
    static func isBrowsable(_ library: MediaItem) -> Bool {
        !["playlists", "livetv"].contains(library.collectionType?.lowercased() ?? "")
    }
}

struct LibraryRoute: Hashable {
    var library: MediaItem
}

/// 媒体库卡片：服务器生成的库封面（通常是海报拼图），没有封面时显示类型图标。
private struct LibraryCard: View {
    let library: MediaItem
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear
                .aspectRatio(1.2, contentMode: .fit)
                .overlay {
                    CachedImage(url: imageURL) {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: Self.symbol(for: library.collectionType))
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 16))
                .padding(.bottom, VelaTheme.Spacing.xs)
            Text(library.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let count = library.childCount, count > 0 { return "\(count) 项" }
        return Self.typeName(for: library.collectionType)
    }

    static func symbol(for collectionType: String?) -> String {
        switch collectionType?.lowercased() {
        case "movies": "film"
        case "tvshows": "tv"
        case "music": "music.note"
        case "books": "book"
        case "boxsets": "square.stack"
        default: "folder"
        }
    }

    static func typeName(for collectionType: String?) -> String {
        switch collectionType?.lowercased() {
        case "movies": "电影"
        case "tvshows": "剧集"
        case "boxsets": "合集"
        default: "媒体库"
        }
    }
}
