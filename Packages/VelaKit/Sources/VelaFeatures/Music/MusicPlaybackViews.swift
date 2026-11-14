import SwiftUI

enum MusicPlayerPanel: String, Identifiable {
    case playing, queue, lyrics
    var id: Self { self }
}

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

struct MusicPlaybackSheet: View {
    let initialPanel: MusicPlayerPanel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: MusicPlayerPanel?
    @State private var scrub: TimeInterval?
    @State private var cloudBusy = false
    @State private var cloudMessage: String?
    @State private var confirmQueueUpload = false
    @State private var confirmQueueRestore = false

    private var panel: MusicPlayerPanel { selected ?? initialPanel }

    var body: some View {
        NavigationStack {
            Group {
                switch panel {
                case .playing: player
                case .queue: queue
                case .lyrics: lyrics
                }
            }
            .navigationTitle(panel == .queue ? "播放队列" : panel == .lyrics ? "歌词" : "正在播放")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selected = panel == .queue ? .playing : .queue
                    } label: {
                        Label(panel == .queue ? "正在播放" : "播放队列",
                              systemImage: panel == .queue ? "music.note" : "list.bullet")
                    }
                }
                if panel == .queue, let source = app.music.source, !app.music.isRadio, !source.isPrivate {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("服务器队列", systemImage: "arrow.trianglehead.clockwise") {
                            Button("保存到服务器") { confirmQueueUpload = true }
                            Button("恢复服务器队列") { confirmQueueRestore = true }
                        }
                        .disabled(cloudBusy)
                    }
                }
            }
        }
        .onChange(of: app.music.index) { _, _ in
            scrub = nil
        }
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
        #if os(macOS)
        .frame(minWidth: 515, minHeight: 540)
        #endif
    }

    @ViewBuilder private var player: some View {
        if let track = app.music.current, let source = app.music.source {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MusicCover(source: source, id: track.coverArt, size: 650, radius: 20)
                        .frame(maxWidth: 340)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title).font(.title.bold()).lineLimit(2)
                        Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                    VStack(spacing: 5) {
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
                    controls
                    if !app.music.isRadio {
                        HStack {
                            Button("歌词", systemImage: "quote.bubble") { selected = .lyrics }
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Label(app.music.compatible ? "兼容转码" : "原始音频", systemImage: "waveform")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !app.music.compatible {
                                Button("改用兼容转码") { app.music.retryCompatible() }.font(.caption)
                            } else {
                                Button("改用原始音频") { app.music.retryOriginal() }.font(.caption)
                            }
                        }
                    }
                    if let error = app.music.playbackError { MusicLoadError(message: error) { app.music.play() } }
                }
                .frame(maxWidth: 470)
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity)
            }
        }
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

    @ViewBuilder private var lyrics: some View {
        if let track = app.music.current, let source = app.music.source {
            VStack(spacing: 8) {
                MusicLyricsView(source: source, track: track, session: app.music).id(track.id)
                VStack(spacing: 0) {
                    scrubber
                    HStack {
                        Button("封面", systemImage: "square") { selected = .playing }
                        Spacer()
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Button(app.music.wantsPlayback ? "暂停" : "播放",
                               systemImage: app.music.wantsPlayback ? "pause.fill" : "play.fill") { app.music.toggle() }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 22).padding(.bottom, 12)
            }
        }
    }

    private var scrubber: some View {
        let duration = app.music.duration
        let position = scrub ?? app.music.position
        let progress = duration > 0 ? min(1, max(0, position / duration)) : 0
        return GeometryReader { geometry in
            let width = geometry.size.width - 14
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: max(0, width * progress + 7), height: 4)
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
                    .foregroundStyle(.white)
                    .frame(width: 69, height: 69)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(app.music.wantsPlayback ? "暂停" : "播放")
            Spacer(minLength: 1)
            control("forward.end.fill", "下一首", size: 24) { app.music.next() }.disabled(!app.music.canSkipNext)
            Spacer(minLength: 1)
            control("list.bullet", "播放队列", size: 19) { selected = .queue }
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
