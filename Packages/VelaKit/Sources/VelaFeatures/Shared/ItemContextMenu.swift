import SwiftUI
import VelaCore
import VelaNetwork

/// 媒体卡片长按 / 右键菜单（对应 Android 条目长按底部菜单）：从头播放、已看 / 收藏、刷新元数据。
///
/// 编辑元数据 / 图片、识别、删除等管理操作 Android 由专门页面完成，iOS 暂未实现，不在此列出。
/// 已看 / 收藏的改动只写服务器，不就地修改卡片（各列表下次加载时更新）。
struct ItemContextMenu: ViewModifier {
    let item: MediaItem
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if item.kind.isPlayable {
                    Button("从头开始播放", systemImage: "play.fill") {
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
            .alert("操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

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
