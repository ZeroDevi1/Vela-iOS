import SwiftUI

public extension View {
    /// 横向滚动列表的翻页按钮（仅 macOS）：鼠标悬停在列表上时，两侧显示「上一页 / 下一页」，点按滚动约一屏。
    /// Mac 没有触屏，鼠标滚轮只能纵向滚动，触控板横扫也容易误触页面滚动，横滑列表需要可点的入口。
    /// iOS 不做任何改变（触屏横滑即可，iPad 指针也支持横向滚动）。
    ///
    /// 作用于 `ScrollView(.horizontal)` 本身，内部挂 `scrollPosition`；列表已用 `scrollPosition(id:)` 定位时
    /// 改用 `velaHorizontalPaging(ids:position:pageSize:)`，同一个 ScrollView 不能挂两个滚动定位。
    func velaHorizontalPaging() -> some View {
        modifier(OffsetPagingModifier())
    }

    /// 按卡片 id 翻页（仅 macOS）：每次前进 / 后退 `pageSize` 张，写入与 `scrollPosition(id:)` 共用的绑定。
    /// - Parameters:
    ///   - ids: 列表中卡片的 id，按显示顺序。
    ///   - position: 与 `scrollPosition(id:anchor: .leading)` 相同的绑定（当前最左侧的卡片）。
    ///   - pageSize: 一屏可见的卡片数。
    func velaHorizontalPaging<ID: Hashable>(ids: [ID], position: Binding<ID?>, pageSize: Int) -> some View {
        modifier(IDPagingModifier(ids: ids, position: position, pageSize: max(1, pageSize)))
    }
}

#if os(macOS)
/// 悬停时两侧显示的圆形翻页按钮；已滚到头的一侧不显示。
private struct PagingButtons: ViewModifier {
    let canGoBack: Bool
    let canGoForward: Bool
    let page: (_ forward: Bool) -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if hovering, canGoBack { button(forward: false).padding(.leading, 8) }
            }
            .overlay(alignment: .trailing) {
                if hovering, canGoForward { button(forward: true).padding(.trailing, 8) }
            }
            // 放在 overlay 之后：悬停范围要包含按钮本身，否则指针移到按钮上即判定离开，按钮消失、点击落空。
            .onHover { hovering = $0 }
    }

    private func button(forward: Bool) -> some View {
        Button {
            page(forward)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(forward ? "下一页" : "上一页")
        .transition(.opacity)
    }
}
#endif

private struct OffsetPagingModifier: ViewModifier {
    #if os(macOS)
    @State private var position = ScrollPosition()
    @State private var metrics = Metrics()

    /// 滚动区域的偏移与尺寸（pt）；`minOffset` / `maxOffset` 已计入内容边距。
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var visibleWidth: CGFloat = 0
        var minOffset: CGFloat = 0
        var maxOffset: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(
                    offset: geometry.contentOffset.x,
                    visibleWidth: geometry.containerSize.width,
                    minOffset: -geometry.contentInsets.leading,
                    maxOffset: max(
                        -geometry.contentInsets.leading,
                        geometry.contentSize.width + geometry.contentInsets.trailing - geometry.containerSize.width
                    )
                )
            } action: { _, new in
                metrics = new
            }
            // 留 1pt 容差，避免浮点误差导致到头后按钮不消失。
            .modifier(PagingButtons(
                canGoBack: metrics.offset > metrics.minOffset + 1,
                canGoForward: metrics.offset < metrics.maxOffset - 1
            ) { forward in
                // 每次滚动可见宽度的 85%，保留一小段上一屏的内容作为衔接。
                let step = metrics.visibleWidth * 0.85 * (forward ? 1 : -1)
                let target = min(max(metrics.offset + step, metrics.minOffset), metrics.maxOffset)
                withAnimation(.snappy) { position.scrollTo(x: target) }
            })
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

private struct IDPagingModifier<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var position: ID?
    let pageSize: Int

    #if os(macOS)
    func body(content: Content) -> some View {
        let index = position.flatMap { ids.firstIndex(of: $0) } ?? 0
        content.modifier(PagingButtons(
            canGoBack: index > 0,
            canGoForward: index + pageSize < ids.count
        ) { forward in
            // 向后翻到最后一屏时以最后一张卡片收尾，不留空白。
            let target = forward ? min(index + pageSize, max(ids.count - pageSize, 0)) : max(index - pageSize, 0)
            withAnimation(.snappy) { position = ids[target] }
        })
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
