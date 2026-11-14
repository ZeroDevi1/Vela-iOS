import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 条目详情（电影 / 剧集 / 单集 / 季）。版式与 Android 版一致：模糊剧照铺底，Logo 与元数据左对齐，
/// 已看 / 收藏 / 更多放在导航栏（iOS 原生位置），下方按内容类型展示分区。
struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.isCompactLayout) private var isCompact
    /// 按本页实际宽度分档（侧边栏展开、分屏时比整窗窄）；写入环境供子视图使用。
    @State private var layout: VelaLayout = .compact
    @Environment(\.openURL) private var openURL
    @State private var model: DetailModel
    /// 当前账号是否为服务器管理员（决定是否显示「管理元数据」）。
    @State private var isAdmin = false
    @State private var showsMetadataManager = false

    init(item: MediaItem) {
        _model = State(initialValue: DetailModel(item: item))
    }

    private var client: MediaServerClient? { app.client(forServerID: model.seed.serverID) }
    private var item: MediaItem { model.item }
    /// 「媒体库配置 → 详情页」的显示开关。
    private var prefs: LibraryPreferences { app.libraryPreferences }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if layout.isWide { wideContent } else { compactContent }
            }
            #if DEBUG
            .task { await scrollToDebugAnchor(proxy) }
            #endif
        }
        .background {
            DetailBackdrop(
                url: app.imageURL(for: item, kind: .backdrop, maxWidth: 800),
                posterURL: app.imageURL(for: item, kind: .primary, maxWidth: 200)
            )
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        // 头图与背景始终是深色：状态栏与返回按钮使用浅色。
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar(removing: .title)
        #if os(iOS)
        // 宽屏详情页铺满整屏（与 Forward 一致），iPad 顶部的浮动标签栏会压在头图上，进入时隐藏。
        .toolbar(layout.isWide ? .hidden : .automatic, for: .tabBar)
        #endif
        // 宽屏的已看 / 收藏 / 更多放在头图右侧操作列，导航栏只留返回按钮（与 Forward 一致）。
        .toolbar { if !layout.isWide { toolbarActions } }
        .navigationTitle(item.name)
        .sheet(isPresented: $showsMetadataManager) {
            MetadataManagerView(item: item, mediaSource: model.selectedSource) {
                guard let client else { return }
                Task { await model.load(client: client) }
            }
        }
        .task(id: item.serverID) { isAdmin = (try? await client?.isAdministrator()) ?? false }
        .environment(\.velaLayout, layout)
        .onGeometryChange(for: VelaLayout.self) { VelaLayout(size: $0.size) } action: { layout = $0 }
        .task {
            guard let client else { return }
            await model.load(client: client)
        }
        // 分段属于具体版本：详情加载完选定默认版本、以及用户切换版本后各取一次。
        .task(id: model.selectedSourceID) {
            guard let client else { return }
            await model.loadParts(client: client)
        }
    }

    /// iPhone / 窄分屏：头图下竖排播放源、播放按钮、简介。
    private var compactContent: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
            DetailHero(item: item, client: client, isCompact: isCompact, details: model.details, style: prefs.detailHeaderStyle)

            VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
                // 与 Android 相同的顺序：播放源选择 → 播放按钮 → 简介 → 导演。
                if item.kind.isPlayable, !model.sourceOptions.isEmpty {
                    SourceSelectionCard(model: model)
                }
                actions
                overview
                directorsLine
                statusLine
            }
            .velaPageMargin()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)

            sections
        }
        .padding(.bottom, VelaTheme.Spacing.xxl)
    }

    /// iPad / Mac：沉浸式头图（左信息、右操作列），剧集在页内列出当前季单集，其余分区铺满宽度。
    private var wideContent: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.xxl) {
            WideDetailHero(item: item, client: client, details: model.details, style: prefs.detailHeaderStyle) {
                wideActionColumn
            }

            if item.kind == .series, !model.seasons.isEmpty {
                SeasonEpisodesSection(model: model, client: client).id("episodes")
            }

            if item.kind.isPlayable, !model.sourceOptions.isEmpty {
                WideSourceSection(model: model).id("source")
            }
            statusLine.velaPageMargin()
            DetailTagChips(item: item, details: model.details).velaPageMargin()

            sections
        }
        .padding(.bottom, VelaTheme.Spacing.xxl)
    }

    /// 头图右侧：播放按钮、图标操作（下载、已看、收藏、更多）、评分。
    private var wideActionColumn: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
            if let target = playTarget {
                Button { play(target) } label: {
                    WidePlayButtonLabel(
                        title: resumeFraction(target) != nil ? "继续播放" : "播放",
                        subtitle: playSubtitle(for: target),
                        progress: resumeFraction(target)
                    )
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: VelaTheme.Spacing.m) {
                if let target = playTarget, resumeFraction(target) != nil {
                    iconButton("从头播放", systemImage: "arrow.counterclockwise") { playFromBeginning(target) }
                }
                if item.kind == .movie || item.kind == .episode {
                    DownloadButton(item: model.playbackItem, source: model.selectedSource)
                }
                iconButton(item.isPlayed ? "标记为未看" : "标记为已看", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle") {
                    guard let client else { return }
                    Task { await model.togglePlayed(client: client) }
                }
                iconButton(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "heart.fill" : "heart") {
                    guard let client else { return }
                    Task { await model.toggleFavorite(client: client) }
                }
                Menu { moreMenuItems } label: {
                    Image(systemName: "ellipsis").font(.title3).frame(width: 30, height: 30)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .tint(.white)
                .buttonBorderShape(.circle)
                .accessibilityLabel("更多")
                Spacer(minLength: 0)
                WideRatingRow(item: item)
            }
        }
    }


    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .buttonBorderShape(.circle)
        .accessibilityLabel(title)
    }

    /// 「第 1 季 · 42 集  15:56」：剧集页附带下一集的季 / 集号，续播时附带位置。
    private func playSubtitle(for target: MediaItem) -> String? {
        var parts: [String] = []
        if target.kind == .episode, let episode = target.indexNumber {
            parts.append([target.parentIndexNumber.map { "第 \($0) 季" }, "\(episode) 集"].compactMap { $0 }.joined(separator: " · "))
        }
        if resumeFraction(target) != nil, let ticks = target.playbackPositionTicks {
            parts.append(PlayerTime.format(Ticks.seconds(ticks)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = model.actionError ?? model.loadError {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
        } else if let notice = model.actionNotice {
            Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    #if DEBUG
    /// 仅 Debug 构建：启动环境变量 `VELA_DEBUG_DETAIL_ANCHOR`（episodes / source / chapters / cast / media / similar）
    /// （另有 source / stills）时，等分区加载后滚到该处，便于真机命令行截图验收下方分区。
    private func scrollToDebugAnchor(_ proxy: ScrollViewProxy) async {
        guard let anchor = ProcessInfo.processInfo.environment["VELA_DEBUG_DETAIL_ANCHOR"], !anchor.isEmpty else { return }
        try? await Task.sleep(for: .seconds(4))
        proxy.scrollTo(anchor, anchor: .top)
    }
    #endif

    // MARK: - 操作区

    /// 剧集的播放按钮播放「下一集」；单集 / 电影播放自身。
    private var playTarget: MediaItem? {
        item.kind == .series ? model.nextUp : (item.kind.isPlayable ? item : nil)
    }

    /// 播放按钮（续播时按进度填充，与 Android 一致）；电影 / 单集右侧附下载按钮。
    private var actions: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            if let target = playTarget {
                Button { play(target) } label: {
                    ProgressPlayLabel(title: playTitle(for: target), progress: resumeFraction(target))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: isCompact ? .infinity : 420)
                // 有续播进度时，在播放按钮旁直接提供「从头播放」，不必进「更多」菜单。
                if resumeFraction(target) != nil {
                    Button { playFromBeginning(target) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title3.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("从头播放")
                }
            }
            if item.kind == .movie || item.kind == .episode {
                DownloadButton(item: model.playbackItem, source: model.selectedSource)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 本条目带上播放源选择；剧集页的下一集直接播放。
    private func play(_ target: MediaItem) {
        if target.id == item.id {
            playMedia(.item(model.playbackItem, options: model.playbackOptions))
        } else {
            playMedia(.item(target))
        }
    }

    /// 忽略续播进度从头播放；本条目沿用已选的播放源 / 音轨 / 字幕，剧集页的下一集用默认选择。
    private func playFromBeginning(_ target: MediaItem) {
        var options = target.id == item.id ? model.playbackOptions : PlaybackRequest.Options()
        options.startFromBeginning = true
        playMedia(.item(target.id == item.id ? model.playbackItem : target, options: options))
    }

    /// 只有看到一半的条目显示进度；未开始或已看完（≥ 95%）按「播放」处理。
    private func resumeFraction(_ target: MediaItem) -> Double? {
        guard let fraction = target.playedFraction, fraction > 0, fraction < 0.95 else { return nil }
        return fraction
    }

    /// 「继续播放 15:18」：续播时附带位置；剧集页的目标是下一集时附带集号。
    private func playTitle(for target: MediaItem) -> String {
        guard resumeFraction(target) != nil else {
            if target.id != item.id, let label = target.episodeLabel { return "播放 \(label)" }
            return "播放"
        }
        let position = target.playbackPositionTicks.map { PlayerTime.format(Ticks.seconds($0)) }
        let label = target.id != item.id ? target.episodeLabel : nil
        return (["继续播放", label, position].compactMap { $0 }).joined(separator: " ")
    }

    /// 导航栏：已看、收藏、更多（从头播放、刷新元数据）。
    @ToolbarContentBuilder
    private var toolbarActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(item.isPlayed ? "标记为未看" : "标记为已看", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle") {
                guard let client else { return }
                Task { await model.togglePlayed(client: client) }
            }
            Button(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "heart.fill" : "heart") {
                guard let client else { return }
                Task { await model.toggleFavorite(client: client) }
            }
            Menu("更多", systemImage: "ellipsis") { moreMenuItems }
        }
    }

    /// 「更多」菜单：从头播放、刷新元数据。
    @ViewBuilder
    private var moreMenuItems: some View {
        // 剧集页的目标是下一集：同样可以从头播放该集。
        if let target = playTarget, target.playedFraction != nil {
            Button("从头开始播放", systemImage: "arrow.counterclockwise") { playFromBeginning(target) }
        }
        if isAdmin {
            Button("管理元数据", systemImage: "slider.horizontal.3") { showsMetadataManager = true }
        }
        // 单集的元数据随剧集刷新：在剧集入口操作可一次更新全部季与单集。
        if item.kind != .episode {
            Button(item.kind == .series ? "刷新元数据（全部剧集）" : "刷新元数据", systemImage: "arrow.clockwise") {
                guard let client else { return }
                Task { await model.refreshMetadata(client: client) }
            }
        }
    }

    /// 「导演：A, B」，点按进入人物页。
    @ViewBuilder
    private var directorsLine: some View {
        let directors = (model.details?.people ?? []).filter { $0.type == "Director" }
        if !directors.isEmpty {
            // 横向 ScrollView 不向外提供文字基线，按基线对齐会把它压到行尾下方并撑高整行；两侧同字号，居中对齐即可。
            HStack(alignment: .center, spacing: 6) {
                Text("导演：").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(directors) { person in
                            NavigationLink(value: PersonRoute(serverID: item.serverID, person: person)) {
                                Text(person.name).font(.subheadline).foregroundStyle(VelaTheme.accentLight)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .velaHideHorizontalScrollIndicators()
            }
        }
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

    /// 分区顺序与 Android 一致：季 / 同季单集 → 章节 → 演职人员 → 外部链接 → 媒体信息 → 预告片 → 由 X 执导 → 推荐。
    @ViewBuilder
    private var sections: some View {
        // 宽屏的季与单集已在页内（`SeasonEpisodesSection`）展示。
        if prefs.showEpisodeIndicator, !layout.isWide, item.kind == .series, !model.seasons.isEmpty {
            MediaShelf("季", items: model.seasons) { season in
                NavigationLink(value: SeasonRoute(series: item, season: season)) {
                    PosterCard(
                        title: season.name,
                        subtitle: nil,
                        imageURL: app.imageURL(for: season, kind: .primary, maxWidth: 400)
                            ?? app.imageURL(for: item, kind: .primary, maxWidth: 400),
                        width: layout.posterWidth
                    )
                    .overlay(alignment: .top) { EpisodeCountBadge(count: season.childCount) }
                }
                .buttonStyle(.plain)
            }
        }

        if model.parts.count > 1 {
            PartsShelf(parts: model.parts, sourceID: model.partsSourceID)
        }

        if prefs.showEpisodeIndicator, item.kind == .episode, model.siblingEpisodes.count > 1 {
            EpisodeShelf(title: "更多来自 \(item.parentIndexNumber.map { "第 \($0) 季" } ?? "本季")",
                         episodes: model.siblingEpisodes, currentID: item.id)
        }

        if let details = model.details {
            ChapterShelf(item: item, client: client) { position in
                var options = model.playbackOptions
                options.startPosition = position
                playMedia(.item(model.playbackItem, options: options))
            }
            .id("chapters")
            if prefs.showCast {
                if layout.isWide {
                    WideCastShelf(people: details.people, client: client, serverID: item.serverID).id("cast")
                } else {
                    CastShelf(people: details.people, client: client, serverID: item.serverID)
                }
            }
        }

        let links = ExternalLink.links(for: item).filter { prefs.showDoubanLink || $0.name != "豆瓣" }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("外部链接").font(.title3.weight(.semibold)).velaPageMargin()
                ScrollView(.horizontal) {
                    HStack(spacing: VelaTheme.Spacing.s) {
                        ForEach(links) { link in
                            Button { openURL(link.url) } label: {
                                Text(link.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .velaPageMargin()
                }
                .velaHideHorizontalScrollIndicators()
            }
        }

        if prefs.showMediaInfo, let details = model.details, let source = model.selectedSource {
            if layout.isWide {
                WideMediaInfoSection(details: details, source: source).id("media")
            } else {
                MediaInfoSection(details: details, source: source)
            }
        }

        // 静态剧照与视频花絮独立展示；iPhone 也保留单张 fanart。
        if let client {
            StillsShelf(images: client.stillImages(for: item, screenshotTags: model.details?.screenshotImageTags ?? []))
        }

        ExtrasShelf(trailers: model.trailers, remoteTrailers: model.details?.remoteTrailers ?? [], features: model.specialFeatures)

        ForEach(model.directorWorks) { works in
            posterShelf("由 \(works.director.name) 执导", items: works.items)
        }

        if prefs.showSimilar, !model.similar.isEmpty {
            posterShelf("推荐", items: model.similar).id("similar")
        }
    }

    private func posterShelf(_ title: String, items: [MediaItem]) -> some View {
        MediaShelf(title, items: items) { other in
            NavigationLink(value: other) {
                PosterCard(
                    title: other.name,
                    subtitle: other.productionYear.map(String.init),
                    imageURL: app.imageURL(for: other, kind: .primary, maxWidth: 400),
                    width: layout.posterWidth,
                    badges: PosterBadges(other)
                )
            }
            .buttonStyle(.plain)
            .itemContextMenu(other)
        }
    }
}

/// 播放按钮：续播时左侧按进度填充白色，其余为深色（与 Android 一致）；文字用差值混合，在两种底色上都清晰。
/// 未开始播放时整个按钮为白底。
private struct ProgressPlayLabel: View {
    let title: String
    let progress: Double?

    var body: some View {
        Label(title, systemImage: "play.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .blendMode(.difference)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.14)
                        Color.white.frame(width: proxy.size.width * (progress ?? 1))
                    }
                }
            }
            .compositingGroup()
            .clipShape(.capsule)
            .contentShape(.capsule)
            .accessibilityElement(children: .combine)
    }
}

/// 季海报顶部的「41 集」标记（与 Android 一致）。
private struct EpisodeCountBadge: View {
    let count: Int?

    var body: some View {
        if let count, count > 0 {
            Text("\(count) 集")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: .capsule)
                .padding(.top, 8)
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
/// 详情页底色：海报主色推出的深色调渐变（见 `BackdropTone`）上叠模糊剧照。取不到主色（无海报、灰色海报）时为纯黑。
private struct DetailBackdrop: View {
    let url: URL?
    let posterURL: URL?
    @State private var tone: Color?

    var body: some View {
        ZStack {
            Color.black
            if let tone {
                LinearGradient(colors: [tone, .black], startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
            RemoteArtwork(url: url, placeholderSymbol: "")
                .blur(radius: 60)
                .opacity(0.45)
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .task(id: posterURL) {
            guard let posterURL, let image = await ImagePipeline.shared.image(for: posterURL),
                  let hsb = BackdropTone.darkTone(for: image) else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                tone = Color(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
            }
        }
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
                DetailHeroArtwork(item: item, client: client, style: style, posterWidth: 1200, backdropWidth: 1920)
            }
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .bottom) { titleBlock.velaPageMargin().padding(.bottom, VelaTheme.Spacing.l) }
            .foregroundStyle(.white)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            if let logo = client?.logoURL(for: item, maxWidth: 800) {
                CachedImage(url: logo, contentMode: .fit) { titleText }
                .frame(maxWidth: isCompact ? 280 : 420, maxHeight: isCompact ? 110 : 150, alignment: .leading)
                .accessibilityLabel(item.seriesName ?? item.name)
            } else {
                titleText
            }

            if let subtitle = episodeTitle {
                Text(subtitle).font(.headline)
            }

            metadata
            DetailTagChips(item: item, details: details)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单集「S1:E1 - 标题」、季「第 1 季」（与 Android 一致）。
    private var episodeTitle: String? {
        switch item.kind {
        case .episode:
            guard let episode = item.indexNumber else { return item.name }
            let season = item.parentIndexNumber.map { "S\($0):" } ?? ""
            return "\(season)E\(episode) - \(item.name)"
        case .season:
            return item.name
        default:
            return nil
        }
    }

    private var titleText: some View {
        Text(item.seriesName ?? item.name)
            .font(.largeTitle.bold())
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

/// 默认显示 `collapsedLines` 行（4 行），点击展开全部。
struct ExpandableText: View {
    let text: String
    var collapsedLines = 4
    @State private var expanded = false

    var body: some View {
        // 服务器简介常带全角空格缩进或首尾换行，折叠显示时会浪费一行。
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : collapsedLines)
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

