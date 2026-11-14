import SwiftUI
import VelaDesignSystem
import VelaNetwork

enum MusicRoute: Hashable {
    case album(String, String)
    case artist(String, String)
    case genre(String)
    case playlist(String, String)
    case recent
    case favorites
    case playlists
    case track(String, String)
    case random
    case bookmarks
    case savedQueue
    case activity
    case directoryRoot
    case directory(String, String)

    var title: String {
        switch self {
        case .album(_, let name), .artist(_, let name), .playlist(_, let name), .genre(let name),
             .track(_, let name), .directory(_, let name): name
        case .recent: "最近播放"
        case .favorites: "收藏"
        case .playlists: "歌单"
        case .random: "随机歌曲"
        case .bookmarks: "书签"
        case .savedQueue: "服务器播放队列"
        case .activity: "服务器正在播放"
        case .directoryRoot: "目录索引"
        }
    }
}

struct MusicCover: View {
    let source: MusicSource
    let id: String?
    var size = 360
    var glyph = "music.note"
    var radius: CGFloat = 8
    @State private var loaded: CGImage?

    private var key: URL? { id.flatMap { source.coverKey($0, size: size) } }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = loaded ?? key.flatMap({ ImagePipeline.shared.cachedImage(for: $0) }) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: max(11, min(proxy.size.width * 0.29, 92)), weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: radius))
        .accessibilityHidden(true)
        .task(id: key) {
            loaded = nil
            guard let id else { return }
            let image = await source.artwork(id, size: size)
            if !Task.isCancelled { loaded = image }
        }
    }
}

struct MusicTrackRows: View {
    let tracks: [NavidromeTrack]
    let source: MusicSource
    var numbered = false
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(tracks.indices, id: \.self) { index in
            let track = tracks[index]
            HStack(spacing: 8) {
                Button {
                    app.playMusic(tracks, at: index, from: source)
                } label: {
                    MusicTrackLabel(track: track, source: source, number: numbered ? (track.track ?? index + 1) : nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("music.track.\(index)")
                Menu {
                    NavigationLink("歌曲详情", value: MusicRoute.track(track.id, track.title))
                    Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        app.music.enqueue(track, next: true)
                    }
                    .disabled(app.music.source?.id != source.id)
                    Button("添加到队列末尾", systemImage: "text.badge.plus") {
                        app.music.enqueue(track, next: false)
                    }
                    .disabled(app.music.source?.id != source.id)
                    if let album = track.album, let id = track.albumId {
                        NavigationLink(value: MusicRoute.album(id, album)) { Label("查看专辑", systemImage: "square.stack") }
                    }
                    if let artist = track.artist, let id = track.artistId {
                        NavigationLink(value: MusicRoute.artist(id, artist)) { Label("查看歌手", systemImage: "person") }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                        .frame(width: 36, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("曲目操作")
            }
            .padding(.horizontal, 16)
            if index < tracks.count - 1 { Divider().padding(.leading, 67).padding(.trailing, 16) }
        }
    }
}

struct MusicTrackLabel: View {
    let track: NavidromeTrack
    let source: MusicSource
    var number: Int?
    var playing = false

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 28)
            } else {
                MusicCover(source: source, id: track.coverArt, size: 144, radius: 6)
                    .frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                let detail = [track.artist, number == nil ? track.album : nil].compactMap { $0 }.filter { !$0.isEmpty }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if playing {
                Image(systemName: "waveform").foregroundStyle(.tint)
                    .accessibilityLabel("当前曲目")
            } else if let duration = track.duration, duration > 0 {
                Text(musicTime(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

struct MusicAlbumTile: View {
    let album: MusicAlbum
    let source: MusicSource

    var body: some View {
        NavigationLink(value: MusicRoute.album(album.id, album.name)) {
            VStack(alignment: .leading, spacing: 7) {
                MusicCover(source: source, id: album.coverArt, glyph: "square.stack")
                Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(album.artist ?? "未知歌手").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MusicAlbumGrid: View {
    let albums: [MusicAlbum]
    let source: MusicSource

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135, maximum: 235), spacing: 16)], alignment: .leading, spacing: 18) {
            ForEach(albums) { MusicAlbumTile(album: $0, source: source) }
        }
        .padding(.horizontal, 16)
    }
}

struct MusicDestinationRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let route: MusicRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.tint)
                    .frame(width: 32, height: 33)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                Text(title).font(.subheadline).lineLimit(1)
                Spacer()
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

struct MusicLoadError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("重试", action: retry).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}

func musicTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) :
        String(format: "%d:%02d", total / 60, total % 60)
}
