import SwiftUI
import VelaCore
import VelaPlayer

/// 设置中「播放」相关的子页面入口。
struct PlaybackSettingsLinks: View {
    var body: some View {
        NavigationLink("播放设置") { PlayerSettingsView() }
        NavigationLink("视频设置") { VideoSettingsView() }
        NavigationLink("音频设置") { AudioSettingsView() }
        NavigationLink("字幕设置") { SubtitleSettingsView() }
        #if os(iOS)
        NavigationLink("播放手势") { GestureSettingsView() }
        #endif
        NavigationLink("界面偏好") { InterfaceSettingsView() }
    }
}

// MARK: - 播放设置

/// 播放内核选项卡片：名称、测试标签、能力说明与选中对勾（参考 Forward 的内核设置）。
private struct EngineOptionRow: View {
    let mode: PlaybackEngineMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.body.weight(.semibold))
                    Text(mode.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension PlaybackEngineMode {
    /// 与能力矩阵一致的简要说明；矩阵变化时同步修改。
    var summary: String {
        switch self {
        case .auto:
            "推荐。优先 AVPlayer 内核（硬件解码、最省电），MKV 等格式由服务器转封装；需要读取内嵌字幕时自动改用 KSPlayer。AVPlayer 播放失败时可选择「用 KSPlayer 内核重试」。"
        case .system:
            "始终使用 AVPlayer：原生 HDR / 杜比视界、空间音频、画中画、AirPlay 与 VR 转平面。不能直放的格式交给服务器处理。"
        case .ksPlayer:
            "基于 FFmpeg 直放原文件，同样硬件解码，支持画中画与 VR 转平面；不支持 AirPlay 视频，杜比视界按 HDR10 显示。"
        }
    }
}

/// 内核、续播、前后台行为、定位、预览、缓存与剧集。修改即时保存，多数选项在播放中即时生效。
struct PlayerSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                ForEach(PlaybackEngineMode.allCases, id: \.self) { mode in
                    EngineOptionRow(mode: mode, isSelected: prefs.engineMode == mode) {
                        prefs.engineMode = mode
                    }
                }
            } header: {
                Text("播放内核")
            } footer: {
                Text("切换后重新进入播放器生效；播放中可在「更多 → 切换内核」立即换用。")
            }

            Section {
                Toggle("从上次进度播放", isOn: $prefs.resumePlayback)
                #if os(iOS)
                Toggle("切后台继续播放音频", isOn: $prefs.backgroundAudio)
                Toggle("回到前台自动播放", isOn: $prefs.resumeOnForeground)
                Toggle("暂停后自动锁屏", isOn: $prefs.lockWhenPaused)
                #endif
            }

            #if os(iOS)
            Section {
                Toggle("后台自动画中画", isOn: $prefs.autoPictureInPicture)
            } footer: {
                Text("需先在系统「设置 → 通用 → 画中画」中开启「自动开启画中画」。下次进入播放器生效。")
            }
            #endif

            Section {
                Toggle("精准定位进度", isOn: $prefs.preciseSeek)
            } footer: {
                Text("可提高调节进度的时间准确度，但可能影响定位的速度（需要从关键帧开始解码）。")
            }

            Section {
                Picker("快退时间", selection: $prefs.seekBackwardSeconds) {
                    ForEach(PlayerPreferences.seekIntervals, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("快进时间", selection: $prefs.seekForwardSeconds) {
                    ForEach(PlayerPreferences.seekIntervals, id: \.self) { Text("\($0) 秒").tag($0) }
                }
            } footer: {
                Text("对所有用到「快退快进」的功能均生效。")
            }

            Section {
                Picker("进度条预览", selection: $prefs.scrubPreview) {
                    ForEach(ScrubPreviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("预缓冲时长", selection: $prefs.forwardBufferSeconds) {
                    ForEach(PlayerPreferences.forwardBufferOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "自动" : "\(seconds) 秒").tag(seconds)
                    }
                }
            } header: {
                Text("播放缓存")
            } footer: {
                Text("自动：由播放内核按网络情况决定。8K VR 等高码率片源频繁卡顿时可调大。下次起播生效。")
            }

            Section {
                Picker("预加载下一集", selection: $prefs.preloadNextPercent) {
                    ForEach(PlayerPreferences.preloadOptions, id: \.self) { percent in
                        Text(percent == 0 ? "禁用" : "播放到 \(percent)%").tag(percent)
                    }
                }
                Toggle("自动跳过片头", isOn: $prefs.autoSkipIntro)
                Toggle("自动播放下一集", isOn: $prefs.autoPlayNext)
            } header: {
                Text("剧集")
            } footer: {
                Text("预加载：播放到指定进度后提前向服务器请求下一集，让服务器提前打开文件或开始转码；成功后「下一集」按钮旁显示闪电标记。片头片尾数据来自服务器（Jellyfin 10.10+ 媒体片段或 Emby 章节标记）。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("播放设置")
    }
}

// MARK: - 视频设置

struct VideoSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                Picker("首选解码模式", selection: $prefs.decodeMode) {
                    ForEach(DecodeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("软件解码线程", selection: $prefs.softwareDecodeThreads) {
                    ForEach(PlayerPreferences.decodeThreadOptions, id: \.self) { Text($0 == 0 ? "自动" : "\($0)").tag($0) }
                }
                .disabled(prefs.decodeMode == .hardware)
            } header: {
                Text("解码（KSPlayer 备选内核）")
            } footer: {
                Text("硬解码：高效省电，基本不发热，能否硬解取决于你的设备及系统。\n软解码：兼容性强，解码稳定，但播放大文件容易发热且耗电量高。\n除非无法正常播放，否则不要使用软解码！AVPlayer 内核始终使用硬件解码。")
            }

            Section("视频截图") {
                Picker("截图格式", selection: $prefs.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if prefs.screenshotFormat != .png {
                    Stepper(value: $prefs.screenshotQuality, in: 0.1...1, step: 0.1) {
                        LabeledContent("\(prefs.screenshotFormat == .heic ? "HEIC" : "JPEG") 图像质量", value: "\(Int((prefs.screenshotQuality * 100).rounded()))%")
                    }
                }
                #if os(iOS)
                Toggle("自动保存到相册", isOn: $prefs.screenshotSavesToPhotos)
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("视频设置")
    }
}

// MARK: - 音频设置

struct AudioSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                Toggle("记住所选音轨", isOn: $prefs.rememberAudioTrack)
                LanguagePicker(title: "音频首选语言", selection: $prefs.preferredAudioLanguage)
            } footer: {
                Text("记住：在某部剧或电影中手动切换音轨后，下次播放同一作品时优先选择同一语言。")
            }
            Section {
                Toggle("杜比全景声", isOn: $prefs.enableAtmos)
            } footer: {
                Text("支持原生杜比 E-AC3 Atmos 音频直通；关闭后由服务器转换为 AC3 / AAC。下次起播生效。")
            }
            Section {
                Toggle("原生音频", isOn: $prefs.nativeAudio)
            } footer: {
                Text("多声道原样输出，获得最佳的多声道及空间音频效果；关闭后由服务器下混为立体声。下次起播生效。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("音频设置")
    }
}

// MARK: - 字幕设置

struct SubtitleSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                Toggle("记住所选字幕", isOn: $prefs.rememberSubtitle)
                LanguagePicker(title: "字幕首选语言", selection: $prefs.preferredSubtitleLanguage)
            } footer: {
                Text("记住：手动选择的字幕语言（包括「关闭」）在同一作品的后续播放中沿用。图形字幕需要服务器烧录，不会自动开启。")
            }

            Section {
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
            } header: {
                Text("样式")
            } footer: {
                Text("播放时也可在字幕面板中实时调整。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("字幕设置")
    }
}

private struct LanguagePicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(PlayerPreferences.languageOptions, id: \.code) { Text($0.title).tag($0.code) }
        }
    }
}

