import SwiftUI

/// 页面级加载状态。失败时保留错误原因，不用空列表冒充「没有内容」。
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension LoadState: Sendable where Value: Sendable {}

/// 播放入口：iPhone / iPad 全屏覆盖，macOS 打开独立播放器窗口。由根视图注入。
public struct PlayMediaAction: Sendable {
    let handler: @MainActor @Sendable (PlaybackRequest) -> Void

    @MainActor
    public func callAsFunction(_ request: PlaybackRequest) { handler(request) }
}

extension EnvironmentValues {
    @Entry public var playMedia = PlayMediaAction { _ in }
}

/// 加载失败的统一展示，带重试。
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
                .buttonStyle(.glass)
        }
    }
}

extension EnvironmentValues {
    /// 紧凑布局（iPhone 竖屏、iPad 窄分屏）。由根视图按 horizontalSizeClass 注入；macOS 始终为 false。
    @Entry var isCompactLayout = false
}
