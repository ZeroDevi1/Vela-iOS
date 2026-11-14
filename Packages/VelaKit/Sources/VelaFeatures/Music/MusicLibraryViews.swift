import SwiftUI
import VelaDesignSystem
import VelaNetwork

struct MusicHomePage: View {
    let source: MusicSource
    let openLibrary: () -> Void
    let openPlayer: () -> Void
    @Environment(AppModel.self) private var app
    @State private var albums: [MusicAlbum]?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                currentCard
                HStack(spacing: 8) {
                    NavigationLink(value: MusicRoute.recent) { shortcut("最近", "clock") }
                    NavigationLink(value: MusicRoute.favorites) { shortcut("收藏", "heart") }
                    NavigationLink(value: MusicRoute.playlists) { shortcut("歌单", "music.note.list") }
                    Button(action: openLibrary) { shortcut("曲库", "square.grid.2x2") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                if !app.music.recent(for: source).isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("最近播放").font(.title3.bold())
                            Spacer()
                            NavigationLink(value: MusicRoute.recent) {
                                HStack(spacing: 4) {
                                    Text("查看全部")
                                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        MusicTrackRows(tracks: Array(app.music.recent(for: source).prefix(3)), source: source)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近加入").font(.title3.bold()).padding(.horizontal, 16)
                    if let error {
                        MusicLoadError(message: error) { retry += 1 }
                    } else if let albums {
                        if albums.isEmpty { ContentUnavailableView("暂无专辑", systemImage: "square.stack") }
                        else { MusicAlbumGrid(albums: albums, source: source) }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .task(id: retry) { await load() }
        .refreshable { await load() }
    }

    private var currentCard: some View {
        let playingTrack = app.music.source?.id == source.id ? app.music.current : nil
        let recent = app.music.recent(for: source)
        let track = playingTrack ?? recent.first
        return HStack(spacing: 13) {
            Button {
                if playingTrack != nil { openPlayer() }
                else if track != nil { app.playMusic(recent, at: 0, from: source) }
                else { openLibrary() }
            } label: {
                HStack(spacing: 13) {
                    MusicCover(source: source, id: track?.coverArt, size: 216, radius: 10).frame(width: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playingTrack == nil ? (track == nil ? "Navidrome" : "最近播放") : "正在播放")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(track?.title ?? "你的音乐库").font(.headline).lineLimit(1)
                        Text(track?.artist ?? "浏览专辑或搜索想听的歌曲")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if track != nil {
                Button {
                    if playingTrack != nil { app.music.toggle() }
                    else { app.playMusic(recent, at: 0, from: source) }
                } label: {
                    Image(systemName: playingTrack != nil && app.music.wantsPlayback ? "pause.fill" : "play.fill")
                        .frame(width: 43, height: 43)
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
                .accessibilityLabel(playingTrack != nil && app.music.wantsPlayback ? "暂停" : "播放")
            }
        }
        .padding(13)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
    }

    private func shortcut(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.headline)
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 11))
    }

    private func load() async {
        error = nil
        do {
            let result = try await source.client.albums(type: "newest", limit: 12)
            if !Task.isCancelled { albums = result }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct MusicLibraryPage: View {
    enum Category: String, CaseIterable {
        case songs = "歌曲", albums = "专辑", artists = "歌手", genres = "流派"
    }

    let source: MusicSource
    @State private var category: Category = .songs
    @State private var folders: [NavidromeFolder] = []
    @State private var folder: Int?

    var body: some View {
        content.id("\(category.rawValue):\(folder ?? -1)")
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("曲库分类", selection: $category) {
                    ForEach(Category.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .frame(maxWidth: 450)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("曲库选项", systemImage: "line.3.horizontal.decrease") {
                    if !folders.isEmpty {
                        Picker("服务器曲库", selection: $folder) {
                            Text("全部曲库").tag(nil as Int?)
                            ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    NavigationLink("目录索引", value: MusicRoute.directoryRoot)
                    NavigationLink("随机歌曲", value: MusicRoute.random)
                }
                .labelStyle(.iconOnly)
            }
        }
        .task { if let result = try? await source.client.musicFolders() { folders = result } }
    }

    @ViewBuilder private var content: some View {
        let client = source.client
        let folder = folder
        switch category {
        case .songs:
            MusicPagedList { offset, size in
                try await client.search("", limit: size, songOffset: offset, songsOnly: true, folder: folder).song ?? []
            } content: { tracks in
                MusicTrackRows(tracks: tracks, source: source)
            }
        case .albums:
            MusicPagedList { offset, size in
                try await client.albums(limit: size, offset: offset, folder: folder)
            } content: { albums in
                MusicAlbumGrid(albums: albums, source: source)
            }
        case .artists:
            MusicLoadedPage { try await client.artists(folder: folder) } content: { artists in
                if artists.isEmpty { ContentUnavailableView("暂无歌手", systemImage: "person.2") }
                ForEach(artists) { artist in
                    MusicArtistRow(artist: artist, source: source)
                }
            }
        case .genres:
            MusicLoadedPage { try await client.genres(folder: folder) } content: { genres in
                if genres.isEmpty { ContentUnavailableView("暂无流派", systemImage: "tag") }
                ForEach(genres) { genre in
                    MusicDestinationRow(title: genre.value, subtitle: "\(genre.songCount) 首",
                                        icon: "tag", route: .genre(genre.value))
                }
            }
        }
    }
}

private struct MusicPagedList<Item: Identifiable & Sendable, Content: View>: View {
    let load: @Sendable (Int, Int) async throws -> [Item]
    @ViewBuilder let content: ([Item]) -> Content
    @State private var items: [Item] = []
    @State private var offset = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    @State private var attempt = 0
    private let pageSize = 50

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty, !more { ContentUnavailableView("暂无内容", systemImage: "music.note") }
                content(items)
                if let error {
                    MusicLoadError(message: error) {
                        self.error = nil
                        attempt += 1
                    }
                } else if more {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(18)
                        .task(id: "\(offset)-\(attempt)") { await loadNext() }
                }
            }
            .padding(.vertical, 8)
        }
        .refreshable {
            guard !loading else { return }
            items = []
            offset = 0
            more = true
            error = nil
            attempt += 1
        }
    }

    private func loadNext() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let results = try await load(offset, pageSize)
            try Task.checkCancellation()
            var seen = Set(items.map(\.id))
            let unique = results.filter { seen.insert($0.id).inserted }
            items += unique
            more = results.count == pageSize && !unique.isEmpty
            offset += results.count
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct MusicLoadedPage<Value: Sendable, Content: View>: View {
    let load: @Sendable () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error {
                    MusicLoadError(message: error) { attempt += 1 }
                } else if let value {
                    content(value)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: attempt) { await fetch() }
        .refreshable { await fetch() }
    }

    private func fetch() async {
        error = nil
        do {
            let result = try await load()
            if !Task.isCancelled { value = result }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct MusicMyPage: View {
    let source: MusicSource

    var body: some View {
        MusicPlaylistsPage(source: source)
        .safeAreaInset(edge: .top, spacing: 0) {
            rows.background(.background)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            MusicDestinationRow(title: "最近播放", subtitle: nil, icon: "clock", route: .recent)
            MusicDestinationRow(title: "收藏", subtitle: nil, icon: "heart", route: .favorites)
            MusicDestinationRow(title: "书签", subtitle: nil, icon: "bookmark", route: .bookmarks)
            MusicDestinationRow(title: "服务器播放队列", subtitle: nil, icon: "music.note.list", route: .savedQueue)
            if !source.isPrivate {
                MusicDestinationRow(title: "服务器正在播放", subtitle: nil, icon: "waveform", route: .activity)
            }
        }
    }
}

struct MusicPlaylistsPage: View {
    let source: MusicSource
    @State private var creating = false
    @State private var refresh = 0

    var body: some View {
        MusicLoadedPage { try await source.client.playlists() } content: { playlists in
            if playlists.isEmpty {
                ContentUnavailableView("暂无歌单", systemImage: "music.note.list")
            } else {
                Text("歌单").font(.title3.bold()).padding(.horizontal, 16).padding(.vertical, 12)
                MusicPlaylistRows(playlists: playlists)
            }
        }
        .id(refresh)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("新建歌单", systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating, onDismiss: { refresh += 1 }) {
            MusicPlaylistEditor(source: source)
        }
    }
}

private struct MusicPlaylistRows: View {
    let playlists: [MusicPlaylist]

    var body: some View {
        ForEach(playlists) { playlist in
            MusicDestinationRow(title: playlist.name, subtitle: playlist.songCount.map { "\($0) 首" },
                                icon: "music.note.list", route: .playlist(playlist.id, playlist.name))
        }
    }
}

struct MusicDetailPage: View {
    let route: MusicRoute
    let source: MusicSource
    @Environment(AppModel.self) private var app

    var body: some View {
        content.navigationTitle(route.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder private var content: some View {
        let client = source.client
        switch route {
        case .album(let id, _):
            MusicLoadedPage { try await client.album(id) } content: { album in
                MusicAlbumDetail(album: album, source: source)
            }
        case .artist(let id, _):
            MusicLoadedPage { try await client.artist(id) } content: { artist in
                VStack(spacing: 10) {
                    MusicCover(source: source, id: artist.coverArt, size: 384, radius: 88, artist: artist)
                        .frame(width: 176)
                    Text(artist.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if let count = artist.albumCount {
                        Text("\(count) 张专辑").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                if let albums = artist.album, !albums.isEmpty { MusicAlbumGrid(albums: albums, source: source) }
                else { ContentUnavailableView("暂无专辑", systemImage: "square.stack") }
                MusicItemActions(source: source, id: id, title: artist.name, kind: .artist, starred: artist.starred != nil)
                MusicMetadataSection(source: source, id: id, isArtist: true, artistName: artist.name)
            }
        case .genre(let name):
            MusicPagedList { offset, size in
                try await client.songs(genre: name, limit: size, offset: offset)
            } content: { tracks in
                MusicTrackRows(tracks: tracks, source: source)
            }
        case .playlist(let id, _):
            MusicEditablePlaylist(source: source, id: id)
        case .recent:
            ScrollView {
                LazyVStack { trackSection(app.music.recent(for: source), numbered: false) }.padding(.vertical, 8)
            }
        case .favorites:
            MusicLoadedPage { try await client.favorites() } content: { results in
                MusicResults(source: source, results: results, emptyTitle: "暂无收藏")
            }
        case .playlists:
            MusicPlaylistsPage(source: source)
        case .track(let id, _):
            MusicLoadedPage { try await client.song(id) } content: { track in
                headline(track.title, subtitle: track.artist, cover: track.coverArt, icon: "music.note")
                trackSection([track], numbered: false)
                MusicItemActions(source: source, id: id, title: track.title, kind: .song, starred: track.starred != nil,
                                 rating: track.userRating, track: track)
                MusicRelatedTracks(source: source, track: track)
            }
        case .random:
            MusicLoadedPage { try await client.randomSongs() } content: { tracks in
                trackSection(tracks, numbered: false)
            }
        case .bookmarks:
            MusicBookmarksPage(source: source)
        case .savedQueue:
            MusicLoadedPage { try await client.savedQueue(indexed: source.capabilities.supports("indexBasedQueue")) } content: { remote in
                if let remote, let tracks = remote.entry, !tracks.isEmpty {
                    Button("恢复队列与播放位置", systemImage: "play.fill") {
                        app.playMusic(tracks, at: remote.selectedIndex, from: source, position: Double(remote.position ?? 0) / 1000)
                    }
                    .foregroundStyle(.primary)
                    .buttonStyle(.glass).padding(16)
                    trackSection(tracks, numbered: true)
                } else {
                    ContentUnavailableView("没有已保存的队列", systemImage: "music.note.list")
                }
            }
        case .activity:
            MusicLoadedPage { try await client.nowPlaying() } content: { entries in
                if entries.isEmpty { ContentUnavailableView("服务器上暂无播放", systemImage: "waveform") }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    MusicDestinationRow(title: entry.title, subtitle: entry.playerName, icon: "waveform",
                                        route: .track(entry.id, entry.title))
                }
            }
        case .directoryRoot:
            MusicLoadedPage { try await client.directoryArtists() } content: { rows in
                if rows.isEmpty { ContentUnavailableView("目录为空", systemImage: "folder") }
                ForEach(rows) { entry in
                    MusicDestinationRow(title: entry.name, subtitle: nil, icon: "folder", route: .directory(entry.id, entry.name))
                }
            }
        case .directory(let id, _):
            MusicLoadedPage { try await client.directory(id) } content: { rows in
                if rows.isEmpty { ContentUnavailableView("目录为空", systemImage: "folder") }
                ForEach(rows) { entry in
                    MusicDestinationRow(title: entry.title, subtitle: nil, icon: entry.isDir == true ? "folder" : "music.note",
                                        route: entry.isDir == true ? .directory(entry.id, entry.title) : .track(entry.id, entry.title))
                }
            }
        }
    }

    private func headline(_ title: String, subtitle: String?, cover: String?, icon: String) -> some View {
        VStack(spacing: 10) {
            MusicCover(source: source, id: cover, size: 520, glyph: icon, radius: 16)
                .frame(maxWidth: 200)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    @ViewBuilder private func trackSection(_ tracks: [NavidromeTrack], numbered: Bool) -> some View {
        if tracks.isEmpty {
            ContentUnavailableView("暂无歌曲", systemImage: "music.note")
        } else {
            Button {
                app.playMusic(tracks, at: 0, from: source)
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            MusicTrackRows(tracks: tracks, source: source, numbered: numbered)
        }
    }
}

private struct MusicAlbumDetail: View {
    let album: MusicAlbum
    let source: MusicSource
    @Environment(AppModel.self) private var app

    private var tracks: [NavidromeTrack] { album.song ?? [] }
    private var cover: String? { album.coverArt ?? tracks.first?.coverArt }

    var body: some View {
        VStack(spacing: 25) {
            hero
            tracksSection
            MusicMetadataSection(source: source, id: album.id, isArtist: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.glass)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            MusicArtworkBackdrop(source: source, coverArt: cover)
                .frame(height: 500)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28),
                                           .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .allowsHitTesting(false)
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            MusicCover(source: source, id: cover, size: 650, glyph: "square.stack", radius: 24)
                .frame(maxWidth: 245)
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.20)) }
                .shadow(color: .black.opacity(0.23), radius: 20, y: 10)

            VStack(spacing: 6) {
                Text(album.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let artist = album.artist, !artist.isEmpty {
                    if let id = album.artistId ?? tracks.first(where: { $0.artist == artist })?.artistId {
                        NavigationLink(value: MusicRoute.artist(id, artist)) {
                            HStack(spacing: 5) {
                                Text(artist)
                                Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(artist).foregroundStyle(.secondary)
                    }
                }
                let duration = album.duration.map(Double.init) ?? tracks.compactMap(\.duration).reduce(0, +)
                let details = [album.year.flatMap { $0 > 0 ? String($0) : nil }, "\(album.songCount ?? tracks.count) 首",
                               duration > 0 ? "\(max(1, Int(duration / 60))) 分钟" : nil].compactMap { $0 }
                Text(details.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
            MusicItemActions(source: source, id: album.id, title: album.name, kind: .album, starred: album.starred != nil,
                             albumPlay: tracks.isEmpty ? nil : { app.playMusic(tracks, at: 0, from: source) })
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("曲目").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16).padding(.vertical, 13)
            if tracks.isEmpty {
                ContentUnavailableView("暂无歌曲", systemImage: "music.note")
            } else {
                LazyVStack(spacing: 0) {
                    MusicTrackRows(tracks: tracks, source: source, numbered: true)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
    }
}

struct MusicSearchPage: View {
    let source: MusicSource
    @State private var query = ""
    @State private var attempt = 0
    @State private var results: MusicSearchResults?
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("搜索音乐", systemImage: "magnifyingglass",
                                           description: Text("按歌曲、专辑或歌手查找"))
                } else if let error {
                    MusicLoadError(message: error) { attempt += 1 }
                } else if let results {
                    MusicResults(source: source, results: results, emptyTitle: "未找到相关音乐")
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(28)
                }
            }
        }
        .searchable(text: $query, prompt: "歌曲、专辑或歌手")
        .task(id: "\(attempt):\(query)") {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = nil
            error = nil
            guard !term.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(280))
                let hits = try await source.client.search(term, limit: 40)
                if !Task.isCancelled { results = hits }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct MusicResults: View {
    let source: MusicSource
    let results: MusicSearchResults
    let emptyTitle: String

    var body: some View {
        if let tracks = results.song, !tracks.isEmpty {
            heading("歌曲")
            MusicTrackRows(tracks: tracks, source: source)
        }
        if let albums = results.album, !albums.isEmpty {
            heading("专辑")
            MusicAlbumGrid(albums: albums, source: source)
        }
        if let artists = results.artist, !artists.isEmpty {
            heading("歌手")
            ForEach(artists) { artist in
                MusicArtistRow(artist: artist, source: source)
            }
        }
        if results.song?.isEmpty != false && results.album?.isEmpty != false && results.artist?.isEmpty != false {
            ContentUnavailableView(emptyTitle, systemImage: "music.note")
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title3.bold()).padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 8)
    }
}
