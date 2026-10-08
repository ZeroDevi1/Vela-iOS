import SwiftUI
import VelaDesignSystem

/// 首次启动引导。
struct OnboardingView: View {
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("欢迎使用 Vela", systemImage: "play.tv")
            } description: {
                Text("连接你的 Jellyfin 或 Emby 服务器，开始观看。")
            } actions: {
                Button("添加服务器") { isAdding = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .sheet(isPresented: $isAdding) {
                AddServerView()
            }
        }
    }
}

/// 添加服务器：地址 + 用户名 + 密码。地址可省略协议与 `/emby` 后缀，由探测逻辑补全。
struct AddServerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var note = ""
    @State private var isPrivate = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, note }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址", text: $address, prompt: Text("例如 192.168.1.2:8096 或 media.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                } footer: {
                    Text("支持 Jellyfin 与 Emby，未填写协议时自动尝试 HTTPS / HTTP。")
                }

                Section("账号") {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .note }
                }

                Section {
                    TextField("备注（可选）", text: $note)
                        .focused($focus, equals: .note)
                        .submitLabel(.done)
                        .onSubmit(submit)
                    Toggle("私密服务器", isOn: $isPrivate)
                } footer: {
                    Text("私密服务器每次启动应用后需通过面容 ID / 触控 ID / 密码验证，且不参与未解锁时的聚合搜索。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加服务器")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("连接", action: submit)
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear { focus = .address }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                var output = try await app.loginService.login(
                    address: address,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password,
                    note: note.isEmpty ? nil : note
                )
                output.server.isPrivate = isPrivate
                try app.servers.upsert(output.server, accessToken: output.accessToken)
                if isPrivate {
                    // 与冷启动一致：私密服务器只能通过设备认证解锁；用户取消则保持锁定。
                    await app.privacy.unlock(output.server.id)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 工具栏中的服务器切换菜单，各内容页共用。
struct ServerSwitcherMenu: View {
    @Environment(AppModel.self) private var app
    @State private var isAdding = false

    var body: some View {
        Menu {
            Picker("当前服务器", selection: Binding(
                get: { app.servers.activeServer?.id },
                set: { if let id = $0 { app.servers.activate(id) } }
            )) {
                ForEach(app.servers.servers) { server in
                    Label(server.displayName, systemImage: server.isPrivate ? "lock" : "server.rack")
                        .tag(Optional(server.id))
                }
            }
            Divider()
            Button("添加服务器…", systemImage: "plus") { isAdding = true }
        } label: {
            Label(app.servers.activeServer?.displayName ?? "服务器", systemImage: "server.rack")
        }
        .sheet(isPresented: $isAdding) { AddServerView() }
    }
}
