import SwiftUI

/// 发现：TMDB / 豆瓣目录流 + 跨服务器继续观看。目录条目不是库条目，播放前必须按 TMDB / IMDb id 精确匹配库内资源。
///
/// 当前为占位，按 docs/ARCHITECTURE.md 的里程碑 M4 实现。
struct DiscoverView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "发现",
                systemImage: "safari",
                description: Text("TMDB 热门、分类榜单与跨服务器继续观看即将推出。")
            )
            .navigationTitle("发现")
        }
    }
}

/// 订阅与更新日历（MoviePilot / Bangumi）。占位，里程碑 M5。
struct SubscriptionsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "订阅",
                systemImage: "calendar",
                description: Text("连接 MoviePilot 后可查看订阅与播出日历；未配置时提供 Bangumi 公开放送。")
            )
            .navigationTitle("订阅")
        }
    }
}
