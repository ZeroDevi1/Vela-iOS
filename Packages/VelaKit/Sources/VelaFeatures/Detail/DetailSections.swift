import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

// MARK: - 播放源选择

/// 版本 / 音轨 / 字幕选择卡片。选择结果随播放请求传给播放器。
struct SourceSelectionCard: View {
    @Bindable var model: DetailModel
    let details: ItemDetails

    var body: some View {
        if let source = model.selectedSource {
            VStack(alignment: .leading, spacing: 0) {
                row(icon: "play.rectangle.on.rectangle") {
                    if details.mediaSources.count > 1 {
                        Picker("版本", selection: $model.selectedSourceID) {
                            ForEach(details.mediaSources) { source in
                                Text(source.name ?? MediaFormat.sourceSummary(source)).tag(Optional(source.id))
                            }
                        }
                        .onChange(of: model.selectedSourceID) { model.resetSelections() }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name ?? model.item.name).lineLimit(1)
                            Text(MediaFormat.sourceSummary(source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !source.audioStreams.isEmpty {
                    Divider().padding(.leading, 44)
                    row(icon: "music.note") {
                        Picker("音轨", selection: $model.selectedAudioIndex) {
                            ForEach(source.audioStreams, id: \.index) { stream in
                                Text(stream.displayTitle ?? stream.language ?? "音轨 \(stream.index)").tag(Optional(stream.index))
                            }
                        }
                    }
                }
                if !source.subtitleStreams.isEmpty {
                    Divider().padding(.leading, 44)
                    row(icon: "captions.bubble") {
                        Picker("字幕", selection: $model.selectedSubtitleIndex) {
                            Text("关闭").tag(Optional(-1))
                            ForEach(source.subtitleStreams, id: \.index) { stream in
                                let title = stream.displayTitle ?? stream.language ?? "字幕 \(stream.index)"
                                Text(stream.isTextSubtitle ? title : "\(title)（需转码）").tag(Optional(stream.index))
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .rect(cornerRadius: VelaTheme.Radius.panel))
        }
    }

    private func row<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VelaTheme.Spacing.m)
        .padding(.vertical, 10)
    }
}

// MARK: - 单集

/// 横向单集列表，自动滚动到当前集。
struct EpisodeShelf: View {
    let title: String
    let episodes: [MediaItem]
    let currentID: String
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(episodes) { episode in
                            NavigationLink(value: episode) {
                                LandscapeCard(
                                    title: "\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)",
                                    subtitle: MediaFormat.runtime(episode.runTimeTicks),
                                    imageURL: app.imageURL(for: episode, kind: .primary, maxWidth: 480),
                                    progress: episode.playedFraction,
                                    width: isCompact ? 220 : 280
                                )
                                .overlay(alignment: .topLeading) {
                                    if episode.id == currentID {
                                        RoundedRectangle(cornerRadius: VelaTheme.Radius.card)
                                            .stroke(.white, lineWidth: 2)
                                            .frame(height: (isCompact ? 220 : 280) * 9 / 16)
                                    }
                                }
                                .overlay(alignment: .topTrailing) { PlayedMark(played: episode.isPlayed) }
                            }
                            .buttonStyle(.plain)
                            .id(episode.id)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
    }
}

struct PlayedMark: View {
    let played: Bool

    var body: some View {
        if played {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, VelaTheme.accentDeep)
                .font(.title3)
                .padding(6)
                .accessibilityLabel("已看")
        }
    }
}

/// 季页面：单集超过 50 集时按区间分页（例如 1-50、51-100），避免长篇番剧一次渲染上千行。
struct SeasonDetailView: View {
    let route: SeasonRoute
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var episodes: LoadState<[MediaItem]> = .idle
    @State private var rangeIndex = 0

    private static let pageSize = 50

    var body: some View {
        List {
            switch episodes {
            case .loaded(let all):
                if all.count > Self.pageSize {
                    Section {
                        ScrollView(.horizontal) {
                            HStack(spacing: VelaTheme.Spacing.s) {
                                ForEach(0..<pageCount(all), id: \.self) { index in
                                    let range = pageRange(index, total: all.count)
                                    Button("\(range.lowerBound + 1)-\(range.upperBound)") { rangeIndex = index }
                                        .buttonStyle(.glass)
                                        .tint(index == rangeIndex ? VelaTheme.accent : nil)
                                        .fontWeight(index == rangeIndex ? .bold : .regular)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(all[pageRange(rangeIndex, total: all.count)]) { episode in
                        NavigationLink(value: episode) { EpisodeRow(episode: episode) }
                            .swipeActions(edge: .leading) {
                                Button("播放", systemImage: "play.fill") { playMedia(.item(episode)) }.tint(VelaTheme.accentDeep)
                            }
                    }
                }
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("\(route.series.name) · \(route.season.name)")
        .task { await load() }
    }

    private func pageCount(_ items: [MediaItem]) -> Int { (items.count + Self.pageSize - 1) / Self.pageSize }

    private func pageRange(_ index: Int, total: Int) -> Range<Int> {
        let start = min(index * Self.pageSize, total)
        return start..<min(start + Self.pageSize, total)
    }

    private func load() async {
        guard let client = app.client(forServerID: route.series.serverID) else { return }
        episodes = .loading
        let result = await capture { try await client.episodes(seriesID: route.series.id, seasonID: route.season.id) }
        episodes = LoadState(result)
        // 默认定位到第一个未看完的区间。
        if case .success(let all) = result, let firstUnplayed = all.firstIndex(where: { !$0.isPlayed }) {
            rangeIndex = firstUnplayed / Self.pageSize
        }
    }
}

private struct EpisodeRow: View {
    let episode: MediaItem
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
            RemoteArtwork(url: app.imageURL(for: episode, kind: .primary, maxWidth: 400), placeholderSymbol: "play.rectangle")
                .frame(width: 150, height: 84)
                .overlay(alignment: .bottom) {
                    if let fraction = episode.playedFraction {
                        ProgressView(value: fraction).tint(VelaTheme.accent).padding(4)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { PlayedMark(played: episode.isPlayed) }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)")
                    .font(.headline)
                    .lineLimit(2)
                if let runtime = MediaFormat.runtime(episode.runTimeTicks) {
                    Text(runtime).font(.caption).foregroundStyle(.secondary)
                }
                if let overview = episode.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 章节 / 演职员

struct ChapterShelf: View {
    let item: MediaItem
    let client: MediaServerClient?
    @Environment(\.playMedia) private var playMedia

    private var chapters: [(offset: Int, element: MediaChapter)] {
        Array(item.chapters.enumerated()).filter { $0.element.marker == .chapter }
    }

    var body: some View {
        if chapters.count > 1 {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("章节").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(chapters, id: \.offset) { index, chapter in
                            VStack(alignment: .leading, spacing: 4) {
                                RemoteArtwork(
                                    url: client?.chapterImageURL(itemID: item.id, index: index, chapter: chapter, maxWidth: 400),
                                    placeholderSymbol: "list.bullet.rectangle"
                                )
                                .frame(width: 200, height: 112)
                                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                                Text(chapter.name ?? "章节 \(index + 1)").font(.subheadline).lineLimit(1)
                                Text(Duration.seconds(chapter.start).formatted(.time(pattern: chapter.start >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 200, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct CastShelf: View {
    let people: [ItemDetails.Person]
    let client: MediaServerClient?

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("演职人员").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(people.prefix(40)) { person in
                            VStack(alignment: .leading, spacing: 2) {
                                RemoteArtwork(url: client?.personImageURL(person, maxWidth: 300), placeholderSymbol: "person.fill")
                                    .frame(width: 104, height: 138)
                                    .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                                Text(person.name).font(.subheadline).lineLimit(1)
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(Self.typeName(person.type)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(width: 104, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    static func typeName(_ type: String?) -> String {
        switch type {
        case "Actor": "演员"
        case "GuestStar": "客串"
        case "Director": "导演"
        case "Writer": "编剧"
        case "Producer": "制片"
        case "Composer": "作曲"
        default: type ?? ""
        }
    }
}

// MARK: - 媒体信息

struct MediaInfoSection: View {
    let details: ItemDetails
    let source: MediaSourceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            Text("媒体信息").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                    ForEach(source.mediaStreams, id: \.index) { stream in
                        StreamCard(stream: stream)
                    }
                }
                .padding(.horizontal, VelaTheme.Spacing.l)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 4) {
                if !details.studios.isEmpty {
                    Text(details.studios.joined(separator: " · "))
                }
                if let path = source.path ?? details.path {
                    Text(path).textSelection(.enabled)
                }
                Text([
                    source.container?.uppercased(),
                    MediaFormat.size(source.size),
                    MediaFormat.runtime(source.runTimeTicks ?? details.item.runTimeTicks),
                    details.dateCreated.map { "添加于 " + $0.formatted(date: .numeric, time: .shortened) }
                ].compactMap { $0 }.joined(separator: "  "))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(VelaTheme.Spacing.m)
            .glassEffect(.regular, in: .rect(cornerRadius: VelaTheme.Radius.panel))
            .padding(.horizontal, VelaTheme.Spacing.l)
        }
    }
}

private struct StreamCard: View {
    let stream: MediaStreamInfo

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Label(title, systemImage: symbol).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: VelaTheme.Spacing.m, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { key, value in
                    GridRow {
                        Text(key).foregroundStyle(.secondary)
                        Text(value).lineLimit(2)
                    }
                }
            }
            .font(.caption)
        }
        .padding(VelaTheme.Spacing.m)
        .frame(width: 260, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: VelaTheme.Radius.panel))
    }

    private var title: String {
        switch stream.type {
        case "Video": "视频"
        case "Audio": "音频"
        case "Subtitle": "字幕"
        default: stream.type
        }
    }

    private var symbol: String {
        switch stream.type {
        case "Video": "video"
        case "Audio": "speaker.wave.2"
        case "Subtitle": "captions.bubble"
        default: "doc"
        }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String?)] = [
            ("标题", stream.displayTitle),
            ("内嵌标题", stream.title),
            ("语言", stream.language),
            ("编码", stream.codec.map { [$0, stream.codecTag].compactMap { $0 }.joined(separator: " / ") })
        ]
        switch stream.type {
        case "Video":
            rows += [
                ("分辨率", stream.width.flatMap { w in stream.height.map { "\(w)x\($0)" } }),
                ("帧率", stream.realFrameRate.map { String(format: "%.3f", $0) }),
                ("码率", MediaFormat.bitrate(stream.bitRate)),
                ("动态范围", stream.videoRangeType),
                ("配置", stream.profile),
                ("等级", stream.level.map { String(format: "%.1f", $0) }),
                ("长宽比", stream.aspectRatio),
                ("位深", stream.bitDepth.map(String.init)),
                ("像素格式", stream.pixelFormat),
                ("隔行", stream.isInterlaced.map { $0 ? "是" : "否" })
            ]
        case "Audio":
            rows += [
                ("布局", stream.channelLayout),
                ("声道", stream.channels.map(String.init)),
                ("码率", MediaFormat.bitrate(stream.bitRate)),
                ("采样率", stream.sampleRate.map { "\($0) Hz" })
            ]
        default:
            rows += [("强制", stream.isForced.map { $0 ? "是" : "否" })]
        }
        rows += [
            ("外部", stream.isExternal.map { $0 ? "是" : "否" }),
            ("默认", stream.isDefault.map { $0 ? "是" : "否" })
        ]
        return rows.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } }
    }
}

// MARK: - 导航目的地

extension View {
    /// 注册详情相关的导航目的地。各标签页的 NavigationStack 统一调用，保证从任意入口进入的详情行为一致。
    func detailDestinations() -> some View {
        self
            .navigationDestination(for: MediaItem.self) { ItemDetailView(item: $0) }
            .navigationDestination(for: SeasonRoute.self) { SeasonDetailView(route: $0) }
    }
}