// MARK: - 播放手势

#if os(iOS)
struct GestureSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                Toggle("双指缩放画面", isOn: $prefs.pinchToZoom)
                Toggle("记住缩放大小", isOn: $prefs.rememberZoom)
                    .disabled(!prefs.pinchToZoom)
                Toggle("双指移动画面", isOn: $prefs.twoFingerPan)
                Toggle("双指单击重置画面", isOn: $prefs.twoFingerTapReset)
            } footer: {
                Text("关闭「双指缩放画面」时，捏合在适应与填充之间切换。")
            }

            Section {
                Toggle("水平滑动调节进度", isOn: $prefs.enableSwipeSeek)
            }

            Section {
                Toggle("左边垂直滑动调节亮度", isOn: $prefs.enableBrightnessSwipe)
                Toggle("右边垂直滑动调节音量", isOn: $prefs.enableVolumeSwipe)
                Toggle("中间垂直滑动切换媒体", isOn: $prefs.enableSwipeSwitchMedia)
            } footer: {
                Text("切换媒体：在屏幕中间上滑播放下一集，下滑播放上一集。")
            }

            Section {
                Toggle("长按播放暂停键退出播放器", isOn: $prefs.longPressPlayPauseExits)
            }

            Section {
                SpeedPicker(title: "长按/双击 左边屏幕倍速", selection: $prefs.leadingSpeed)
                SpeedPicker(title: "长按/双击 右边屏幕倍速", selection: $prefs.trailingSpeed)
            } header: {
                Text("倍速播放速度设置")
            } footer: {
                Text("对长按屏幕倍速和双击手势「倍速播放」生效。")
            }

            Section("单击手势") {
                TapActionPicker(title: "单击屏幕中间", selection: $prefs.singleTapCenter, allowed: [.toggleControls, .playPause, .none])
                TapActionPicker(title: "单击屏幕两边", selection: $prefs.singleTapSides, allowed: [.toggleControls, .playPause, .none])
            }

            Section("双击手势") {
                TapActionPicker(title: "双击屏幕中间", selection: $prefs.doubleTapCenter, allowed: [.playPause, .toggleControls, .speed, .none])
                TapActionPicker(title: "双击屏幕两边", selection: $prefs.doubleTapSides, allowed: [.seek, .playPause, .speed, .none])
            }

            Section("震动反馈") {
                Toggle("长按屏幕", isOn: $prefs.hapticLongPress)
                Toggle("滑动调节进度", isOn: $prefs.hapticSwipeSeek)
                Toggle("拖动进度条", isOn: $prefs.hapticScrubBar)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("播放手势")
    }
}

