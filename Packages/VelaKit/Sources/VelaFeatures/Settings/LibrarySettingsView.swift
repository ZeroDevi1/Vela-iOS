import SwiftUI
import VelaCore

/// 「媒体库配置」：首页、继续观看、列表、海报与详情页的显示偏好，修改即时生效。
struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.libraryPreferences
        Form {
            Section("首页配置") {
                Toggle("显示我的媒体", isOn: $prefs.showMyMedia)
                Toggle("显示轮播图片", isOn: $prefs.showHero)
                Toggle("隐藏已观看项目", isOn: $prefs.hideWatched)
            }

            Section("继续观看") {
                Toggle("显示继续观看", isOn: $prefs.showResume)
                Toggle("显示接下来观看", isOn: $prefs.showNextUp)
                Toggle("使用“集”图片", isOn: $prefs.useEpisodeImages)
                Toggle("显示播放按钮", isOn: $prefs.showPlayButton)
            }

            Section("列表") {
                Toggle("列表中显示合集", isOn: $prefs.showCollections)
                Picker("混合内容优先展示视图", selection: $prefs.mixedContentView) {
                    ForEach(LibraryPreferences.MixedContentView.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("视频首选版本", selection: $prefs.preferredVersion) {
                    ForEach(MediaVersionPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("展示") {
                Picker("轮播图展示", selection: $prefs.heroStyle) {
                    ForEach(LibraryPreferences.ArtworkStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("详情页展示", selection: $prefs.detailHeaderStyle) {
                    ForEach(LibraryPreferences.ArtworkStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("海报偏好") {
                Picker("名称对齐方式", selection: $prefs.titleAlignment) {
                    ForEach(LibraryPreferences.TitleAlignment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("显示社区评分", isOn: $prefs.showRating)
                Toggle("显示已播放标记", isOn: $prefs.showPlayedMark)
                Toggle("显示剩余播放数量", isOn: $prefs.showUnplayedCount)
            }

            Section("详情页") {
                Toggle("显示演职人员", isOn: $prefs.showCast)
                Toggle("显示选集指示器", isOn: $prefs.showEpisodeIndicator)
                Toggle("显示媒体信息", isOn: $prefs.showMediaInfo)
                Toggle("显示豆瓣链接", isOn: $prefs.showDoubanLink)
                Toggle("显示类似作品", isOn: $prefs.showSimilar)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("媒体库配置")
    }
}
