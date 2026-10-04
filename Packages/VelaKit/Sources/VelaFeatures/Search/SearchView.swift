import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem

/// 聚合搜索：同时搜索所有已解锁的服务器，结果按来源分区；单个源失败只在该分区提示。
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var query = ""
    @State private var sections: [FederatedSearchSection] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "聚合搜索",
                        systemImage: "magnifyingglass",
                        description: Text("同时搜索所有已登录的服务器。私密服务器需先解锁才会参与。")
                    )
                } else if isSearching && sections.isEmpty {
                    ProgressView()
                } else if sections.allSatisfy(\.isEmptySuccess) {
                    ContentUnavailableView.search(text: query)
                } else {
                    results
                }
            }
            .navigationTitle("搜索")
            .detailDestinations()
        }
        .searchable(text: $query, prompt: "电影、剧集、单集")
        // 输入停顿 350ms 后再搜索，避免每个字符都打到所有服务器。
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                ForEach(sections) { section in
                    switch section.result {
                    case .success(let items) where !items.isEmpty:
                        MediaShelf("\(section.sourceName)（\(items.count)）", items: items) { item in
                            NavigationLink(value: item) {
                                PosterCard(
                                    title: item.seriesName ?? item.name,
                                    subtitle: item.episodeLabel ?? item.productionYear.map(String.init),
                                    imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                                    progress: item.playedFraction,
                                    width: VelaTheme.posterWidth(compact: isCompact)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    case .failure(let error):
                        Label("\(section.sourceName)：\(error.message)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, VelaTheme.Spacing.l)
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(.vertical, VelaTheme.Spacing.l)
        }
    }

    private func search() async {
        let term = query
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            sections = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        let result = await app.searchService.search(term, in: app.searchableSources)
        // 期间用户继续输入时丢弃过期结果。
        guard term == query else { return }
        sections = result
    }
}

private extension FederatedSearchSection {
    var isEmptySuccess: Bool {
        if case .success(let items) = result { return items.isEmpty }
        return false
    }
}
