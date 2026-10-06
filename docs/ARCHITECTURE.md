# Vela for Apple 平台：分析、架构与开发计划

目标设备：iPhone 16 Pro（A18 Pro）、iPad Pro 11" 2022（M2）、MacBook Air 13" M4。
系统：iOS / iPadOS / macOS 27（部署目标 27.0）。技术栈：Swift 6、SwiftUI，按需桥接 UIKit / AppKit，不使用 Catalyst。

---

## 1. Vela（JellyCine）Android 版特征提取

源仓库：`../JellyCine`（Kotlin Multiplatform，phone / tv / data / core / shared）。

| 领域 | Android 实现要点 | Apple 版对应 |
|---|---|---|
| 服务器 | Jellyfin + Emby；`SavedServer` 身份 = 服务器 + 用户；备注替换显示名 | `VelaCore.SavedServer`，id = `instanceID\|userID` |
| 多线路 | 一个账号多条 Line（LAN / WAN / 备用），按网络自动路由，失败切换并冷却 | `ServerLine` + `LineRouting` / `LineCooldown`（纯逻辑）+ `LineRouter`（`NWPathMonitor` + 并发探测 + 冷却） |
| 隐私服务器 | 系统锁屏验证；解锁只在进程内存；FLAG_SECURE 防截屏；未解锁不建页面 | `PrivacyGuard`（LocalAuthentication）+ `PrivacyGate` + 后台切换遮挡 |
| 聚合搜索 | 多服务器并发、限并发 4、单源失败不影响整体；扩展 TMDB / 豆瓣源 | `FederatedSearchService`（TaskGroup 限流），TMDB 源待做 |
| 播放器 | MPV 主 + ExoPlayer 回退；HDR10 / HDR10+ / DV；DV7→8.1；音频直通 | `PlaybackEngine` 协议；AVPlayer 默认，KSPlayer（FFmpeg）备选 |
| 选流 | DeviceProfile + PlaybackInfo；STRM 原始地址直连 | `DeviceProfile.avFoundation` + `PlaybackResolver` |
| VR 转平面 | 文件名 / 标签 / 宽高比严格识别；GLSL 反投影；拖动看视角、捏合调 FOV | `VRLayoutParser` + `VRRenderer`（Metal 反投影，两种内核共用：`VRFrameSource` 从视频输出或 KSPlayer 解码帧取图） |
| 手势 | 单击显隐；两侧双击快退快进（2:1:2）；中间双击暂停；横滑进度；左亮度右音量；长按倍速；捏合缩放；锁定 | `PlayerGestureModel`（纯逻辑）+ iOS UIKit 识别器 + macOS 键鼠 |
| 画中画 | Android PiP | `AVPictureInPictureController`，支持后台自动进入 |
| 发现 / 目录 | TMDB 趋势、分类、查看全部；目录条目 ≠ 库条目，靠 provider id 精确匹配 | `CatalogRequest` / `CatalogIdentity`（Core）+ `TMDBClient`（Network）+ `CatalogService`（Data：凭据、匹配、跨服务器继续观看） |
| 订阅 / 日历 | MoviePilot 为真相源，Bangumi 公开回退 | 占位，M5 |
| Trakt | OAuth、scrobble | M7 |
| 下载 | 队列、转码下载 | M8（`AVAssetDownloadURLSession`） |
| 跳过片头 | IntroDB / Media Segments | 已实现（MediaSegments + Emby 章节标记） |

**原则延续**：不用标题模糊匹配冒充身份；不用空列表冒充失败；单源失败局部提示；token 不落普通存储。

---

## 2. 架构

```
Vela.xcodeproj             单一多平台 App target（iOS / iPadOS / macOS 原生）
├─ Vela/                   同步文件夹：入口 VelaApp.swift、资源（新增文件无需改工程）
├─ Config/Vela-Info.plist  后台音频、ATS 例外等数组 / 字典键
└─ Packages/VelaKit/       本地 SPM 包，全部业务代码
   ├─ VelaCore             领域模型、线路路由、日志、能力模型（无 UI、无网络）
   ├─ VelaNetwork          HTTP、鉴权头、Jellyfin/Emby 客户端、DTO、DeviceProfile
   ├─ VelaData             ServerStore（JSON + Keychain）、登录、聚合搜索、隐私、选流
   ├─ VelaPlayer           PlaybackEngine、AVPlayer 内核、控制器、手势模型、VR、画中画
   ├─ VelaDesignSystem     主题令牌、海报 / 横幅卡、分区
   └─ VelaFeatures         各页面与 AppModel（依赖注入容器）
```

依赖方向只允许自上而下：`Features → Data / Player / DesignSystem → Network → Core`。
Player 不依赖 Network：服务器相关信息在 Features 中转换为 `PlaybackSource` 后交给内核。

