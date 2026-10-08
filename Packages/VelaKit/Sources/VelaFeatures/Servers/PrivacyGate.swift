import SwiftUI

/// 私密服务器解锁前不创建内容视图，避免请求、缓存或快照泄露内容。
struct PrivacyGate<Content: View>: View {
    @Environment(AppModel.self) private var app
    @State private var isUnlocking = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if app.isActiveServerAccessible {
            content()
        } else if let server = app.servers.activeServer {
            ContentUnavailableView {
                Label("私密服务器", systemImage: "lock.fill")
            } description: {
                Text("「\(server.displayName)」需要验证身份后才能访问。解锁仅在本次运行期间有效。")
            } actions: {
                Button {
                    Task {
                        isUnlocking = true
                        await app.privacy.unlock(server.id)
                        isUnlocking = false
                    }
                } label: {
                    Label("解锁", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUnlocking)

                if let error = app.privacy.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                let publicServers = app.servers.servers.filter { !$0.isPrivate }
                if !publicServers.isEmpty {
                    Menu("切换到其他服务器") {
                        ForEach(publicServers) { other in
                            Button(other.displayName) { app.servers.activate(other.id) }
                        }
                    }
                }
            }
        }
    }
}
