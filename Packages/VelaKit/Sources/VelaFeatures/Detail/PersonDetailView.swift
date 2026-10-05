import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 演职人员详情路由。人物属于某台服务器，作品也只在该服务器内查找。
struct PersonRoute: Hashable {
    var serverID: String
    var person: ItemDetails.Person
}

/// 演职人员详情：头像、生卒与出生地、简介，以及本服务器上的作品（可按电影 / 剧集筛选）。
struct PersonDetailView: View {
    let route: PersonRoute
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var details: ItemDetails?
    @State private var works: LoadState<[MediaItem]> = .idle
    @State private var filter: Filter = .all

    enum Filter: Hashable {
        case all, movies, series
    }

    /// 作品上限：演员在单台服务器上的作品通常不会超过这个数。
    private static let worksLimit = 300

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
        .padding(.horizontal, VelaTheme.Spacing.l)
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
        case .loaded(let all):
            let movies = all.filter { $0.kind == .movie }
            let series = all.filter { $0.kind == .series }
            let shown = switch filter {
            case .all: all
            case .movies: movies
            case .series: series
            }
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                HStack {
                    Text("作品").font(.title3.weight(.semibold))
                    Spacer()
                    if !movies.isEmpty && !series.isEmpty {
                        Picker("类型", selection: $filter) {
                            Text("全部 \(all.count)").tag(Filter.all)
                            Text("电影 \(movies.count)").tag(Filter.movies)
                            Text("剧集 \(series.count)").tag(Filter.series)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, VelaTheme.Spacing.l)

                if shown.isEmpty {
                    Text("本服务器上没有该人物的作品").foregroundStyle(.secondary).padding(.horizontal, VelaTheme.Spacing.l)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: VelaTheme.posterWidth(compact: isCompact)), spacing: VelaTheme.Spacing.m, alignment: .top)],
                        spacing: VelaTheme.Spacing.l
                    ) {
                        ForEach(shown) { item in
                            NavigationLink(value: item) {
                                PosterCard(
                                    title: item.name,
                                    subtitle: item.productionYear.map(String.init),
                                    imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                                    width: VelaTheme.posterWidth(compact: isCompact),
                                    badges: PosterBadges(item)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
            }
        case .failed(let message):
            LoadFailureView(message: message) { Task { await load() } }
        default:
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        guard let client else {
            works = .failed("服务器不可用")
            return
        }
        let personID = route.person.id
        async let detailsTask = capture { try await client.itemDetails(id: personID) }
        async let worksTask = capture {
            try await client.items(ItemQuery(
                includeItemTypes: ["Movie", "Series"],
                recursive: true,
                sortBy: .premiereDate,
                sortDescending: true,
                limit: Self.worksLimit,
                personIDs: [personID]
            )).items
        }
        // 人物资料缺失（服务器未刮削）不影响作品列表。
        if case .success(let value) = await detailsTask { details = value }
        works = LoadState(await worksTask.map(MediaItemMerger.merge))
    }
}
