import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

struct MusicMiniPlayer: View {
    @Environment(AppModel.self) private var app
    let onOpen: () -> Void
    let onQueue: () -> Void

    var body: some View {
        if let track = app.music.current, let source = app.music.source {
            VStack(spacing: 0) {
                ProgressView(value: app.music.position, total: max(1, app.music.duration))
                    .progressViewStyle(.linear)
                    .scaleEffect(y: 0.5)
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Button(action: onOpen) {
                        HStack(spacing: 9) {
                            MusicCover(source: source, id: track.coverArt, size: 144, radius: 6).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(app.music.playbackError == nil ? track.artist ?? "正在播放" : "播放失败")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 43)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("music.mini.open")
                    Button { app.music.toggle() } label: {
                        Image(systemName: app.music.wantsPlayback ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .frame(width: 42, height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(app.music.wantsPlayback ? "暂停" : "播放")
                    Button(action: onQueue) {
                        Image(systemName: "list.bullet").font(.headline)
                            .frame(width: 42, height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放队列")
                    .accessibilityIdentifier("music.mini.queue")
                }
                .padding(.leading, 10)
                .padding(.trailing, 5)
            }
        }
    }
}

struct MusicPlaybackPage: View {
    let onClose: () -> Void
    let onQueue: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Page? = .cover
    @State private var scrub: TimeInterval?

    // 声明顺序同时用于页面和顶部圆点，从左到右为推荐、封面、歌词。
    private enum Page: CaseIterable, Hashable {
        case recommendations, cover, lyrics

        var title: String {
            switch self {
            case .recommendations: "推荐"
            case .cover: "封面"
            case .lyrics: "歌词"
            }
        }
    }

    private var currentPage: Page { page ?? .cover }

    var body: some View {
        NavigationStack {
            if let track = app.music.current, let source = app.music.source {
                let isRadio = app.music.isRadio
                VStack(spacing: 8) {
                    header(isRadio: isRadio)
                    GeometryReader { proxy in
                        if isRadio { cover(track, source: source) }
                        else { pages(track, source: source, size: proxy.size) }
                    }
                    .clipped()
                    playbackBar(isRadio: isRadio)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    MusicArtworkBackdrop(source: source, coverArt: track.coverArt)
                        .ignoresSafeArea()
                }
                .navigationDestination(for: MusicRoute.self) { route in
                    MusicDetailPage(route: route, source: source)
                        #if os(iOS)
                        .toolbarVisibility(.visible, for: .navigationBar)
                        #endif
                }
                #if os(iOS)
                .toolbarVisibility(.hidden, for: .navigationBar)
                #endif
                .onChange(of: track.id) { _, _ in scrub = nil }
                .onChange(of: app.music.index) { _, _ in scrub = nil }
                .onChange(of: isRadio) { _, _ in page = .cover }
            }
        }
        .accessibilityAction(.escape) { onClose() }
    }

    private func header(isRadio: Bool) -> some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .foregroundStyle(.primary)
            }
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
                .accessibilityLabel("返回音乐库")
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            if !isRadio {
                Menu {
                    Button("原始音频", systemImage: app.music.compatible ? "waveform" : "checkmark") { app.music.retryOriginal() }
                        .disabled(!app.music.compatible)
                    Button("兼容转码", systemImage: app.music.compatible ? "checkmark" : "waveform.path") { app.music.retryCompatible() }
                        .disabled(app.music.compatible)
                } label: {
                    Image(systemName: "waveform").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("音频模式")
                .accessibilityValue(app.music.compatible ? "兼容转码" : "原始音频")
            }
        }
        .frame(minHeight: 44)
        .overlay {
            if isRadio {
                Text("网络电台").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            } else {
                HStack(spacing: 0) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy) { page = item }
                        } label: {
                            Capsule()
                                .fill(.primary.opacity(currentPage == item ? 1 : 0.45))
                                .frame(width: currentPage == item ? 18 : 6, height: 6)
                                .frame(width: 37, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(currentPage == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 4)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func pages(_ track: NavidromeTrack, source: MusicSource, size: CGSize) -> some View {
        #if os(iOS)
        TabView(selection: $page) {
            ForEach(Page.allCases, id: \.self) { item in
                pageContent(item, track: track, source: source)
                    .tag(Optional(item))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: size.width, height: size.height)
        #else
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Page.allCases, id: \.self) { item in
                    pageContent(item, track: track, source: source)
                        .frame(width: size.width, height: size.height)
                        .id(item)
                }
            }
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.center, for: .initialOffset)
        .scrollPosition(id: $page, anchor: .center)
        .scrollTargetBehavior(.paging)
        .velaHideHorizontalScrollIndicators()
        #endif
    }

    private func pageContent(_ item: Page, track: NavidromeTrack, source: MusicSource) -> some View {
        Group {
            switch item {
            case .lyrics:
                VStack(spacing: 12) {
                    MusicPlayingTitle(track: track).padding(.horizontal, 24)
                    MusicLyricsView(source: source, track: track, session: app.music, isActive: currentPage == .lyrics)
                        .id(track.id)
                }
                .frame(maxWidth: 660, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            case .cover:
                cover(track, source: source)
            case .recommendations:
                MusicPlayerRecommendations(source: source, track: track, isActive: currentPage == .recommendations)
                    .id(track.id)
            }
        }
        .accessibilityHidden(currentPage != item)
    }

    private func cover(_ track: NavidromeTrack, source: MusicSource) -> some View {
        GeometryReader { proxy in
            let side = max(110, min(proxy.size.width - 58, proxy.size.height - 115, 375))
            ScrollView {
                VStack(spacing: 26) {
                    MusicCover(source: source, id: track.coverArt, size: 650, radius: 22)
                        .frame(width: side)
                        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.20)) }
                        .shadow(color: .black.opacity(0.26), radius: 22, x: 0, y: 12)
                    MusicPlayingTitle(track: track)
                    if let error = app.music.playbackError {
                        MusicLoadError(message: error) { app.music.play() }
                    }
                }
                .padding(.vertical, 18)
                .frame(maxWidth: 460, minHeight: proxy.size.height)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func playbackBar(isRadio: Bool) -> some View {
        VStack(spacing: 10) {
            if !isRadio {
                VStack(spacing: 0) {
                    scrubber
                    HStack {
                        Text(musicTime(scrub ?? app.music.position))
                        Spacer()
                        Text(musicTime(app.music.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if !app.music.canSeek, app.music.compatible {
                        Text("当前转码流不支持跳转").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            controls
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        let duration = app.music.duration
        let position = scrub ?? app.music.position
        let progress = duration > 0 ? min(1, max(0, position / duration)) : 0
        return GeometryReader { geometry in
            let width = geometry.size.width - 14
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(VelaTheme.accent).frame(width: max(0, width * progress + 7), height: 4)
                Circle().fill(.primary).frame(width: 14, height: 14).offset(x: width * progress)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard app.music.canSeek, width > 0 else { return }
                    scrub = duration * min(1, max(0, (value.location.x - 7) / width))
                }
                .onEnded { value in
                    guard app.music.canSeek, width > 0 else { scrub = nil; return }
                    app.music.seek(to: duration * min(1, max(0, (value.location.x - 7) / width)))
                    scrub = nil
                })
        }
        .frame(height: 32)
        .opacity(app.music.canSeek ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(musicTime(position)) / \(musicTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: app.music.seek(to: position + 10)
            case .decrement: app.music.seek(to: position - 10)
            @unknown default: break
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            control(app.music.mode.symbol, app.music.mode.title, size: 19) { app.music.cycleMode() }
            Spacer(minLength: 1)
            control("backward.end.fill", "上一首", size: 24) { app.music.previous() }
            Spacer(minLength: 1)
            Button { app.music.toggle() } label: {
                Image(systemName: app.music.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.primary)
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityLabel(app.music.wantsPlayback ? "暂停" : "播放")
            Spacer(minLength: 1)
            control("forward.end.fill", "下一首", size: 24) { app.music.next() }.disabled(!app.music.canSkipNext)
            Spacer(minLength: 1)
            control("list.bullet", "播放队列", size: 19, action: onQueue)
        }
    }

    private func control(_ icon: String, _ title: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct MusicPlayingTitle: View {
    let track: NavidromeTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(track.title)
                .font(.title2.bold())
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            let subtitle = [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }
            if !subtitle.isEmpty {
                Text(subtitle.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MusicArtworkBackdrop: View {
    let source: MusicSource
    let coverArt: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: CGImage?
    @State private var tone: BackdropTone.HSB?

    var body: some View {
        GeometryReader { proxy in
            let dark = colorScheme == .dark
            ZStack {
                Rectangle().fill(.background)
                if let tone {
                    let color = Color(hue: tone.hue, saturation: tone.saturation,
                                      brightness: dark ? tone.brightness : 0.95)
                    LinearGradient(colors: [color.opacity(dark ? 1 : 0.34), .clear], startPoint: .top, endPoint: .bottom)
                }
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .scaleEffect(1.15)
                        .blur(radius: 64)
                        .saturation(0.65)
                        .opacity(dark ? 0.23 : 0.19)
                }
                Rectangle().fill(.background)
                    .mask(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
            }
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: coverArt) {
            image = nil
            tone = nil
            guard let coverArt else { return }
            guard let artwork = await source.artwork(coverArt, size: 144), !Task.isCancelled else { return }
            image = artwork
            tone = BackdropTone.darkTone(for: artwork)
        }
    }
}

struct MusicQueueSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cloudBusy = false
    @State private var cloudMessage: String?
    @State private var confirmQueueUpload = false
    @State private var confirmQueueRestore = false

    var body: some View {
        NavigationStack {
            queue
                .navigationTitle("播放队列")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    if let source = app.music.source, !app.music.isRadio, !source.isPrivate {
                        ToolbarItem(placement: .primaryAction) {
                            Menu("服务器队列", systemImage: "arrow.trianglehead.clockwise") {
                                Button("保存到服务器") { confirmQueueUpload = true }
                                Button("恢复服务器队列") { confirmQueueRestore = true }
                            }
                            .disabled(cloudBusy)
                        }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 515, minHeight: 540)
        #endif
        .overlay {
            if scenePhase != .active, app.music.source?.isPrivate == true {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
        }
        .confirmationDialog("用本机队列覆盖服务器保存的队列？", isPresented: $confirmQueueUpload, titleVisibility: .visible) {
            Button("保存队列") { cloudQueue(save: true) }
        }
        .confirmationDialog("用服务器队列替换本机队列？", isPresented: $confirmQueueRestore, titleVisibility: .visible) {
            Button("恢复并播放") { cloudQueue(save: false) }
        }
        .alert("服务器队列", isPresented: Binding(get: { cloudMessage != nil }, set: { if !$0 { cloudMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(cloudMessage ?? "") }
    }

    private func cloudQueue(save: Bool) {
        guard let source = app.music.source else { return }
        let indexed = source.capabilities.supports("indexBasedQueue")
        let form = source.capabilities.supports("formPost")
        let queue = app.music.queue.map(\.id)
        let index = app.music.index ?? 0
        let position = app.music.position
        cloudBusy = true
        Task {
            defer { cloudBusy = false }
            do {
                if save {
                    try await source.client.saveQueue(ids: queue, currentIndex: index, position: position, indexed: indexed, form: form)
                    cloudMessage = "已保存当前队列与播放位置。"
                } else if let remote = try await source.client.savedQueue(indexed: indexed), let songs = remote.entry, !songs.isEmpty {
                    app.playMusic(songs, at: remote.selectedIndex, from: source, position: Double(remote.position ?? 0) / 1000)
                } else {
                    cloudMessage = "服务器上没有已保存的队列。"
                }
            } catch { cloudMessage = error.localizedDescription }
        }
    }

    @ViewBuilder private var queue: some View {
        if let source = app.music.source, let currentIndex = app.music.index {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("\(app.music.queue.count) 首 · \(app.music.mode.title)")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                        ForEach(app.music.queue.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                Button { app.music.play(at: index) } label: {
                                    MusicTrackLabel(track: app.music.queue[index], source: source, playing: index == currentIndex)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("music.queue.\(index)")
                                if index > currentIndex {
                                    Button("从队列移除", systemImage: "minus.circle") { app.music.removeUpcoming(at: index) }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, height: 38)
                                }
                            }
                            .padding(.horizontal, 16)
                            .id(index)
                            Divider().padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.top)
                .onAppear { reader.scrollTo(currentIndex, anchor: .center) }
            }
        }
    }
}
