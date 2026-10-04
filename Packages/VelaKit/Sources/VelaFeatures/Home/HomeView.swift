import SwiftUI
import VelaCore
import VelaDesignSystem

/// 当前服务器首页：继续观看、下一集、最新入库。各分区独立加载，单个失败不影响其他分区。
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var resume: LoadState<[MediaItem]> = .idle
    @State private var nextUp: LoadState<[MediaItem]> = .idle
    @State private var latest: LoadState<[MediaItem]> = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                    shelf("继续观看", state: resume, landscape: true)
                    shelf("下一集", state: nextUp, landscape: true)
                    shelf("最新入库", state: latest, landscape: false)
                    if allEmpty {
                        ContentUnavailableView("暂无内容", systemImage: "film.stack", description: Text("服务器上还没有可展示的内容。"))
                    }
                }
                .padding(.vertical, VelaTheme.Spacing.l)
            }
            .navigationTitle(app.servers.activeServer?.displayName ?? "首页")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ServerSwitcherMenu() }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
                #endif
            }
            .detailDestinations()
            .refreshable { await load() }
            .task(id: app.servers.activeServer?.baseURL) { await load() }
        }
    }

    private var allEmpty: Bool {
        [resume, nextUp, latest].allSatisfy { state in
            if case .loaded(let items) = state { return items.isEmpty }
            return false
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, state: LoadState<[MediaItem]>, landscape: Bool) -> some View {
        switch state {
        case .loaded(let items) where !items.isEmpty:
            MediaShelf(title, items: items) { item in
                NavigationLink(value: item) {
                    if landscape {
                        LandscapeCard(
                            title: item.seriesName ?? item.name,
                            subtitle: item.episodeLabel.map { "\($0) · \(item.name)" },
                            imageURL: app.imageURL(for: item, kind: .backdrop, maxWidth: 640)
                                ?? app.imageURL(for: item, kind: .primary, maxWidth: 640),
                            progress: item.playedFraction,
                            width: VelaTheme.landscapeCardWidth(compact: isCompact)
                        )
                    } else {
                        PosterCard(
                            title: item.seriesName ?? item.name,
                            subtitle: item.productionYear.map(String.init),
                            imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                            width: VelaTheme.posterWidth(compact: isCompact)
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        case .failed(let message):
            Label("\(title)加载失败：\(message)", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, VelaTheme.Spacing.l)
        case .loading where state.value == nil:
            ProgressView().frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }

    private func load() async {
        guard let client = app.activeClient else {
            resume = .failed("登录已失效，请在设置中重新添加服务器")
            return
        }
        if resume.value == nil { resume = .loading }
        async let resumeTask = capture { try await client.resumeItems() }
        async let nextUpTask = capture { try await client.nextUp() }
        async let latestTask = capture { try await client.latestItems(limit: 24) }
        resume = LoadState(await resumeTask)
        nextUp = LoadState(await nextUpTask)
        latest = LoadState(await latestTask)
    }
}

extension LoadState {
    init(_ result: Result<Value, any Error>) {
        switch result {
        case .success(let value): self = .loaded(value)
        case .failure(let error): self = .failed(error.localizedDescription)
        }
    }
}

/// 把抛错的异步调用转为 `Result`，便于多个分区并发加载、各自处理失败。
func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
