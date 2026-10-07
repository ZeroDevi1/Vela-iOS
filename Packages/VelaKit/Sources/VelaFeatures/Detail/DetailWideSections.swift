import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

// 宽屏（iPad / Mac，`VelaLayout.isWide`）详情页的分区。参考 Forward：剧照铺满首屏，左下 Logo + 元数据 + 简介，
// 右侧一列为播放按钮、图标操作与评分；剧集在页内直接列出当前季的大尺寸单集卡。iPhone 版式不使用这些视图。

// MARK: - 头图

/// 沉浸式头图：高度按可视高度的比例（`VelaLayout.heroHeightFraction`），右侧操作列由调用方提供。
struct WideDetailHero<Actions: View>: View {
    let item: MediaItem
    let client: MediaServerClient?
    let details: ItemDetails?
    let style: LibraryPreferences.ArtworkStyle
    @ViewBuilder let actions: Actions
    @Environment(\.velaLayout) private var layout

    var body: some View {
        Color.clear
            .containerRelativeFrame(.vertical) { height, _ in max(height * layout.heroHeightFraction, 420) }
            .frame(maxWidth: .infinity)
            .overlay {
                // 剧照与压暗层一起向下渐隐到透明，露出页面的模糊背景，头图与下方分区之间没有硬边（与 Forward 一致）。
                ZStack {
                    RemoteArtwork(
                        url: style == .poster
                            ? client?.imageURL(for: item, kind: .primary, maxWidth: 1600)
                            : client?.imageURL(for: item, kind: .backdrop, maxWidth: 2560)
                                ?? client?.imageURL(for: item, kind: .primary, maxWidth: 1600),
                        placeholderSymbol: "film"
                    )
                    // 底部压暗保证文字可读；左侧再加一层横向渐变，Logo 与简介落在亮背景上也清晰。
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.7), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .center)
                }
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 48) {
                    infoColumn.frame(maxWidth: .infinity, alignment: .leading)
                    actions.frame(width: layout == .expanded ? 460 : 340)
                }
                .velaPageMargin()
                .padding(.bottom, VelaTheme.Spacing.xl)
            }
            .foregroundStyle(.white)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            if let logo = client?.logoURL(for: item, maxWidth: 1000) {
                CachedImage(url: logo, contentMode: .fit) { titleText }
                    .frame(maxWidth: 520, maxHeight: 180, alignment: .bottomLeading)
                    .accessibilityLabel(item.seriesName ?? item.name)
            } else {
                titleText
            }
            if let subtitle = episodeTitle {
                Text(subtitle).font(.title3.weight(.semibold))
            }
            Text(metadataLine)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            if let overview = item.overview, !overview.isEmpty {
                ExpandableText(text: overview, collapsedLines: 2)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var titleText: some View {
        Text(item.seriesName ?? item.name)
            .font(.system(size: 52, weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
    }

    private var episodeTitle: String? {
        switch item.kind {
        case .episode:
            guard let episode = item.indexNumber else { return item.name }
            return [item.parentIndexNumber.map { "第 \($0) 季" }, "第 \(episode) 集", item.name].compactMap { $0 }.joined(separator: " · ")
        case .season:
            return item.name
        default:
            return nil
        }
    }

    /// 「2026-10-04 · 剧情, 家庭 · 46 分钟 · 连载中」。
    private var metadataLine: String {
        var parts: [String] = []
        if let date = item.premiereDate {
            parts.append(date.formatted(.iso8601.year().month().day()))
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        if item.kind != .episode, !item.genres.isEmpty {
            parts.append(item.genres.prefix(4).joined(separator: ", "))
        }
        if let runtime = MediaFormat.runtime(item.runTimeTicks) { parts.append(runtime) }
        if item.kind == .series, let status = details?.seriesStatus {
            parts.append(status == "Ended" ? "已完结" : "连载中")
        }
        return parts.joined(separator: " · ")
    }
}

/// 宽屏头图右侧的大播放按钮：白底，续播时只有已播部分为白色（与 iPhone 版一致），标题下一行写集数与位置。
struct WidePlayButtonLabel: View {
    let title: String
    let subtitle: String?
    let progress: Double?

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            Image(systemName: "play.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).opacity(0.75)
                }
            }
        }
        .foregroundStyle(.white)
        .blendMode(.difference)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.18)
                    Color.white.frame(width: proxy.size.width * (progress ?? 1))
                }
            }
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// 评分行：社区评分 + 分级。
struct WideRatingRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            if let score = item.communityRating {
                Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.multicolor)
            }
            if let rating = item.officialRating {
                Text(rating)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.7)))
            }
        }
        .font(.headline)
    }
}

