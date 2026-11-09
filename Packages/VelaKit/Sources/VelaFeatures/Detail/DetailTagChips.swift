import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 详情页类型 / 制片公司胶囊点按后的条目列表（跨媒体库，按条目类型限定）。
struct DetailTagRoute: Hashable {
    var serverID: String
    var facet: MediaServerClient.Facet
    var id: String
    var name: String
    /// 只列出与来源条目同类的条目（电影 → 电影，剧集 / 季 / 单集 → 剧集）；空数组不限制。
    var itemTypes: [String]
}

/// 类型与制片公司胶囊（单集不显示，与 Android 一致）。
/// 服务器返回了 id（`GenreItems` / `Studios`）的胶囊可点按进入同类条目列表，没有 id 的只显示名称。
struct DetailTagChips: View {
    let item: MediaItem
    let details: ItemDetails?

    private struct Chip: Hashable {
        var facet: MediaServerClient.Facet
        var id: String?
        var name: String
    }

    private var chips: [Chip] {
        guard item.kind != .episode else { return [] }
        // 详情未加载完时先用列表接口带来的类型名称，加载后换成带 id 的版本。
        let genres: [Chip] = if let details, !details.genreItems.isEmpty {
            details.genreItems.prefix(4).map { Chip(facet: .genres, id: $0.id, name: $0.name) }
        } else {
            item.genres.prefix(4).map { Chip(facet: .genres, id: nil, name: $0) }
        }
        let studios = (details?.studioItems ?? []).prefix(3).map { Chip(facet: .studios, id: $0.id, name: $0.name) }
        return genres + studios
    }

    private var itemTypes: [String] {
        switch item.kind {
        case .movie: ["Movie"]
        case .series, .season, .episode: ["Series"]
        default: []
        }
    }

    var body: some View {
        let chips = chips
        if !chips.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        if let id = chip.id {
                            NavigationLink(value: DetailTagRoute(serverID: item.serverID, facet: chip.facet, id: id, name: chip.name, itemTypes: itemTypes)) {
                                label(chip.name, tappable: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            label(chip.name, tappable: false)
                        }
                    }
                }
            }
            .velaHideHorizontalScrollIndicators()
            .scrollClipDisabled()
        }
    }

    private func label(_ name: String, tappable: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name)
            if tappable {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).opacity(0.7)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VelaTheme.accentDeep.opacity(0.35), in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        #if os(macOS)
        .pointerStyle(tappable ? .link : nil)
        #endif
    }
}

/// 某个类型 / 制片公司下的条目（全部媒体库）。
struct DetailTagItemsView: View {
    let route: DetailTagRoute
    @State private var sort = LibrarySort(field: .premiereDate, descending: true)

    var body: some View {
        var template = ItemQuery(includeItemTypes: route.itemTypes, recursive: true)
        if route.facet == .genres { template.genreIDs = [route.id] } else { template.studioIDs = [route.id] }
        return PagedItemGrid(serverID: route.serverID, template: template, sort: sort, played: nil)
            .navigationTitle(route.name)
    }
}
