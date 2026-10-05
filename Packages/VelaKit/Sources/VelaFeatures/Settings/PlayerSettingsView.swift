import SwiftUI
import VelaCore
import VelaPlayer

/// 播放设置：快进快退、手势、片头片尾与下一集、字幕外观。修改即时保存，下次进入播放器生效。
struct PlayerSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                Picker("播放内核", selection: $prefs.engineMode) {
                    ForEach(PlaybackEngineMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("内核")
            } footer: {
                Text("自动：系统内核能直放或服务器只需转封装时用系统内核（HDR / 杜比视界 / 画中画 / AirPlay）；服务器因格式或字幕需要转码时改用 MPV 直放原文件（MKV、ASS 特效字幕、图形字幕）。因码率超限转码时仍用系统内核。MPV 内核不支持画中画与 VR 转平面。")
            }

            Section {
                Picker("快退", selection: $prefs.seekBackwardSeconds) {
                    ForEach(PlayerPreferences.seekIntervals, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("快进", selection: $prefs.seekForwardSeconds) {
                    ForEach(PlayerPreferences.seekIntervals, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("长按倍速", selection: $prefs.holdSpeed) {
                    ForEach(PlayerPreferences.holdSpeeds, id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
            } header: {
                Text("快进与倍速")
            } footer: {
                Text("双击画面左 / 右侧快退 / 快进；按住画面临时倍速播放，松手恢复。")
            }

            #if os(iOS)
            Section("手势") {
                Toggle("左侧亮度 / 右侧音量", isOn: $prefs.enableBrightnessVolume)
                Toggle("横向滑动调整进度", isOn: $prefs.enableSwipeSeek)
            }
            #endif

            Section {
                Toggle("自动跳过片头", isOn: $prefs.autoSkipIntro)
                Toggle("自动播放下一集", isOn: $prefs.autoPlayNext)
            } header: {
                Text("剧集")
            } footer: {
                Text("片头片尾数据来自服务器：Jellyfin 10.10+ 的媒体片段，或 Emby 的章节标记。没有数据时在结束前 30 秒提示下一集。")
            }

            Section("字幕") {
                LabeledContent("字号") {
                    Slider(value: $prefs.subtitleScale, in: 0.6...2.0, step: 0.1) {
                        Text("字号")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                LabeledContent("底部距离") {
                    Slider(value: $prefs.subtitleBottomOffset, in: 0...200, step: 10) {
                        Text("底部距离")
                    }
                }
                Text("字幕预览 Subtitle Preview")
                    .font(.system(size: 20 * prefs.subtitleScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.black.gradient, in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("播放")
    }
}
