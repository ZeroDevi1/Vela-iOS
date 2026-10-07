import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// 目录详情：TMDB 资料 + 各服务器中的同一作品。
///
/// 只有按 TMDB / IMDb id 精确匹配到的库条目才提供进入与播放；未匹配到时明确显示「未入库」，
/// 查询失败的服务器单独列出，不当作「没有资源」。
struct CatalogDetailView: View {
    let title: CatalogTitle
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.isCompactLayout) private var isCompact
    @State private var detail: TMDBClient.Detail?
    @State private var detailError: String?
    @State private var matches: CatalogService.MatchResult?

    private var shown: CatalogTitle { detail?.title ?? title }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                hero
                VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
                    if app.subscriptions.isConnected {
                        SubscribeControl(title: shown, seasonCount: detail?.numberOfSeasons)
                    }
                    availability
                    if let tagline = detail?.tagline {
                        Text(tagline).font(.headline)
                    }
                    if let overview = shown.overview {
                        ExpandableText(text: overview)
                    }
                    if let detailError {
                        Label(detailError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .velaPageMargin()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)

                if let cast = detail?.cast, !cast.isEmpty {
                    MediaShelf("演职人员", items: cast) { member in
                        VStack(alignment: .leading, spacing: 2) {
                            RemoteArtwork(url: CatalogImage.url(member.profilePath, size: .profile), placeholderSymbol: "person.fill")
                                .frame(width: 96, height: 128)
                                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                            Text(member.name).font(.subheadline).lineLimit(1)
                            if let character = member.character, !character.isEmpty {
                                Text(character).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 96, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }

                if let recommendations = detail?.recommendations, !recommendations.isEmpty {
                    MediaShelf("相关推荐", items: recommendations) { other in
                        NavigationLink(value: other) { CatalogPosterCard(title: other) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, VelaTheme.Spacing.xxl)
        }
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar(removing: .title)
        .navigationTitle(title.title)
        .task(id: title.id) { await load() }
    }

    // MARK: - 头图

    private var hero: some View {
        Color.clear
            .frame(height: isCompact ? 420 : 500)
            .frame(maxWidth: .infinity)
            .overlay {
                RemoteArtwork(url: CatalogImage.url(shown.backdropPath, size: .backdrop) ?? CatalogImage.url(shown.posterPath, size: .posterLarge), placeholderSymbol: "film")
            }
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.3), .init(color: Color.homeBackground, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: VelaTheme.Spacing.l) {
                    RemoteArtwork(url: CatalogImage.url(shown.posterPath, size: .poster), placeholderSymbol: "film")
                        .frame(width: isCompact ? 100 : 130, height: isCompact ? 150 : 195)
                        .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                        .shadow(radius: 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shown.title).font(.title2.weight(.bold)).lineLimit(3)
                        if let original = shown.originalTitle, original != shown.title {
                            Text(original).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(metadata).font(.subheadline).foregroundStyle(.secondary)
                        if let rating = shown.voteAverage {
                            Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .velaPageMargin()
            }
    }

    private var metadata: String {
        var parts: [String] = [shown.mediaType == .movie ? "电影" : "剧集"]
        if let year = shown.year { parts.append(String(year)) }
        if let genres = detail?.genres, !genres.isEmpty { parts.append(genres.prefix(3).map(\.name).joined(separator: " / ")) }
        if let runtime = detail?.runtime, runtime > 0 { parts.append("\(runtime) 分钟") }
        if let seasons = detail?.numberOfSeasons, seasons > 0 { parts.append("\(seasons) 季") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 入库情况

    @ViewBuilder
    private var availability: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text("在服务器中").font(.title3.weight(.semibold))
            if let matches {
                if matches.matches.isEmpty && matches.failures.isEmpty {
                    Label(app.searchableSources.isEmpty ? "没有可查询的服务器" : "所有服务器中都没有这部作品", systemImage: "tray")
                        .foregroundStyle(.secondary)
                }
                ForEach(matches.matches) { match in
                    MatchRow(match: match)
                }
                ForEach(Array(matches.failures.enumerated()), id: \.offset) { _, failure in
                    Label("\(failure.serverName)：查询失败（\(failure.message)）", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        guard let client = app.catalog.client else {
            detailError = TMDBClient.TMDBError.missingKey.localizedDescription
            return
        }
        // IMDb id 只在详情中，先取详情再匹配；详情失败时仍按 TMDB id 匹配。
        do {
            detail = try await client.detail(title.mediaType, id: title.tmdbID)
            detailError = nil
        } catch {
            detailError = "TMDB 资料加载失败：\(error.localizedDescription)"
        }
        let identity = CatalogIdentity(mediaType: title.mediaType, tmdbID: title.tmdbID, imdbID: detail?.imdbID)
        matches = await CatalogService.match(identity, in: app.searchableSources, activeServerID: app.servers.activeServer?.id)
    }
}

/// MoviePilot 订阅：电影一键切换；剧集按季勾选。状态每次从 MoviePilot 读取。
private struct SubscribeControl: View {
    let title: CatalogTitle
    let seasonCount: Int?
    @Environment(AppModel.self) private var app
    @State private var subscribed: Set<Int>?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if title.mediaType == .movie {
                    let isOn = subscribed?.contains(0) == true
                    Button {
                        Task { await set(season: nil, on: !isOn) }
                    } label: {
                        Label(isOn ? "已订阅" : "订阅", systemImage: isOn ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.glass)
                } else {
                    Menu {
                        ForEach(1...max(seasonCount ?? 1, 1), id: \.self) { season in
                            Toggle("第 \(season) 季", isOn: Binding(
                                get: { subscribed?.contains(season) == true },
                                set: { on in Task { await set(season: season, on: on) } }
                            ))
                        }
                    } label: {
                        Label(subscribedSummary, systemImage: (subscribed?.isEmpty ?? true) ? "bookmark" : "bookmark.fill")
                    }
                    .buttonStyle(.glass)
                }
                if isWorking || subscribed == nil { ProgressView().controlSize(.small) }
            }
            .disabled(isWorking || subscribed == nil)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .task(id: title.id) { await refresh() }
    }

    private var subscribedSummary: String {
        guard let subscribed, !subscribed.isEmpty else { return "订阅" }
        return "已订阅 " + subscribed.sorted().map { "S\($0)" }.joined(separator: "、")
    }

    private func refresh() async {
        do {
            subscribed = try await app.subscriptions.subscribedSeasons(of: title)
            error = nil
        } catch {
            subscribed = []
            self.error = error.localizedDescription
        }
    }

    private func set(season: Int?, on: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.subscriptions.setSubscription(title, season: season, subscribed: on)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }
}

/// 一条匹配到的库资源：服务器名 + 条目；电影可直接播放，剧集进入详情选集。
private struct MatchRow: View {
    let match: CatalogService.Match
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            NavigationLink(value: match.item) {
                HStack(spacing: VelaTheme.Spacing.m) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.serverName).font(.headline)
                        Text([match.item.name, match.item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if match.item.kind.isPlayable {
                Button {
                    playMedia(.item(match.item))
                } label: {
                    Image(systemName: "play.fill").frame(width: 20, height: 20)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .accessibilityLabel("在 \(match.serverName) 播放")
            }
        }
        .padding(VelaTheme.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: VelaTheme.Radius.panel))
    }
}

/// TMDB 凭据设置。保存到 Keychain；留空表示使用构建时内置的凭据（若有）。
struct TMDBCredentialForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                SecureField("API Key 或 Read Access Token", text: $value)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status)
                    Link("在 TMDB 申请 API Key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if !app.catalog.userCredential.isEmpty {
                Button("清除已保存的凭据", role: .destructive) { save("") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("TMDB")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(value) }
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    private var status: String {
        if !app.catalog.userCredential.isEmpty { return "已保存自定义凭据（保存在本机钥匙串）。" }
        if app.catalog.usesBundledCredential { return "当前使用应用内置凭据。" }
        return "未配置：发现页不可用。"
    }

    private func save(_ newValue: String) {
        do {
            try app.catalog.setCredential(newValue)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
