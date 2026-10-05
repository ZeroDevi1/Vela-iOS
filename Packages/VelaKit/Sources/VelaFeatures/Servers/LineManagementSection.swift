import SwiftUI
import VelaCore
import VelaData
import VelaNetwork

/// 服务器编辑页中的「线路」分区：查看状态、手动切换、检测、新增 / 重命名 / 删除。
struct LineManagementSection: View {
    let server: SavedServer
    @Environment(AppModel.self) private var app
    @State private var isAdding = false
    @State private var renaming: ServerLine?
    @State private var renameText = ""

    private var router: LineRouter { app.lineRouter }

    var body: some View {
        Section {
            ForEach(server.lines) { line in
                Button {
                    router.switchManually(serverID: server.id, lineID: line.id)
                } label: {
                    LineRow(line: line, isActive: line.id == server.activeLineID, status: router.statuses[line.id])
                }
                .buttonStyle(.plain)
                .contextMenu { actions(for: line) }
                .swipeActions { actions(for: line) }
            }

            Button {
                router.checkLines(serverID: server.id)
            } label: {
                HStack {
                    Label("检测线路", systemImage: "waveform.path.ecg")
                    if router.probingServerIDs.contains(server.id) {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(router.probingServerIDs.contains(server.id))

            Button("添加线路", systemImage: "plus") { isAdding = true }
        } header: {
            Text("线路")
        } footer: {
            Text(server.autoRouteEnabled
                 ? "已开启自动切换：Wi-Fi / 有线网络下优先局域网线路，蜂窝网络下使用公网线路；当前线路连接失败时自动换用其他可达线路。手动选择的线路会在下次网络变化时重新评估。"
                 : "自动切换已关闭，始终使用所选线路。")
        }
        .sheet(isPresented: $isAdding) {
            AddLineSheet(server: server)
        }
        .alert("重命名线路", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称（留空自动命名）", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let line = renaming { app.servers.renameLine(serverID: server.id, lineID: line.id, name: renameText) }
                renaming = nil
            }
        }
        .task(id: server.id) {
            // 进入页面时检测一次，让用户看到各线路的当前状态。
            if server.lines.contains(where: { router.statuses[$0.id] == nil }) {
                router.checkLines(serverID: server.id)
            }
        }
    }

    @ViewBuilder
    private func actions(for line: ServerLine) -> some View {
        Button("重命名", systemImage: "pencil") {
            renameText = line.name
            renaming = line
        }
        if server.lines.count > 1 {
            Button("删除", systemImage: "trash", role: .destructive) {
                app.servers.removeLine(serverID: server.id, lineID: line.id)
            }
        }
    }
}

private struct LineRow: View {
    let line: ServerLine
    let isActive: Bool
    let status: MediaServerProbe.LineProbeResult?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: line.isLAN ? "house" : "globe")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(LineRouting.displayName(of: line))
                Text(line.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            statusView
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(!isActive)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .reachable(let latency):
            Text("\(Int((latency * 1000).rounded())) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
        case .mismatch:
            Text("非同一服务器").font(.caption).foregroundStyle(.orange)
        case .unreachable:
            Text("不可达").font(.caption).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

/// 新增线路：输入地址后探测并核对服务器实例 id，确认是同一台服务器才保存。
private struct AddLineSheet: View {
    let server: SavedServer
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("地址，例如 192.168.1.10:8096 或 media.example.com", text: $address)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("名称（可选）", text: $name)
                } footer: {
                    Text("未写协议时自动尝试 https / http；Emby 自动补全 /emby。会核对是否为同一台服务器。")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加线路")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("添加") { Task { await add() } }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }

    private func add() async {
        isChecking = true
        error = nil
        defer { isChecking = false }
        do {
            let url = try await app.lineRouter.resolveNewLine(input: address, for: server)
            app.servers.addLine(serverID: server.id, url: url, name: name)
            app.lineRouter.checkLines(serverID: server.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
