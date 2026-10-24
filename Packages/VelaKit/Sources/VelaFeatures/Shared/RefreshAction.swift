import SwiftUI

extension View {
    /// 下拉刷新，刷新期间视图重绘不会取消加载。
    ///
    /// 加载过程中改动状态（清空列表、显示加载中等）会让页面重绘，SwiftUI 随之取消 `refreshable` 自带的任务，
    /// 网络请求以「已取消」失败，页面停在错误状态。把加载放进非结构化 `Task` 不继承这次取消；
    /// 等待它的结果，下拉指示器仍在加载结束后才收起。离开页面时加载会继续到完成，结果写回已不显示的状态。
    func refreshableLoad(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable { await Task { @MainActor in await action() }.value }
    }
}
