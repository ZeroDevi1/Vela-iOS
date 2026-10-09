import Observation
import SwiftUI

/// 一个标签页的导航路径与前进记录，供 macOS 菜单栏「前往 → 返回 / 前进」（⌘[ / ⌘]）使用。
///
/// `NavigationPath` 不能取出被弹出的元素，前进记录因此保存整条路径的快照：「返回」前把当前路径压入前进栈，
/// 「前进」恢复栈顶快照。经其他途径改变路径（点按卡片进入、工具栏返回按钮）时清空前进栈，与浏览器行为一致。
@MainActor
@Observable
final class NavigationHistory {
    var path = NavigationPath() {
        didSet { if !isTraversing { forwardStack.removeAll() } }
    }
    private var forwardStack: [NavigationPath] = []
    @ObservationIgnored private var isTraversing = false

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func back() {
        guard !path.isEmpty else { return }
        traverse {
            forwardStack.append(path)
            path.removeLast()
        }
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        traverse { path = next }
    }

    /// 代码打开条目（键盘回车、调试启动参数），等同点按卡片。
    func push(_ value: some Hashable) {
        path.append(value)
    }

    private func traverse(_ change: () -> Void) {
        isTraversing = true
        change()
        isTraversing = false
    }
}

extension FocusedValues {
    /// 当前窗口当前标签的导航记录；没有浏览窗口在前台时为 nil，「返回 / 前进」置灰。
    @Entry var navigationHistory: NavigationHistory?
}

/// 带导航记录的 `NavigationStack`：使用上层（`MainTabView` 按标签）注入的 `NavigationHistory`，
/// 没有注入时（如 macOS 设置窗口、iOS）用自己的。导航记录同时注入到栈内，供卡片的键盘操作打开条目。
struct HistoryNavigationStack<Root: View>: View {
    @Environment(NavigationHistory.self) private var injected: NavigationHistory?
    @State private var local = NavigationHistory()
    private let root: Root

    init(@ViewBuilder root: () -> Root) {
        self.root = root()
    }

    var body: some View {
        @Bindable var history = injected ?? local
        NavigationStack(path: $history.path) { root }
            .environment(history)
    }
}
