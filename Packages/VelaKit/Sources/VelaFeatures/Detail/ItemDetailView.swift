import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 条目详情（电影 / 剧集 / 单集 / 季）。沉浸式版式：模糊剧照铺底，Logo 居中，下方按内容类型展示分区。
struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.openURL) private var openURL
    @State private var model: DetailModel

    init(item: MediaItem) {
        _model = State(initialValue: DetailModel(item: item))
    }

    private var client: MediaServerClient? { app.client(forServerID: model.seed.serverID) }
    private var item: MediaItem { model.item }
    /// 「媒体库配置 → 详情页」的显示开关。
    private var prefs: LibraryPreferences { app.libraryPreferences }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                DetailHero(item: item, client: client, isCompact: isCompact, details: model.details, style: prefs.detailHeaderStyle)

                VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
                    actions
                    if item.kind.isPlayable, !model.sourceOptions.isEmpty {
                        SourceSelectionCard(model: model)
                    }
                    overview
                    if let error = model.actionError ?? model.loadError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, VelaTheme.Spacing.l)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)

                sections
            }
            .padding(.bottom, VelaTheme.Spacing.xxl)
        }
        .background { DetailBackdrop(url: app.imageURL(for: item, kind: .backdrop, maxWidth: 800)) }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        // 头图与背景始终是深色：状态栏与返回按钮使用浅色。
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar(removing: .title)
        .navigationTitle(item.name)
        .task {
            guard let client else { return }
            await model.load(client: client)
        }
    }

    // MARK: - 操作区

    /// 剧集的播放按钮播放「下一集」；单集 / 电影播放自身。
    private var playTarget: MediaItem? {
        item.kind == .series ? model.nextUp : (item.kind.isPlayable ? item : nil)
    }

    private var actions: some View {
        VStack(spacing: VelaTheme.Spacing.m) {
            if let target = playTarget {
                Button {
                    if target.id == item.id {
                        playMedia(.item(model.playbackItem, options: model.playbackOptions))
                    } else {
                        playMedia(.item(target))
                    }
                } label: {
                    Label(playTitle(for: target), systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                // 深色沉浸背景上使用白底黑字的主按钮（与 Apple TV / Infuse 一致），对比度最高。
                .buttonStyle(.glassProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.large)
                .frame(maxWidth: isCompact ? .infinity : 420)

                if let fraction = target.playedFraction, fraction > 0, fraction < 0.95 {
                    ProgressView(value: fraction).tint(.white).frame(maxWidth: isCompact ? .infinity : 420)
                }
            }

            HStack(spacing: VelaTheme.Spacing.xl) {
                if item.kind.isPlayable, item.playedFraction != nil {
                    circleButton("arrow.counterclockwise", label: "从头播放") {
                        var options = model.playbackOptions
                        options.startFromBeginning = true
                        playMedia(.item(model.playbackItem, options: options))
                    }
                }
                circleButton(item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle", label: item.isPlayed ? "标记为未看" : "标记为已看") {
                    guard let client else { return }
                    Task { await model.togglePlayed(client: client) }
                }
                circleButton(item.isFavorite ? "heart.fill" : "heart", label: item.isFavorite ? "取消收藏" : "收藏") {
                    guard let client else { return }
                    Task { await model.toggleFavorite(client: client) }
                }
                if item.kind == .movie || item.kind == .episode {
                    DownloadButton(item: model.playbackItem)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func playTitle(for target: MediaItem) -> String {
        let resume = target.playedFraction.map { $0 > 0 && $0 < 0.95 } ?? false
        let verb = resume ? "继续播放" : "播放"
        if target.id != item.id, let label = target.episodeLabel { return "\(verb) \(label)" }
        return verb
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30, height: 30)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            if let tagline = model.details?.taglines.first, !tagline.isEmpty {
                Text(tagline).font(.headline)
            }
            if let overview = item.overview, !overview.isEmpty {
                ExpandableText(text: overview)
            }
        }
    }

    // MARK: - 分区

    @ViewBuilder
    private var sections: some View {
        if prefs.showEpisodeIndicator, item.kind == .series, !model.seasons.isEmpty {
            MediaShelf("季", items: model.seasons) { season in
                NavigationLink(value: SeasonRoute(series: item, season: season)) {
                    PosterCard(
                        title: season.name,
                        subtitle: season.childCount.map { "\($0) 集" },
                        imageURL: app.imageURL(for: season, kind: .primary, maxWidth: 400)
                            ?? app.imageURL(for: item, kind: .primary, maxWidth: 400),
                        width: VelaTheme.posterWidth(compact: isCompact)
                    )
                    .overlay(alignment: .topTrailing) { UnplayedBadge(count: season.unplayedItemCount) }
                }
                .buttonStyle(.plain)
            }
        }

        if model.parts.count > 1 {
            PartsShelf(parts: model.parts)
        }

        if prefs.showEpisodeIndicator, item.kind == .episode, model.siblingEpisodes.count > 1 {
            EpisodeShelf(title: "更多来自 \(model.siblingEpisodes.first.flatMap { _ in item.parentIndexNumber.map { "第 \($0) 季" } } ?? "本季")",
                         episodes: model.siblingEpisodes, currentID: item.id)
        }

        if let details = model.details {
            ChapterShelf(item: item, client: client)
            if prefs.showCast {
                CastShelf(people: details.people, client: client, serverID: item.serverID)
            }
        }

        ExtrasShelf(trailers: model.trailers, remoteTrailers: model.details?.remoteTrailers ?? [], features: model.specialFeatures)

        if prefs.showSimilar, !model.similar.isEmpty {
            MediaShelf("类似作品", items: model.similar) { other in
                NavigationLink(value: other) {
                    PosterCard(
                        title: other.name,
                        subtitle: other.productionYear.map(String.init),
                        imageURL: app.imageURL(for: other, kind: .primary, maxWidth: 400),
                        width: VelaTheme.posterWidth(compact: isCompact)
                    )
                }
                .buttonStyle(.plain)
            }
        }

        let links = ExternalLink.links(for: item).filter { prefs.showDoubanLink || $0.name != "豆瓣" }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("链接").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
                ScrollView(.horizontal) {
                    HStack(spacing: VelaTheme.Spacing.s) {
                        ForEach(links) { link in
                            Button { openURL(link.url) } label: { Label(link.name, systemImage: "link") }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
            }
        }

        if prefs.showMediaInfo, let details = model.details, let source = model.selectedSource {
            MediaInfoSection(details: details, source: source)
        }
    }
}

/// 季页面路由。
struct SeasonRoute: Hashable {
    var series: MediaItem
    var season: MediaItem
}

// MARK: - 背景与头图

/// 整页背景：低分辨率剧照大半径模糊 + 暗化，营造沉浸感且不干扰文字。
private struct DetailBackdrop: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            RemoteArtwork(url: url, placeholderSymbol: "")
                .blur(radius: 60)
                .opacity(0.55)
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

private struct DetailHero: View {
    let item: MediaItem
    let client: MediaServerClient?
    let isCompact: Bool
    let details: ItemDetails?
    /// 「详情页展示」：背景图（横版）或海报（竖版）。
    let style: LibraryPreferences.ArtworkStyle

    var body: some View {
        // 固定尺寸占位决定布局，图片作为 overlay 填充，避免 scaledToFill 撑宽页面。
        Color.clear
            .frame(height: isCompact ? 480 : 560)
            .frame(maxWidth: .infinity)
            .overlay {
                RemoteArtwork(
                    url: style == .poster
                        ? client?.imageURL(for: item, kind: .primary, maxWidth: 1200)
                        : client?.imageURL(for: item, kind: .backdrop, maxWidth: 1920)
                            ?? client?.imageURL(for: item, kind: .primary, maxWidth: 1200),
                    placeholderSymbol: "film"
                )
            }
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipped()
            .overlay(alignment: .bottom) { titleBlock.padding(.horizontal, VelaTheme.Spacing.l).padding(.bottom, VelaTheme.Spacing.l) }
            .foregroundStyle(.white)
    }

    private var titleBlock: some View {
        VStack(spacing: VelaTheme.Spacing.s) {
            if let logo = client?.logoURL(for: item, maxWidth: 800) {
                CachedImage(url: logo, contentMode: .fit) { titleText }
                .frame(maxWidth: isCompact ? 280 : 420, maxHeight: isCompact ? 110 : 150)
                .accessibilityLabel(item.seriesName ?? item.name)
            } else {
                titleText
            }

            if item.kind == .episode || item.kind == .season {
                Text([item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            metadata
            if !item.genres.isEmpty {
                Text(item.genres.prefix(4).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var titleText: some View {
        Text(item.seriesName ?? item.name)
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    private var metadata: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            if let score = item.communityRating {
                Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    .labelStyle(RatingLabelStyle())
            }
            if let date = item.premiereDate {
                Text(date.formatted(.dateTime.year().month().day()))
            } else if let year = item.productionYear {
                Text(String(year))
            }
            if let runtime = MediaFormat.runtime(item.runTimeTicks) { Text(runtime) }
            if let rating = item.officialRating {
                Text(rating)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.7)))
            }
            if item.kind == .series, let status = details?.seriesStatus {
                Text(status == "Ended" ? "已完结" : "连载中")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.9))
    }
}

private struct RatingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(.red)
            configuration.title
        }
    }
}

/// 默认显示 4 行，点击展开全部。
struct ExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 4)
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            .accessibilityHint(expanded ? "" : "轻点展开全文")
    }
}

struct UnplayedBadge: View {
    let count: Int?

    var body: some View {
        if let count, count > 0 {
            Text("\(count)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(VelaTheme.accentDeep, in: .capsule)
                .padding(6)
                .accessibilityLabel("\(count) 集未看")
        }
    }
}
