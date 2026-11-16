<p align="center">
  <img src="Vela/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="Vela" width="140">
</p>

<h1 align="center">Vela for iOS / iPadOS / macOS</h1>

<p align="center">
  面向 <strong>Jellyfin</strong>、<strong>Emby</strong> 与 <strong>Navidrome</strong> 的 Apple 原生客户端，Swift 6 + SwiftUI，适配 iOS / iPadOS / macOS 27 与 Liquid Glass。
</p>

Android 版见 [ZeroDevi1/Vela](https://github.com/ZeroDevi1/Vela)（基于 [JellyCine](https://github.com/sureshfizzy/JellyCine)）。本仓库按 Android 版的功能与约定在 Apple 平台上原生实现，不共享代码。

安装包见 [GitHub Releases](https://github.com/ZeroDevi1/Vela-iOS/releases)。iPhone 和 iPad 共用一个需自行签名的 IPA，Mac 使用通用 ZIP。设备需运行 iOS、iPadOS 或 macOS 27 及以上版本。

> 当前状态：应用大框架基本完成（M0–M8 代码完成，界面已与 Android 版对齐），待实机逐项验收（各项状态见路线图）。进度与排期见 [docs/ROADMAP.md](docs/ROADMAP.md)。

---

## 功能

### 服务器

- 同时支持 Jellyfin 与 Emby；添加时自动补全 `https` / `http` 与 Emby 的 `/emby` 路径，并识别服务器类型
- 多服务器切换；Jellyfin / Emby 支持多条线路（局域网 / 公网）和 STRM 原始地址直连
- **私密服务器**：每次启动后需面容 ID / 触控 ID / 密码解锁，解锁状态只在内存中保存；进入多任务切换器时遮挡内容；与 Android 版一致，私密服务器（无论是否解锁）不参与聚合搜索、跨服匹配与聚合继续观看
- 登录凭据保存在 Keychain（仅本机），服务器列表 JSON 不保存凭据

### Navidrome 音乐

- 在「添加服务器」选择 Navidrome，填写基址及账号密码，或使用支持 API 密钥的服务器签发的密钥。基址支持反代子路径；省略协议默认使用 HTTPS，使用 HTTP 时需写出 `http://`。
- 独立音乐界面支持分库浏览、搜索、收藏与评分、歌单编辑、书签，以及在 Navidrome 保存或恢复播放队列。
- 迷你播放器和系统媒体控制共享同一播放会话，支持原流与兼容 MP3 转码。歌词有逐字时间时渐进填色，普通 LRC 按行高亮，纯文本可阅读；点击同步歌词可跳转。
- 音乐设置按服务端能力和当前账号权限显示共享、电台管理、扫描和 Jukebox。可按权限下载并导出原始文件。参见 [公开接口覆盖范围](docs/ROADMAP.md#navidrome-音乐)。

### 浏览

- 导航与 Android 版一致：底栏 首页 / 我的媒体 / 搜索 / 收藏 / 设置（iPad / Mac 侧边栏另有发现、订阅；iPhone 从设置页进入）
- 首页：分类胶囊（首页 / 电影 / 剧集）、线路切换、投屏、头像菜单；卡片式轮播（Logo + 评分 / 年份 / 类型 / 分级）；媒体库、继续观看（剩余时长）、接下来、各库「最近添加」；电影 / 剧集分类按风格分区
- 我的媒体：媒体库大卡片网格；媒体库页分 全部 / 推荐 / 类型 / 文件夹，工具条含条目数、随机播放、海报 / 横版样式、观看状态筛选、排序（再选同一项切换方向）
- 收藏：电影 / 剧集 / 单集分区
- **聚合搜索**：同时搜索所有非私密服务器，限制并发，单个服务器失败只在其分区提示；未输入时显示沉浸式随机推荐
- **详情页**：沉浸式头图与 Logo、评分 / 分级 / 类型 / 连载状态、继续播放与进度、已看 / 收藏；剧集的季与按 50 集分段的单集列表；播放源（版本 / 音轨 / 字幕）预选；章节缩略图、演职人员、类似作品、外部链接；视频 / 音频 / 字幕流的完整媒体信息

### 播放

- 系统内核 AVPlayer：HDR10 / 杜比视界（Profile 5、8.x）/ HLG 原生输出，空间音频、画中画、AirPlay
- 按设备实测能力（AV1 / HEVC 硬解、HDR）生成 DeviceProfile：能直放就直放；MKV 等由服务器转封装为 HLS fMP4，视频流复制不损画质
- 字幕：文本字幕（内嵌 / 外挂、SRT / ASS 等）由服务器转 WebVTT 后本地渲染，可调字号、位置与延迟；图形字幕可选服务器烧录
- 播放器界面：章节 / 剧集 / 音轨 / 字幕 / 播放信息侧面板，音轨与字幕显示中文语言名、采样率、码率；拖动进度时本地解码预览画面（不依赖服务器 trickplay）；截图、画面旋转、适应 / 填充 / 拉伸
- 音轨切换、跳过片头 / 回顾（Jellyfin 媒体片段、Emby 章节标记，可自动跳过）、下一集倒计时自动播放
- 播放进度与已看状态同步到服务器；锁屏 / 控制中心正在播放与远程控制
- **手势**（iPhone / iPad）：单击显隐控制层；左 / 右侧双击快退 / 快进、中间双击暂停；横滑调进度；左侧竖滑亮度、右侧竖滑音量；长按临时倍速；捏合切换适应 / 填充；锁定
- **macOS**：独立播放器窗口，空格 / ← → / F / Esc 快捷键，双击全屏

### 平台

| 平台 | 目标设备 | 说明 |
|---|---|---|
| iOS 27 | iPhone 16 Pro | 底部 Liquid Glass 标签栏，下滑自动收起 |
| iPadOS 27 | iPad Pro 11"（2022） | 可展开侧边栏，支持多窗口 |
| macOS 27 | MacBook Air 13"（M4） | 原生 SwiftUI（非 Catalyst），系统「设置」窗口（⌘,） |

---

## 构建

需要 Xcode 27（iOS / macOS 27 SDK）。

0. 首次构建前拉取 KSPlayer 内核及其 FFmpegKit 依赖（约 1.4 GB，固定版本，不入库）：`./scripts/fetch-ksplayer.sh`
1. 打开 `Vela.xcodeproj`，选择 `Vela` scheme
2. 目标选择 iPhone / iPad 模拟器或 My Mac 运行
3. 真机运行前在 Signing & Capabilities 中选择开发团队（仓库未配置 `DEVELOPMENT_TEAM`）

命令行：

```bash
xcodebuild -project Vela.xcodeproj -scheme Vela -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

```bash
xcodebuild -project Vela.xcodeproj -scheme Vela -destination 'platform=macOS' build
```

包单元测试（Swift Testing）：

```bash
cd Packages/VelaKit && swift test
```

若 `xcode-select` 指向 CommandLineTools，可在命令前加 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。

### GitHub Actions 构建产物

[Build Apple Apps](.github/workflows/build.yml) 在每次 push 时构建，也可从 Actions 页面手动运行。使用 GitHub 的 [`xcode-27` runner](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) 和 Xcode 27.0，复用 `scripts/fetch-ksplayer.sh` 准备并缓存播放器依赖。

构建完成后，打开仓库 **Actions → Build Apple Apps → 对应运行 → Artifacts** 下载，保留 14 天：

| 产物 | 支持平台 | 签名与安装 |
|---|---|---|
| `Vela-iOS-iPadOS-unsigned.ipa` | iPhone / iPad（同一份通用 IPA） | 未签名，需用自己的证书或侧载工具签名后安装，不能直接安装 |
| `Vela-macOS-universal.zip` | macOS，arm64 / x86_64 通用二进制 | ad-hoc 签名，未公证；下载后可能需要在「系统设置 → 隐私与安全性」允许打开 |

日常构建无需配置签名 Secrets。某个平台构建失败时，另一个平台继续构建，并上传失败平台的日志与 `.xcresult`（保留 7 天）。

本地可使用同一入口验证打包（先准备播放器依赖）：

```bash
bash scripts/ci-build.sh ios
bash scripts/ci-build.sh macos
```

默认输出到 `build/ci/<平台>/`；再次构建前需移走该目录的 `Build.xcresult`，或通过 `VELA_CI_BUILD_ROOT` 指定新的构建目录。

### 部署 Release 版到真机

前提：设备系统为 iOS / iPadOS / macOS 27 或更高（部署目标 27.0）；已执行 `scripts/fetch-ksplayer.sh` 拉取 KSPlayer 与 FFmpegKit。

#### iPhone / iPad（Xcode）

1. Xcode 打开 `Vela.xcodeproj` → 选中 `Vela` target → Signing & Capabilities：勾选 Automatically manage signing，Team 选你的 Apple ID（免费账号也可）；Bundle Identifier 冲突时改成自己的，例如 `com.<你的名字>.vela`
2. Product → Scheme → Edit Scheme… → Run → Info → Build Configuration 改为 **Release**（取消 Debug executable）
3. 用数据线连接设备并在设备上点「信任此电脑」；首次需在「设置 → 隐私与安全性 → 开发者模式」开启并重启
4. Xcode 顶部设备列表选中该设备，⌘R。Xcode 会自动把设备注册到你的团队并重新生成描述文件
5. 首次启动提示「不受信任的开发者」：设备「设置 → 通用 → VPN 与设备管理」信任你的开发者证书

每台新设备（例如再加一台 iPad）重复 3～5 即可，无需改代码。免费账号的限制：描述文件 **7 天**过期（过期后重新 ⌘R 安装即可，数据保留），同一团队最多注册 3 台同类设备；付费开发者账号为 1 年。

#### iPhone / iPad（命令行）

```bash
xcrun devicectl list devices
```

记下设备的 UDID（Xcode → Window → Devices and Simulators 中的 Identifier），然后：

```bash
xcodebuild -project Vela.xcodeproj -scheme Vela -configuration Release -destination 'id=<设备 UDID>' -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM=<你的 Team ID> build
```

```bash
xcrun devicectl device install app --device <devicectl 列出的设备 Identifier> build/Build/Products/Release-iphoneos/Vela.app
```

首次给新设备构建时 `-allowProvisioningUpdates` 会自动注册设备；设备需已开启开发者模式并信任这台 Mac。iPad 与 iPhone 命令相同，只换成 iPad 的 UDID / Identifier。

注意 `xcodebuild -destination 'id=…'` 用的是设备 **UDID**（如 `00008140-…`），`devicectl --device` 用的是 `xcrun devicectl list devices` 列出的 **Identifier**（如 `0FE1D33C-…`），两者不同。

安装后启动（设备需解锁）：

```bash
xcrun devicectl device process launch --device <devicectl 列出的设备 Identifier> com.zerodevi1.vela
```

排查播放 / 字幕问题时带日志启动，终端会实时输出播放器日志（`Log.player`，含内核选择、字幕加载与耗时）：

```bash
xcrun devicectl device process launch --device <devicectl 列出的设备 Identifier> --terminate-existing --console --environment-variables '{"OS_ACTIVITY_DT_MODE":"YES"}' com.zerodevi1.vela
```

#### MacBook（原生 macOS 版）

在要使用的 Mac 上直接构建最简单：

1. 该 Mac 安装 Xcode 27，克隆仓库并执行 `scripts/fetch-ksplayer.sh`
2. Xcode 顶部目标选 **My Mac**，Scheme 的 Build Configuration 改为 Release，⌘R；或 Product → Archive → Distribute App → Custom → Copy App，得到可放进「应用程序」的 `Vela.app`

命令行（本机构建并装到「应用程序」）：

```bash
xcodebuild -project Vela.xcodeproj -scheme Vela -configuration Release -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM=<你的 Team ID> build
```

```bash
ditto build/Build/Products/Release/Vela.app /Applications/Vela.app
```

把一台 Mac 上构建的 `Vela.app` 拷到另一台 Mac：

- 免费账号无法公证（notarize），拷过去后 Gatekeeper 会拦截。在目标 Mac 上右键 `Vela.app` → 打开，或到「系统设置 → 隐私与安全性」点「仍要打开」；必要时执行 `xattr -dr com.apple.quarantine /Applications/Vela.app`
- 开发证书签名的 App 带描述文件，只能在已注册到团队的 Mac 上运行：目标 Mac 先用 Xcode 运行一次（会自动注册），或改为自行构建
- 付费开发者账号可用 Developer ID 签名并公证，分发给任意 Mac

测试完把 Scheme 的 Build Configuration 改回 Debug，日常调试更快。TMDB 内置凭据可通过构建设置 `VELA_TMDB_API_KEY` 注入（target Build Settings → User-Defined），或在 App 内「设置 → 探索 → 发现」页填写。

---

## 目录结构

```
Vela.xcodeproj          多平台 App target（同步文件夹，新增文件无需改工程）
Vela/                   App 入口（Scene / 窗口 / 设置）与资源
Config/Vela-Info.plist  后台音频、ATS 等
Packages/VelaKit/       全部业务代码（本地 Swift 包）
  VelaCore              领域模型、线路路由、日志
  VelaNetwork           Jellyfin / Emby / Navidrome 客户端、DTO、DeviceProfile
  VelaData              服务器存储、登录、聚合搜索、隐私、选流、播放上报
  VelaPlayer            播放内核协议、AVPlayer 内核、控制器、手势、字幕、VR、正在播放
  VelaDesignSystem      主题与通用卡片组件
  VelaFeatures          各页面与 AppModel
docs/                   架构与路线图
```

依赖方向：`Features → Data / Player / DesignSystem → Network → Core`。详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：Android 版特征映射、模块与关键设计、播放内核选型
- [docs/ROADMAP.md](docs/ROADMAP.md)：里程碑、已完成项、已知问题与后续排期

## 隐私

Vela 只与你添加的媒体服务器通信，不收集任何数据。账号 token 保存在本机 Keychain。

## 许可证

[GNU General Public License v3.0](LICENSE)，与 Vela / JellyCine 保持一致。
