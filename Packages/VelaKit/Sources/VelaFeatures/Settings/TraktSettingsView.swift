import SwiftUI
import VelaData

/// Trakt 同步设置：填写应用凭据 → 设备码授权 → 播放时自动 scrobble。
struct TraktSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var error: String?

    var body: some View {
        @Bindable var trakt = app.trakt
        Form {
            Section {
                TextField("Client ID", text: $clientID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Client Secret", text: $clientSecret)
                Button("保存凭据") {
                    do {
                        try app.trakt.saveCredentials(clientID: clientID, clientSecret: clientSecret)
                        clientSecret = ""
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(clientID.isEmpty || clientSecret.isEmpty)
            } header: {
                Text("应用凭据")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.trakt.hasCredentials ? "已保存凭据（保存在本机钥匙串）。" : "在 Trakt 创建应用，Redirect URI 填 urn:ietf:wg:oauth:2.0:oob。")
                    Link("打开 Trakt 应用管理", destination: URL(string: "https://trakt.tv/oauth/applications")!)
                }
            }

            Section("账号") {
                if app.trakt.isConnected {
                    Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Toggle("播放时同步观看记录", isOn: $trakt.scrobbleEnabled)
                    Button("断开连接", role: .destructive) { app.trakt.disconnect() }
                } else if let pending = app.trakt.pending {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在浏览器打开下面的网址并输入验证码：")
                        Text(pending.userCode)
                            .font(.title.monospaced().weight(.bold))
                            .textSelection(.enabled)
                        Button(pending.verificationURL.absoluteString) { openURL(pending.verificationURL) }
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("等待确认…").foregroundStyle(.secondary)
                        }
                    }
                    Button("取消", role: .cancel) { app.trakt.cancelAuthorization() }
                } else {
                    Button("连接 Trakt") { Task { await app.trakt.beginAuthorization() } }
                        .disabled(!app.trakt.hasCredentials)
                }
                if let message = error ?? app.trakt.lastError {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }

            Section {
            } footer: {
                Text("只同步带有 TMDB / IMDb / TVDB id 的电影与单集；进度达到 80% 时 Trakt 记为已看。同步失败不影响播放。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Trakt")
        .onAppear { if clientID.isEmpty { clientID = app.trakt.clientID } }
    }
}