### 关键设计

- **并发**：Swift 6 严格并发。网络 client 为值类型 `Sendable`，可在任意 Task 使用；状态对象（`ServerStore`、`PlayerController`、`AppModel`）为 `@MainActor @Observable`。
- **依赖注入**：`AppModel` 在 App 入口创建一次，经 `.environment` 下发；页面不创建单例。
- **播放入口**：`@Environment(\.playMedia)`。iPhone / iPad 全屏覆盖；macOS 用 `openWindow` 打开独立播放器窗口（可单独全屏、与浏览窗口并排）。
- **内核可替换**：`PlaybackEngine` 协议 + `PlaybackSurface` 枚举；新增内核只需实现协议并提供自己的 surface（KSPlayer 为 `.view`，直放原文件不依赖 DeviceProfile）。
- **选流**：PlaybackInfo 携带按设备实测（VideoToolbox / AVPlayer）生成的 DeviceProfile；能直放就直放，否则由服务器转封装为 HLS fMP4，视频流复制，保留 HDR / DV 元数据。
- **字幕**：文本字幕统一请求服务器转 WebVTT（`/Videos/{id}/{source}/Subtitles/{index}/Stream.vtt`）由客户端渲染；DeviceProfile 把文本字幕声明为 External 并默认传 `SubtitleStreamIndex=-1`，避免服务器因字幕自行烧录导致转码。
- **播放上报**：`PlaybackReporter` 串行发送，失败只记日志不影响播放；结束即上报 Stopped。
- **安全**：token 存 Keychain（`ThisDeviceOnly`）；服务器列表 JSON 只含非敏感字段；日志不输出 token / 带鉴权的 URL。

### Apple 平台特性落点

| 特性 | 位置 |
|---|---|
| Liquid Glass | `TabView` + `.sidebarAdaptable`、`.tabBarMinimizeBehavior`、`Tab(role: .search)`；播放器 `.glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)`；详情页 `.backgroundExtensionEffect()` |
| iPad / Mac 侧边栏 | `sidebarAdaptable` 自动切换 |
| macOS 规范 | 独立播放器窗口、`Settings` 场景（⌘,）、键盘快捷键（空格 / ← → / F / Esc） |
| HDR / 杜比视界 | AVPlayer 原生输出；`PlaybackCapabilityProbe` 决定是否声明 DV / AV1 |
| 空间音频 / AirPlay | AVPlayer 原生；`AVRoutePickerView` |
| 画中画 | `AVPictureInPictureController(playerLayer:)`，iOS 后台自动进入 |

---

## 3. 播放内核选型

| 内核 | 优势 | 劣势 | 定位 |
|---|---|---|---|
| **AVPlayer** | HDR10 / DV 5、8.x / HLG 系统级输出、EDR、空间音频、PiP、AirPlay、省电 | 不支持 MKV 容器、ASS 特效字幕、DV7 双层 | **默认**：配合服务器 remux，覆盖绝大多数片源且画质最佳 |
| **KSPlayer（KSMEPlayer：FFmpeg + VideoToolbox + `AVSampleBufferDisplayLayer`）** | 格式全（MKV 直放）、硬解、画中画、可取解码帧（VR 转平面复用同一 Metal 着色器）；GPL-3.0 与本项目兼容 | GPL 版不含 libass 图像化 ASS 特效与部分高级功能；DV 按 HDR10 显示；不支持 AirPlay 视频 | **第二内核**：MKV 直放、系统内核解不出画面时兜底 |
| MPV（MPVKit） | 格式全、ASS 特效 | 自带一套 FFmpeg，与 KSPlayer 的 FFmpegKit 不能同时链接；无 PiP、VR 需额外取帧 | 已由 KSPlayer 取代（2026-10） |

策略：设置中可选「自动 / 系统 / KSPlayer」。自动模式始终用系统内核（服务器 remux / 转码）；系统内核失败或解不出画面时可「用 KSPlayer 重试」，超过本机硬解上限的片源可「服务器转码为 4K」（DeviceProfile 的 `Width` 条件）。

---

## 4. 里程碑

完成情况、已知问题与后续排期见 [ROADMAP.md](ROADMAP.md)。

---

## 5. 开发约定

- 构建：`xcode-select` 指向 CommandLineTools 时，命令前加
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。
- 包单测：`cd Packages/VelaKit && swift test`。
- 新增功能放在对应模块；跨模块共享的纯逻辑优先放 Core 并写单测。
- 签名：工程未设置 `DEVELOPMENT_TEAM`，真机运行前在 Xcode 中选择团队；配置团队后可让 `KeychainStore` 在 macOS 启用 data protection keychain。
