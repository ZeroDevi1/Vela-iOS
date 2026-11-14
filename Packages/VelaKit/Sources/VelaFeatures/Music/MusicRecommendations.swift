import SwiftUI
import VelaNetwork

struct MusicPlayerRecommendations: View {
    let source: MusicSource
    let track: NavidromeTrack
    let isActive: Bool

    @State private var suggestions: Suggestions?
    @State private var retry = 0

    private struct Suggestions {
        let similar: [NavidromeTrack]
        let albumTracks: [NavidromeTrack]
        let artistAlbums: [MusicAlbum]
        let error: String?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                currentTrack
                if let suggestions {
                    if !suggestions.similar.isEmpty {
                        trackSection("相似歌曲", tracks: suggestions.similar)
                    }
                    if !suggestions.albumTracks.isEmpty {
                        trackSection("同专辑歌曲", tracks: suggestions.albumTracks)
                    }
                    if !suggestions.artistAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("同歌手专辑").font(.headline).padding(.horizontal, 16)
                            MusicAlbumGrid(albums: suggestions.artistAlbums, source: source)
                        }
                    }
                    if suggestions.similar.isEmpty, suggestions.albumTracks.isEmpty, suggestions.artistAlbums.isEmpty {
                        if let error = suggestions.error {
                            MusicLoadError(message: error) { retry += 1 }
                        } else {
                            ContentUnavailableView("暂无相关推荐", systemImage: "music.note.list")
                        }
                    }
                } else {
                    ProgressView("正在加载推荐").frame(maxWidth: .infinity, minHeight: 110)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
        }
        .task(id: isActive ? retry : nil) {
            guard isActive, suggestions == nil || suggestions?.error != nil else { return }
            await load()
        }
    }

    private var currentTrack: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: MusicRoute.track(track.id, track.title)) {
                HStack(spacing: 12) {
                    MusicCover(source: source, id: track.coverArt, size: 144).frame(width: 48)
                    Text(track.title).font(.title3.bold()).lineLimit(2).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开歌曲详情")
            if let artist = track.artist, let id = track.artistId {
                NavigationLink(value: MusicRoute.artist(id, artist)) {
                    Label(artist, systemImage: "person").lineLimit(1).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let album = track.album, let id = track.albumId {
                NavigationLink(value: MusicRoute.album(id, album)) {
                    Label(album, systemImage: "square.stack").lineLimit(1).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
    }

    private func trackSection(_ title: String, tracks: [NavidromeTrack]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 16)
            MusicTrackRows(tracks: tracks, source: source)
        }
    }

    private func load() async {
        suggestions = nil
        let client = source.client
        async let onAlbum: MusicAlbum? = if let id = track.albumId { try? await client.album(id) } else { nil }
        async let byArtist: MusicArtist? = if let id = track.artistId { try? await client.artist(id) } else { nil }
        var related: [NavidromeTrack] = []
        var failure: String?
        do {
            if source.capabilities.supports("sonicSimilarity") {
                related = (try? await client.sonicMatches(from: track.id, limit: 8)) ?? []
            }
            if related.allSatisfy({ $0.id == track.id }) {
                related = try await client.similarSongs(track.id, limit: 8)
            }
        } catch {
            failure = error.localizedDescription
        }
        let (album, artist) = await (onAlbum, byArtist)
        guard !Task.isCancelled else { return }
        var seen: Set<String> = [track.id]
        let similar = related.filter { seen.insert($0.id).inserted }
        let albumTracks = (album?.song ?? []).filter { seen.insert($0.id).inserted }.prefix(8)
        let artistAlbums = (artist?.album ?? []).filter { $0.id != track.albumId }.prefix(6)
        suggestions = Suggestions(similar: similar, albumTracks: Array(albumTracks), artistAlbums: Array(artistAlbums),
                                  error: similar.isEmpty && albumTracks.isEmpty && artistAlbums.isEmpty ? failure : nil)
    }
}

struct MusicMetadataSection: View {
    let source: MusicSource
    let id: String
    let isArtist: Bool
    var artistName: String?
    @State private var metadata: NavidromeMetadata?
    @State private var top: [NavidromeTrack] = []
    @State private var requested = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !requested || failure != nil {
                Button(isArtist ? "加载歌手资料与热门歌曲" : "加载专辑资料", systemImage: "info.circle") {
                    Task { await load() }
                }
                .disabled(loading).padding(.horizontal, 16)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if let text = metadata?.biography ?? metadata?.notes, !text.isEmpty {
                Text(text).font(.subheadline).textSelection(.enabled).padding(.horizontal, 16)
            }
            if let url = metadata?.lastFmUrl, let safe = musicWebURL(url.absoluteString) {
                Link("打开外部资料", destination: safe).padding(.horizontal, 16)
            }
            if let artists = metadata?.similarArtist, !artists.isEmpty {
                Text("相似歌手").font(.headline).padding(.horizontal, 16)
                ForEach(artists.filter { !$0.id.isEmpty && $0.id != "-1" }) { artist in
                    MusicArtistRow(artist: artist, source: source)
                }
            }
            if !top.isEmpty {
                Text("热门歌曲").font(.headline).padding(.horizontal, 16)
                MusicTrackRows(tracks: top, source: source)
            }
        }
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            if isArtist {
                let client = source.client
                let name = artistName ?? ""
                let key = source.capabilities.supports("topSongsByArtistId") ? id : nil
                async let profile = client.artistInfo(id)
                async let songs = try? client.topSongs(artist: name, id: key)
                metadata = try await profile
                top = await songs ?? []
            } else {
                metadata = try await source.client.albumInfo(id)
            }
            requested = true
            if (metadata?.notes ?? metadata?.biography ?? "").isEmpty, metadata?.similarArtist?.isEmpty != false,
               metadata?.lastFmUrl == nil, top.isEmpty {
                failure = "未找到资料，请检查服务器的外部资料来源设置。"
            }
        } catch { failure = error.localizedDescription }
    }
}