private struct SpeedPicker: View {
    let title: String
    @Binding var selection: Float

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(PlayerPreferences.speedOptions, id: \.self) { Text(String(format: "%.2f X", $0)).tag($0) }
        }
    }
}

private struct TapActionPicker: View {
    let title: String
    @Binding var selection: PlayerTapAction
    let allowed: [PlayerTapAction]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(allowed, id: \.self) { Text($0.title).tag($0) }
        }
    }
}
#endif

// MARK: - 界面偏好

struct InterfaceSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                NavigationLink("OSD 信息显示") { OSDSettingsView() }
                NavigationLink("自定义播放器按钮") { PlayerButtonsSettingsView() }
            }

            #if os(iOS)
            Section {
                Toggle("播放器独立亮度", isOn: $prefs.independentBrightness)
            } header: {
                Text("亮度")
            } footer: {
                Text("开启后播放器内调节的亮度单独记住，退出播放器时恢复系统亮度。")
            }
            #endif

            Section("控制栏") {
                Picker("进度条时间模式", selection: $prefs.progressTimeMode) {
                    ForEach(ProgressTimeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("自动隐藏", selection: $prefs.autoHideSeconds) {
                    ForEach(PlayerPreferences.autoHideOptions, id: \.self) { Text($0 == 0 ? "从不" : "\($0) 秒").tag($0) }
                }
            }

            #if os(iOS)
            Section("屏幕方向") {
                Picker("进入播放器屏幕方向", selection: $prefs.orientationOnEnter) {
                    ForEach(PlayerOrientation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("切换视频后屏幕方向", selection: $prefs.orientationOnSwitch) {
                    ForEach(PlayerOrientation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("设备横屏方向", selection: $prefs.landscapeSide) {
                    ForEach(LandscapeSide.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            #endif

            Section("提示信息") {
                Toggle("即将跳过片头/片尾", isOn: $prefs.hintBeforeSkip)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("界面偏好")
    }
}

private struct OSDSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section("OSD") {
                Toggle("系统时间", isOn: $prefs.osd.clock)
                Toggle("实时帧率", isOn: $prefs.osd.frameRate)
                Toggle("设备网速", isOn: $prefs.osd.networkSpeed)
                Toggle("播放速度", isOn: $prefs.osd.playbackSpeed)
                Toggle("播放时间", isOn: $prefs.osd.playbackTime)
                Toggle("CPU 占用", isOn: $prefs.osd.cpuUsage)
                #if os(iOS)
                Toggle("设备电量", isOn: $prefs.osd.battery)
                #endif
            }
            Section {
                Toggle("文字背景", isOn: $prefs.osd.textBackground)
                Picker("文字大小", selection: $prefs.osd.textSize) {
                    ForEach(OSDTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("紧贴两侧显示", isOn: $prefs.osd.hugEdges)
                Toggle("仅横屏显示", isOn: $prefs.osd.landscapeOnly)
            } header: {
                Text("高级设置")
            } footer: {
                Text("设置 OSD 过多可能遮挡画面；CPU 占用为本应用所有线程之和。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("OSD 信息显示")
    }
}

private struct PlayerButtonsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.playerPreferences
        Form {
            Section {
                Toggle("快退快进按钮", isOn: $prefs.buttons.seek)
                Toggle("切换媒体按钮", isOn: $prefs.buttons.switchMedia)
                Toggle("播放暂停按钮", isOn: $prefs.buttons.playPause)
                Toggle("画面缩放按钮", isOn: $prefs.buttons.zoom)
                #if os(iOS)
                Toggle("旋屏按钮", isOn: $prefs.buttons.rotate)
                #endif
                Toggle("画中画按钮", isOn: $prefs.buttons.pictureInPicture)
                Toggle("章节选择按钮", isOn: $prefs.buttons.chapters)
                Toggle("速度调节按钮", isOn: $prefs.buttons.speed)
                Toggle("投屏按钮", isOn: $prefs.buttons.cast)
                Toggle("截图按钮", isOn: $prefs.buttons.screenshot)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("自定义播放器按钮")
    }
}
