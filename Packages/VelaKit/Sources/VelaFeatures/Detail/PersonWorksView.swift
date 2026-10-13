import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 人物某一类作品的完整列表（与 Android 版人物作品页一致）：分页网格，
/// 顶部工具条为条目数、随机播放、海报 / 横版样式、筛选（观看状态 / 收藏 / 年份）与排序。
/// 排序、筛选与样式只在本页有效，不记住。
struct PersonWorksView: View {
    let route: PersonWorksRoute

    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var sort = LibrarySort(field: .premiereDate, descending: true)
    @State private var played: Bool?
    @State private var favoritesOnly = false
    /// 选中的出品年份；nil 不筛选。
    @State private var year: Int?
    /// 年份筛选的选项（从新到旧）；取不到时为空，筛选菜单里不出现年份。
    @State private var years: [Int] = []
    @State private var style: LibraryImageStyle
    @State private var counts = GridCounts()
    @State private var shuffleError: String?

    /// 年份选项取自该人物这一类的全部作品，最多取这么多项（与 Android 版人物作品的上限相同）。
    private static let yearScanLimit = 500

    init(route: PersonWorksRoute) {
        self.route = route
        // 单集的图片是 16:9 剧照，默认用横版样式。
        _style = State(initialValue: route.kind == .episodes ? .landscape : .poster)
    }

    /// 当前筛选对应的查询（不含排序与观看状态，二者由网格另行附加）。
    private var template: ItemQuery {
        var query = ItemQuery(
            includeItemTypes: [route.kind.itemType],
            recursive: true,
            isFavorite: favoritesOnly ? true : nil,
            personIDs: [route.personID]
        )
        if let year { query.years = [year] }
        return query
    }

    private var filtersActive: Bool { played != nil || favoritesOnly || year != nil }

    var body: some View {
        PagedItemGrid(
            serverID: route.serverID,
            template: template,
            sort: sort,
            played: played,
            style: style,
            counts: $counts
        ) {
            // macOS 的工具条控件在窗口工具栏，条目数在窗口副标题（与媒体库页一致）。
            #if os(iOS)
            chromeBar
            #endif
        }
        .navigationTitle("\(route.personName) · \(route.kind.title)")
        .navigationSubtitle(counts.total > 0 ? "\(counts.loaded) / \(counts.total) 项" : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                shuffleButton.help("随机播放")
                styleButton.help(style == .poster ? "横版样式" : "海报样式")
                filterMenu
                sortMenu
            }
        }
        #endif
        .task(id: route) { await loadYears() }
        .alert("随机播放失败", isPresented: Binding(get: { shuffleError != nil }, set: { if !$0 { shuffleError = nil } })) {
            Button("好") {}
        } message: {
            Text(shuffleError ?? "")
        }
    }

    private var chromeBar: some View {
        HStack(spacing: 4) {
            Text("\(counts.total) 项")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            shuffleButton
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 36)
            Spacer()
            styleButton
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 36)
            filterMenu
            sortMenu
        }
        .buttonStyle(.plain)
        .font(.body)
    }

    private var shuffleButton: some View {
        Button("随机播放", systemImage: "shuffle") { Task { await shuffle() } }
            .disabled(counts.total == 0)
    }

    private var styleButton: some View {
        Button(style == .poster ? "横版样式" : "海报样式", systemImage: style == .poster ? "square.grid.2x2" : "rectangle.grid.1x2") {
            style = style == .poster ? .landscape : .poster
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("观看状态", selection: $played) {
                Text("全部").tag(Bool?.none)
                Text("未看").tag(Bool?.some(false))
                Text("已看").tag(Bool?.some(true))
            }
            Toggle("只看收藏", isOn: $favoritesOnly)
            if !years.isEmpty {
                Picker("年份", selection: $year) {
                    Text("全部年份").tag(Int?.none)
                    ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .foregroundStyle(filtersActive ? VelaTheme.accent : Color.primary)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("筛选")
    }

    private var sortMenu: some View {
        LibrarySortMenu(options: LibrarySort.fields(for: route.kind == .series ? "tvshows" : nil), sort: $sort)
    }

    /// 取年份筛选的选项。失败或人物没有带年份的作品时选项为空，其余筛选不受影响。
    private func loadYears() async {
        guard let client = app.client(forServerID: route.serverID) else { return }
        let page = try? await client.items(ItemQuery(
            includeItemTypes: [route.kind.itemType],
            recursive: true,
            limit: Self.yearScanLimit,
            personIDs: [route.personID]
        ))
        years = Set(page?.items.compactMap(\.productionYear) ?? []).sorted(by: >)
    }

    /// 在当前筛选结果里随机挑一项从头播放；挑到剧集时再从这部剧里随机挑一集（剧集本身不可播放）。
    private func shuffle() async {
        guard let client = app.client(forServerID: route.serverID) else { return }
        var query = template
        query.sortBy = .random
        query.limit = 1
        query.isPlayed = played
        do {
            guard var item = try await client.items(query).items.first else {
                shuffleError = "没有符合当前筛选条件的作品。"
                return
            }
            if item.kind == .series {
                let episodes = try await client.items(ItemQuery(
                    parentID: item.id, includeItemTypes: ["Episode"], recursive: true, sortBy: .random, limit: 1
                ))
                guard let episode = episodes.items.first else {
                    shuffleError = "《\(item.name)》里没有可播放的单集。"
                    return
                }
                item = episode
            }
            playMedia(.item(item, options: .init(startFromBeginning: true)))
        } catch {
            shuffleError = error.localizedDescription
        }
    }
}
