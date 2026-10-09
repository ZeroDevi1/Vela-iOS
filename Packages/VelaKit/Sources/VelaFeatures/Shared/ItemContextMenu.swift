import SwiftUI
import VelaCore
import VelaNetwork

/// 媒体卡片长按 / 右键菜单（对应 Android 条目长按底部菜单）：播放、从头播放、已看 / 收藏、刷新元数据。
///
/// macOS 鼠标悬停时卡片右上角另显示「播放 / 更多」按钮（第 3.5 节「悬停代替长按」），「更多」与右键菜单内容相同。
/// 卡片可获得键盘焦点（系统「键盘导航」开启时 Tab 键移入）：回车打开详情、空格播放，获得焦点时同样显示按钮。
///
/// 编辑元数据 / 图片、识别、删除等管理操作 Android 由专门页面完成，iOS 暂未实现，不在此列出。
/// 已看 / 收藏的改动只写服务器，不就地修改卡片（各列表下次加载时更新）。
struct ItemContextMenu: ViewModifier {
    let item: MediaItem
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var failure: String?
    #if os(macOS)
    @Environment(NavigationHistory.self) private var history: NavigationHistory?
    @State private var hovering = false
    @FocusState private var focused: Bool
    #endif

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            #if os(macOS)
            .overlay(alignment: .topTrailing) {
                if hovering || focused { hoverActions.padding(8).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.15), value: hovering || focused)
            .onHover { hovering = $0 }
            .focusable(interactions: .activate)
            .focused($focused)
            .onKeyPress(.return) {
                guard let history else { return .ignored }
                history.push(item)
                return .handled
            }
            .onKeyPress(.space) {
                guard item.kind.isPlayable else { return .ignored }
                playMedia(.item(item))
                return .handled
            }
            #endif
            .alert("操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        if item.kind.isPlayable {
            Button("播放", systemImage: "play.fill") { playMedia(.item(item)) }
            Button("从头开始播放", systemImage: "arrow.counterclockwise") {
                playMedia(.item(item, options: .init(startFromBeginning: true)))
            }
        }
        Button(item.isPlayed ? "标记为未看" : "标记为已看", systemImage: item.isPlayed ? "eye.slash" : "checkmark.circle") {
            run { try await $0.setPlayed(itemID: item.id, !item.isPlayed) }
        }
        Button(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "heart.slash" : "heart") {
            run { try await $0.setFavorite(itemID: item.id, !item.isFavorite) }
        }
        Divider()
        Button("刷新元数据", systemImage: "arrow.clockwise") {
            run { try await $0.refreshMetadata(itemID: item.id) }
        }
    }

    #if os(macOS)
    /// 悬停按钮放在画面右上角（卡片画面总在标题之上）；在画面上按控件尺寸规范用 28pt 小按钮。
    private var hoverActions: some View {
        HStack(spacing: 6) {
            if item.kind.isPlayable {
                Button { playMedia(.item(item)) } label: {
                    Image(systemName: "play.fill").frame(width: 28, height: 28)
                }
                .help("播放")
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuIndicator(.hidden)
            .help("更多")
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .background(.black.opacity(0.55), in: .capsule)
    }
    #endif

    private func run(_ action: @escaping @MainActor (MediaServerClient) async throws -> Void) {
        guard let client = app.client(forServerID: item.serverID) else {
            failure = "服务器不可用"
            return
        }
        Task {
            do {
                try await action(client)
            } catch APIError.http(let status, _) where status == 401 || status == 403 {
                failure = "当前账号没有权限执行此操作"
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension View {
    func itemContextMenu(_ item: MediaItem) -> some View {
        modifier(ItemContextMenu(item: item))
    }
}
