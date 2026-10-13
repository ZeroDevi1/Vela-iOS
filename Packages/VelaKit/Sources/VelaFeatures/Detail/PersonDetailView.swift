import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 演职人员详情路由。人物属于某台服务器，作品也只在该服务器内查找。
struct PersonRoute: Hashable {
    var serverID: String
    var person: ItemDetails.Person
}

/// 人物某一类作品的完整列表路由（演员页分区标题右侧的「数量 ›」进入）。
struct PersonWorksRoute: Hashable {
    var serverID: String
    var personID: String
    var personName: String
    var kind: PersonWorksKind
}

/// 人物作品的分类，与 Android 版人物页的分区相同。
enum PersonWorksKind: String, CaseIterable, Hashable {
    case movies, series, episodes

    var title: String {
        switch self {
        case .movies: "电影"
        case .series: "剧集"
        case .episodes: "分集"
        }
    }

    /// 服务器条目类型（`IncludeItemTypes`）。
    var itemType: String {
        switch self {
        case .movies: "Movie"
        case .series: "Series"
        case .episodes: "Episode"
        }
    }
}

/// 演职人员详情：头像、生卒与出生地、简介，以及本服务器上的作品。
/// 作品按电影 / 剧集 / 分集分区横滑（与 Android 版一致），每个分区只取前几项，完整列表在二级页 `PersonWorksView`。
struct PersonDetailView: View {
    let route: PersonRoute
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var details: ItemDetails?
    @State private var works: LoadState<[WorksSection]> = .idle

    /// 一个分区：横滑里的前几项与服务器上的总数。
    struct WorksSection: Identifiable {
        var kind: PersonWorksKind
        var items: [MediaItem]
        var total: Int
        var id: PersonWorksKind { kind }
    }

    /// 每个分区横滑展示的条目数，其余在二级页分页加载。
    private static let shelfLimit = 20

    private var client: MediaServerClient? { app.client(forServerID: route.serverID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                header
                worksSection
            }
            .padding(.vertical, VelaTheme.Spacing.l)
        }
        .navigationTitle(route.person.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: route) { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: VelaTheme.Spacing.l) {
            RemoteArtwork(url: client?.personImageURL(route.person, maxWidth: 400), placeholderSymbol: "person.fill")
                .frame(width: isCompact ? 110 : 150, height: isCompact ? 146 : 200)
                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))

            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text(route.person.name).font(.title2.weight(.bold))
                if let role = roleSummary {
                    Text(role).font(.subheadline).foregroundStyle(.secondary)
                }
                if let life = lifeText {
                    Label(life, systemImage: "calendar").font(.subheadline)
                }
                if let place = details?.productionLocations.first, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse").font(.subheadline)
                }
                if let overview = details?.item.overview, !overview.isEmpty {
                    ExpandableText(text: overview)
                }
            }
        }
        .padding(.horizontal, layout.pageMargin)
    }

    /// 生卒：「1990年1月1日 出生（35 岁）」或「1930年1月1日 – 2000年1月1日」。
    private var lifeText: String? {
        guard let birth = details?.item.premiereDate else { return nil }
        let birthText = birth.formatted(.dateTime.year().month().day())
        if let death = details?.endDate {
            return "\(birthText) – \(death.formatted(.dateTime.year().month().day()))"
        }
        let age = Calendar.current.dateComponents([.year], from: birth, to: .now).year ?? 0
        return age > 0 ? "\(birthText) 出生（\(age) 岁）" : "\(birthText) 出生"
    }

    private var roleSummary: String? {
        let type = CastShelf.typeName(route.person.type)
        return type.isEmpty ? nil : type
    }

    // MARK: - 作品

    @ViewBuilder
    private var worksSection: some View {
        switch works {
        case .loaded(let sections) where sections.isEmpty:
            Text("本服务器上没有该人物的作品").foregroundStyle(.secondary).padding(.horizontal, layout.pageMargin)
        case .loaded(let sections):
            ForEach(sections) { section in
                MediaShelf(section.kind.title, items: section.items) { item in
                    NavigationLink(value: item) { card(item) }
                        .buttonStyle(.plain)
                        .itemContextMenu(item)
                } accessory: {
                    NavigationLink(value: PersonWorksRoute(
                        serverID: route.serverID, personID: route.person.id, personName: route.person.name, kind: section.kind
                    )) { ShelfCountLabel(count: section.total) }
                        .buttonStyle(.plain)
                }
            }
        case .failed(let message):
            LoadFailureView(message: message) { Task { await load() } }
        default:
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    /// 电影 / 剧集用海报卡；单集用横卡，标题为剧名、副标题为「S01 E05 - 集名」（与首页继续观看一致）。
    @ViewBuilder
    private func card(_ item: MediaItem) -> some View {
        if item.kind == .episode {
            LandscapeCard(
                title: item.seriesName ?? item.name,
                subtitle: HomeView.episodeSubtitle(item),
                imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 640),
                progress: item.playedFraction,
                width: HomeView.landscapeWidth(compact: isCompact)
            )
        } else {
            PosterCard(
                title: item.name,
                subtitle: item.productionYear.map(String.init),
                imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                width: layout.posterWidth,
                badges: PosterBadges(item)
            )
        }
    }

    private func load() async {
        guard let client else {
            works = .failed("服务器不可用")
            return
        }
        let personID = route.person.id
        async let detailsTask = capture { try await client.itemDetails(id: personID) }
        // 三类作品各取一页，并发请求；总数用于分区标题右侧的数量。
        let results = await withTaskGroup(of: (PersonWorksKind, Result<(items: [MediaItem], total: Int), Error>).self) { group in
            for kind in PersonWorksKind.allCases {
                group.addTask {
                    (kind, await capture {
                        try await client.items(ItemQuery(
                            includeItemTypes: [kind.itemType],
                            recursive: true,
                            sortBy: .premiereDate,
                            sortDescending: true,
                            limit: Self.shelfLimit,
                            personIDs: [personID]
                        ))
                    })
                }
            }
            var collected: [PersonWorksKind: Result<(items: [MediaItem], total: Int), Error>] = [:]
            for await (kind, result) in group { collected[kind] = result }
            return collected
        }
        // 人物资料缺失（服务器未刮削）不影响作品列表。
        if case .success(let value) = await detailsTask { details = value }

        let sections = PersonWorksKind.allCases.compactMap { kind -> WorksSection? in
            guard case .success(let page) = results[kind], !page.items.isEmpty else { return nil }
            return WorksSection(kind: kind, items: MediaItemMerger.merge(page.items), total: page.total)
        }
        // 某一类请求失败时仍显示其余分区；全部失败才报错。
        if sections.isEmpty, let failure = results.values.compactMap({ result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }).first, results.values.allSatisfy({ if case .failure = $0 { true } else { false } }) {
            works = .failed(failure.localizedDescription)
        } else {
            works = .loaded(sections)
        }
    }
}