// MARK: - 季与单集

/// 页内的季与单集：季标题即下拉菜单；单集为 16:9 大卡横滑，超过 30 集按区间分段，右侧「→|」跳到最新一集。
struct SeasonEpisodesSection: View {
    @Bindable var model: DetailModel
    let client: MediaServerClient?
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.velaLayout) private var layout
    @State private var rangeIndex = 0
    @State private var scrollTarget: String?

    /// 每段集数（与 Forward 一致）。
    private static let pageSize = 30
    private static let cardSpacing: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            seasonMenu.velaPageMargin()
            switch model.seasonEpisodes {
            case .loaded(let episodes):
                if episodes.isEmpty {
                    Text("本季暂无单集").foregroundStyle(.secondary).velaPageMargin()
                } else {
                    episodeRow(episodes)
                    if episodes.count > Self.pageSize {
                        rangeBar(episodes)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).velaPageMargin()
            default:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: model.selectedSeasonID) {
            guard let client, model.selectedSeasonID != nil else { return }
            await model.loadSeasonEpisodes(client: client)
            if let episodes = model.seasonEpisodes.value { focus(initialEpisode(in: episodes), in: episodes) }
        }
    }

    private var selectedSeason: MediaItem? {
        model.seasons.first { $0.id == model.selectedSeasonID }
    }

    @ViewBuilder
    private var seasonMenu: some View {
        if model.seasons.count > 1 {
            Menu {
                ForEach(model.seasons) { season in
                    Toggle(isOn: Binding(
                        get: { model.selectedSeasonID == season.id },
                        set: { if $0 { model.selectedSeasonID = season.id } }
                    )) { Text(season.name) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedSeason?.name ?? "选择季")
                    Image(systemName: "chevron.down").font(.subheadline.weight(.bold))
                }
                .font(.title2.weight(.bold))
                .contentShape(.rect)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("选择季")
        } else {
            Text(selectedSeason?.name ?? "剧集").font(.title2.weight(.bold))
        }
    }

    private func episodeRow(_ episodes: [MediaItem]) -> some View {
        let page = episodes[pageRange(rangeIndex, total: episodes.count)]
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                ForEach(page) { episode in
                    NavigationLink(value: episode) {
                        WideEpisodeCard(
                            episode: episode,
                            imageURL: app.imageURL(for: episode, kind: .primary, maxWidth: 720),
                            isCurrent: episode.id == model.nextUp?.id
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("播放", systemImage: "play.fill") { playMedia(.item(episode)) }
                    }
                    .containerRelativeFrame(.horizontal, count: layout.visibleEpisodeCards, spacing: Self.cardSpacing)
                    .id(episode.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, layout.pageMargin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollTarget, anchor: .leading)
    }

    private func rangeBar(_ episodes: [MediaItem]) -> some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            ScrollView(.horizontal) {
                HStack(spacing: VelaTheme.Spacing.s) {
                    ForEach(0..<pageCount(episodes.count), id: \.self) { index in
                        let range = pageRange(index, total: episodes.count)
                        Button {
                            rangeIndex = index
                            scrollTarget = episodes[range].first?.id
                        } label: {
                            Text("\(label(episodes[range.lowerBound])) · \(label(episodes[range.upperBound - 1]))")
                                .font(.headline.monospacedDigit())
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(index == rangeIndex ? Color.black.opacity(0.75) : Color.white.opacity(0.08), in: .capsule)
                                .foregroundStyle(index == rangeIndex ? .white : .white.opacity(0.6))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button("跳到最新一集", systemImage: "arrow.right.to.line") {
                focus(latestEpisode(in: episodes), in: episodes)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
        }
        .velaPageMargin()
    }

    /// 区间标签用集号（缺失时用序号），与 Forward 的「1 · 30」一致。
    private func label(_ episode: MediaItem) -> String {
        episode.indexNumber.map(String.init) ?? "–"
    }

    /// 初始定位：下一集在本季时定位到它，否则第一个未看完的单集。
    private func initialEpisode(in episodes: [MediaItem]) -> MediaItem? {
        if let next = model.nextUp, let match = episodes.first(where: { $0.id == next.id }) { return match }
        return episodes.first { !$0.isPlayed } ?? episodes.first
    }

    /// 最新一集：已播出（首播日期不晚于今天）的最后一集；没有日期信息时取最后一集。
    private func latestEpisode(in episodes: [MediaItem]) -> MediaItem? {
        let now = Date()
        return episodes.last { ($0.premiereDate ?? .distantPast) <= now } ?? episodes.last
    }

    private func focus(_ episode: MediaItem?, in episodes: [MediaItem]) {
        guard let episode, let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        rangeIndex = index / Self.pageSize
        // 等新区间的卡片布局完成后再滚动，否则目标 id 尚不存在。
        Task { @MainActor in scrollTarget = episode.id }
    }

    private func pageCount(_ total: Int) -> Int { (total + Self.pageSize - 1) / Self.pageSize }

    private func pageRange(_ index: Int, total: Int) -> Range<Int> {
        let start = min(index * Self.pageSize, total)
        return start..<min(start + Self.pageSize, total)
    }
}

/// 16:9 单集卡：缩略图（进度条、已看标记，当前集描边）+ 日期、「第 N 集 · 时长」、标题、两行简介。
private struct WideEpisodeCard: View {
    let episode: MediaItem
    let imageURL: URL?
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteArtwork(url: imageURL, placeholderSymbol: "play.rectangle")
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if let fraction = episode.playedFraction {
                        GeometryReader { proxy in
                            Rectangle().fill(VelaTheme.accent).frame(width: proxy.size.width * fraction, height: 4)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: VelaTheme.Radius.card).stroke(.white, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) { PlayedMark(played: episode.isPlayed) }
                .velaCardHover()
                .padding(.bottom, 6)
            if let date = episode.premiereDate {
                Text(date.formatted(.iso8601.year().month().day()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text([episode.indexNumber.map { "第 \($0) 集" }, MediaFormat.runtime(episode.runTimeTicks)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(episode.name).font(.title3.weight(.semibold)).lineLimit(1)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 团队

/// 圆形头像的演职人员（导演、编剧排在演员前，与 Forward 一致）；无头像时显示姓名首字。
struct WideCastShelf: View {
    let people: [ItemDetails.Person]
    let client: MediaServerClient?
    let serverID: String

    private var ordered: [ItemDetails.Person] {
        let rank: (ItemDetails.Person) -> Int = { person in
            switch person.type {
            case "Director": 0
            case "Writer": 1
            default: 2
            }
        }
        return Array(people.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element).prefix(40))
    }

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                Text("演职人员").font(.title2.weight(.bold)).velaPageMargin()
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.l) {
                        ForEach(ordered) { person in
                            NavigationLink(value: PersonRoute(serverID: serverID, person: person)) {
                                PersonAvatar(person: person, url: client?.personImageURL(person, maxWidth: 300))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .velaPageMargin()
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct PersonAvatar: View {
    let person: ItemDetails.Person
    let url: URL?

    private let diameter: CGFloat = 120

    var body: some View {
        VStack(spacing: 4) {
            CachedImage(url: url) {
                ZStack {
                    Circle().fill(.white.opacity(0.08))
                    Text(person.name.prefix(1)).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(.circle)
            .overlay(Circle().stroke(.white.opacity(0.12)))
            Text(person.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(person.role.flatMap { $0.isEmpty ? nil : $0 } ?? CastShelf.typeName(person.type))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: diameter + 16)
        .accessibilityElement(children: .combine)
        .contentShape(.rect)
    }
}

// MARK: - 媒体信息

/// 可折叠的媒体信息：视频 / 音频 / 字幕三列卡片，键值两列对齐；底部为入库时间。
struct WideMediaInfoSection: View {
    let details: ItemDetails
    let source: MediaSourceInfo
    @State private var expanded = Self.initiallyExpanded

    /// 默认折叠；Debug 构建以 `VELA_DEBUG_DETAIL_ANCHOR=media` 启动时展开，便于截图验收。
    private static var initiallyExpanded: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["VELA_DEBUG_DETAIL_ANCHOR"] == "media"
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: VelaTheme.Spacing.l) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Label(expanded ? "收起媒体信息" : "展开媒体信息", systemImage: expanded ? "chevron.up.circle" : "chevron.down.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(alignment: .top, spacing: VelaTheme.Spacing.l) {
                        ForEach(["Video", "Audio", "Subtitle"], id: \.self) { type in
                            let streams = source.mediaStreams.filter { $0.type == type }
                            if !streams.isEmpty {
                                column(streams)
                            }
                        }
                    }
                    if let added = details.dateCreated {
                        Text("入库时间  " + added.formatted(date: .long, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .transition(.opacity)
            }
        }
        .velaPageMargin()
    }

    /// 文件路径、容器、大小、码率。
    private var summary: String {
        [
            source.path ?? details.path,
            [source.container?.uppercased(), MediaFormat.size(source.size), MediaFormat.bitrate(source.bitrate)]
                .compactMap { $0 }.joined(separator: "  ")
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func column(_ streams: [MediaStreamInfo]) -> some View {
        let header = StreamCard(stream: streams[0])
        return VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            Label(header.title, systemImage: header.symbol).font(.title3.weight(.semibold))
            ForEach(Array(streams.enumerated()), id: \.element.index) { offset, stream in
                if offset > 0 { Divider() }
                Grid(alignment: .leading, horizontalSpacing: VelaTheme.Spacing.l, verticalSpacing: 6) {
                    ForEach(StreamCard(stream: stream).rows, id: \.0) { key, value in
                        GridRow {
                            Text(key).foregroundStyle(.secondary)
                            Text(value).lineLimit(2)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(VelaTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: VelaTheme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: VelaTheme.Radius.panel).stroke(.white.opacity(0.08)))
    }
}

// MARK: - 播放资源

/// 宽屏的播放资源区（参考 Forward）：版本按清晰度分组为胶囊，每个版本一张资源卡（动态范围、大小、码率、来源服务器），
/// 右侧「线路」切换服务器线路（多条线路时显示），下方选择音轨与字幕。选择结果随播放请求传给播放器，与 iPhone 版一致。
struct WideSourceSection: View {
    @Bindable var model: DetailModel
    @Environment(AppModel.self) private var app
    @State private var selectedGroup: String?

    /// 清晰度分组：4K / 1080p / 720p …，无法识别分辨率的归入「其他」；保持版本原有顺序。
    private var groups: [(name: String, options: [DetailModel.SourceOption])] {
        var result: [(name: String, options: [DetailModel.SourceOption])] = []
        for option in model.sourceOptions {
            let name = MediaFormat.resolution(option.source.videoStream) ?? "其他"
            if let index = result.firstIndex(where: { $0.name == name }) {
                result[index].options.append(option)
            } else {
                result.append((name, [option]))
            }
        }
        return result
    }

    /// 当前显示的分组：用户点选的分组，否则为已选版本所在的分组。
    private var currentGroup: String? {
        selectedGroup ?? groups.first { group in group.options.contains { $0.id == model.selectedSource?.id } }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            HStack(spacing: VelaTheme.Spacing.m) {
                Text("播放资源").font(.title2.weight(.bold))
                if groups.count > 1 {
                    ForEach(groups, id: \.name) { group in
                        Button { selectedGroup = group.name } label: {
                            Text(group.name)
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(group.name == currentGroup ? Color.white.opacity(0.2) : Color.white.opacity(0.06), in: .capsule)
                                .foregroundStyle(group.name == currentGroup ? .primary : .secondary)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
                lineMenu
            }
            .velaPageMargin()

            ScrollView(.horizontal) {
                HStack(spacing: VelaTheme.Spacing.m) {
                    ForEach(groups.first { $0.name == currentGroup }?.options ?? []) { option in
                        Button { select(option.id) } label: {
                            SourceCard(option: option, serverName: serverName(option.item.serverID), isSelected: option.id == model.selectedSource?.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .velaPageMargin()
            }
            .scrollIndicators(.hidden)

            if let source = model.selectedSource {
                HStack(spacing: VelaTheme.Spacing.xl) {
                    if !source.audioStreams.isEmpty {
                        trackMenu(icon: "music.note") {
                            TrackSelectionMenu(title: "音轨", streams: source.audioStreams, selection: $model.selectedAudioIndex)
                        }
                    }
                    if !source.subtitleStreams.isEmpty {
                        trackMenu(icon: "captions.bubble") {
                            TrackSelectionMenu(title: "字幕", streams: source.subtitleStreams, selection: $model.selectedSubtitleIndex, offValue: -1)
                        }
                    }
                }
                .velaPageMargin()
            }
        }
    }

    private func trackMenu<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: VelaTheme.Spacing.s) {
            Image(systemName: icon).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, VelaTheme.Spacing.m)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
    }

    /// 「线路」：当前条目所在服务器有多条线路时可手动切换（与首页顶栏的线路菜单相同）。
    @ViewBuilder
    private var lineMenu: some View {
        if let server = app.servers.servers.first(where: { $0.id == model.item.serverID }), server.lines.count > 1 {
            Menu {
                Picker("线路", selection: Binding(
                    get: { server.activeLine.id },
                    set: { app.lineRouter.switchManually(serverID: server.id, lineID: $0) }
                )) {
                    ForEach(server.lines) { Text(LineRouting.displayName(of: $0)).tag($0.id) }
                }
            } label: {
                Text("线路")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: .capsule)
                    .overlay(Capsule().stroke(.white.opacity(0.15)))
                    .contentShape(.capsule)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    private func serverName(_ serverID: String) -> String? {
        app.servers.servers.first { $0.id == serverID }?.displayName
    }

    private func select(_ id: String) {
        guard id != model.selectedSourceID else { return }
        model.selectedSourceID = id
        model.resetSelections()
    }
}

/// 资源卡：标题为动态范围（无标记时为分辨率 + 编码），下面是大小、码率、来源服务器，选中时右下角打勾。
private struct SourceCard: View {
    let option: DetailModel.SourceOption
    let serverName: String?
    let isSelected: Bool

    private var title: String {
        let video = option.source.videoStream
        if let video, let range = PlayerSession.dynamicRangeLabel(for: video), range != "SDR" { return range }
        return [MediaFormat.resolution(video), video?.codec?.uppercased()].compactMap { $0 }.joined(separator: " ")
            .nonEmpty ?? (option.source.name ?? "默认版本")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text(title).font(.title3.weight(.bold)).lineLimit(1)
            HStack(spacing: VelaTheme.Spacing.m) {
                if let size = MediaFormat.size(option.source.size) {
                    Label(size, systemImage: "internaldrive")
                }
                if let bitrate = MediaFormat.bitrate(option.source.bitrate) {
                    Label(bitrate, systemImage: "speedometer")
                }
            }
            .font(.subheadline.weight(.medium))
            HStack {
                if let serverName {
                    Label(serverName, systemImage: "server.rack").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: VelaTheme.Spacing.s)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .green : .secondary)
            }
        }
        .padding(VelaTheme.Spacing.l)
        .frame(width: 300, alignment: .leading)
        .background(.white.opacity(isSelected ? 0.12 : 0.06), in: .rect(cornerRadius: VelaTheme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: VelaTheme.Radius.panel).stroke(.white.opacity(isSelected ? 0.6 : 0.1), lineWidth: isSelected ? 1.5 : 1))
        .contentShape(.rect(cornerRadius: VelaTheme.Radius.panel))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 剧照

/// 剧照：条目的全部背景图，16:9 大图横滑（一屏约 2.5 张）。只有一张时与头图重复，不显示。
struct StillsShelf: View {
    let urls: [URL]
    @Environment(\.velaLayout) private var layout

    var body: some View {
        if urls.count > 1 {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                Text("剧照").font(.title2.weight(.bold)).velaPageMargin()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: VelaTheme.Spacing.l) {
                        ForEach(urls, id: \.self) { url in
                            RemoteArtwork(url: url, placeholderSymbol: "photo")
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                                .containerRelativeFrame(.horizontal, count: layout == .expanded ? 5 : 4, span: 2, spacing: VelaTheme.Spacing.l)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, layout.pageMargin, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}