struct MusicRelatedTracks: View {
    let source: MusicSource
    let track: NavidromeTrack
    @State private var songs: [NavidromeTrack]?
    @State private var busy = false
    @State private var showPath = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("相似歌曲", systemImage: "sparkles") { load(sonic: false) }
                if source.capabilities.supports("sonicSimilarity") {
                    Menu("声音相似度", systemImage: "waveform") {
                        Button("声音相近的歌曲") { load(sonic: true) }
                        Button("查找两首歌之间的路径") { showPath = true }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .disabled(busy)
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if let songs {
                if songs.isEmpty { Text("暂无相似歌曲").foregroundStyle(.secondary).padding(.horizontal, 16) }
                else { MusicTrackRows(tracks: songs, source: source) }
            }
        }
        .padding(.vertical, 10)
        .sheet(isPresented: $showPath) { MusicSonicPath(source: source, start: track) }
    }

    private func load(sonic: Bool) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { songs = try await (sonic ? source.client.sonicMatches(from: track.id) : source.client.similarSongs(track.id)) }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct MusicSonicPath: View {
    let source: MusicSource
    let start: NavidromeTrack
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [NavidromeTrack] = []
    @State private var result: [NavidromeTrack]?
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("起点") { Text(start.title) }
                if let result {
                    Section("匹配路径") {
                        if result.isEmpty { Text("未找到路径") }
                        else {
                            Button("播放整条路径") { app.playMusic(result, at: 0, from: source); dismiss() }
                            ForEach(result.indices, id: \.self) { Text(result[$0].title) }
                        }
                        Button("重新查找") { self.result = nil }
                    }
                } else {
                    Section("选择终点") {
                        TextField("搜索歌曲", text: $query)
                        ForEach(candidates.filter { $0.id != start.id }) { track in
                            Button(track.title) { loadPath(track) }.disabled(busy)
                        }
                    }
                }
                if busy { ProgressView() }
                if let failure { Text(failure).foregroundStyle(.secondary) }
            }
            .navigationTitle("歌曲之间的路径")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .frame(minWidth: 320, minHeight: 320)
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { candidates = []; return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                candidates = try await source.client.search(term, limit: 20, songsOnly: true).song ?? []
                failure = nil
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private func loadPath(_ destination: NavidromeTrack) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { result = try await source.client.sonicMatches(from: start.id, to: destination.id) }
            catch { failure = error.localizedDescription }
        }
    }
}
