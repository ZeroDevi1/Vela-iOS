import SwiftUI

/// macOS 菜单栏「前往」：⌘1… 切换主导航标签，⌘F 进入搜索。作用于当前活动窗口（见 `FocusedValues.selectedTab`）；
/// 没有活动的浏览窗口（例如只开着播放器窗口）时菜单项置灰。
public struct VelaCommands: Commands {
    @FocusedBinding(\.selectedTab) private var selectedTab

    public init() {}

    public var body: some Commands {
        CommandMenu("前往") {
            item("首页", .home, key: "1")
            item("我的媒体", .media, key: "2")
            item("收藏", .favorites, key: "3")
            item("发现", .discover, key: "4")
            item("订阅", .subscriptions, key: "5")
            Divider()
            item("搜索", .search, key: "f")
        }
    }

    private func item(_ title: String, _ tab: AppTab, key: KeyEquivalent) -> some View {
        Button(title) { selectedTab = tab }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(selectedTab == nil)
    }
}
