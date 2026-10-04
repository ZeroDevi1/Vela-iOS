import SwiftUI
import VelaCore
import VelaPlayer

/// 设置。iPhone / iPad 在标签页中显示；macOS 在系统「设置」窗口（⌘,）中显示。
public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var isAdding = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    ForEach(app.servers.servers) { server in
                        NavigationLink(value: server.id) {
                            ServerRow(server: server, isActive: server.id == app.servers.activeServer?.id)
                        }
                    }
                    Button("添加服务器", systemImage: "plus") { isAdding = true }
                }

                Section("播放") {
                    NavigationLink("播放设置") { PlayerSettingsView() }
                    LabeledContent("播放内核", value: "AVPlayer（系统）")
                    LabeledContent("杜比视界", value: app.capabilities.supportsDolbyVision ? "支持" : "不支持")
                    LabeledContent("HDR10", value: app.capabilities.supportsHDR10 ? "支持" : "不支持")
                    LabeledContent("AV1 硬件解码", value: app.capabilities.supportsAV1 ? "支持" : "不支持")
                }

                Section("隐私") {
                    Button("立即锁定私密服务器", systemImage: "lock") { app.privacy.lockAll() }
                        .disabled(app.privacy.unlockedServerIDs.isEmpty)
                }

                #if DEBUG
                Section("开发") {
                    Button("测试播放（Apple HDR 示例流）", systemImage: "play.rectangle") {
                        playMedia(PlaybackRequest(
                            target: .url(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8")!),
                            title: "Apple HLS 示例"
                        ))
                    }
                }
                #endif

                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    Link("项目主页", destination: URL(string: "https://github.com/ZeroDevi1/Vela")!)
                } footer: {
                    Text("Vela 基于 JellyCine 继续开发，遵循 GPLv3。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .navigationDestination(for: String.self) { serverID in
                ServerEditView(serverID: serverID)
            }
            .sheet(isPresented: $isAdding) { AddServerView() }
        }
    }
}

private struct ServerRow: View {
    let server: SavedServer
    let isActive: Bool

    var body: some View {
        HStack {
            Image(systemName: server.isPrivate ? "lock.fill" : "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(server.displayName)
                Text("\(server.kind.displayName) · \(server.username) · \(server.activeLine.url.host() ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark").foregroundStyle(.tint)
                    .accessibilityLabel("当前服务器")
            }
        }
    }
}

/// 单个服务器的编辑：备注、私密、STRM 直连、线路与删除。
private struct ServerEditView: View {
    let serverID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        if let server = app.servers.servers.first(where: { $0.id == serverID }) {
            Form {
                Section {
                    TextField("备注", text: binding(server, \.noteText))
                    Toggle("私密服务器", isOn: binding(server, \.isPrivate))
                    Toggle("STRM 优先播放原始地址", isOn: binding(server, \.preferStrmOriginalPath))
                    Toggle("自动切换线路", isOn: binding(server, \.autoRouteEnabled))
                }
                Section("线路") {
                    ForEach(server.lines) { line in
                        Button {
                            var updated = server
                            updated.activeLineID = line.id
                            app.servers.update(updated)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(line.name.isEmpty ? (line.isLAN ? "局域网" : "公网") : line.name)
                                    Text(line.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if line.id == server.activeLineID { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    if server.id != app.servers.activeServer?.id {
                        Button("设为当前服务器") { app.servers.activate(server.id) }
                    }
                    Button("删除服务器", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(server.displayName)
            .confirmationDialog("删除「\(server.displayName)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    app.servers.remove(server.id)
                    dismiss()
                }
            } message: {
                Text("将移除本机保存的登录信息，服务器上的数据不受影响。")
            }
        } else {
            ContentUnavailableView("服务器不存在", systemImage: "server.rack")
        }
    }

    private func binding<Value>(_ server: SavedServer, _ keyPath: WritableKeyPath<SavedServer, Value>) -> Binding<Value> {
        Binding(
            get: { app.servers.servers.first { $0.id == serverID }?[keyPath: keyPath] ?? server[keyPath: keyPath] },
            set: { newValue in
                guard var updated = app.servers.servers.first(where: { $0.id == serverID }) else { return }
                updated[keyPath: keyPath] = newValue
                app.servers.update(updated)
            }
        )
    }
}

private extension SavedServer {
    var noteText: String {
        get { note ?? "" }
        set { note = newValue.isEmpty ? nil : newValue }
    }
}
