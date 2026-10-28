# Peach Provider 接入计划

目标：在 Vela 中新增 [Peach](https://github.com/peach-mitao/peach) 服务器类型，覆盖 Peach Web 端的浏览、播放、互动、任务与设置功能。

本文依据 Peach `main` 分支源码（2026-10-28 浅克隆）与 Vela 当前代码编写。接口路径、参数与限制均引用 Peach 源文件；标「待验证」的项需要在真实 Peach 部署上确认后再实施。

---

## 1. 现状与结论

### Vela 侧

- 没有 Provider 抽象。`VelaNetwork/MediaServerClient.swift` 是 Jellyfin / Emby 专用的具体类型，Data 与 Features 层共 29 个文件、58 处直接引用；另有 67 处按 `kind == .emby / .jellyfin` 分支。
- `SavedServer.id = 实例 ID|用户 ID`，token 按 id 存 Keychain。
- `ImagePipeline.load(_ url:)` 只接收 URL，不能附加请求头。
- `PlaybackSource.httpHeaders` 已经存在，AVPlayer 通过 `AVURLAssetHTTPHeaderFieldsKey` 传递（`AVPlayerEngine.swift:67`）。
- 字幕已统一走 WebVTT（`VelaPlayer/Subtitles/WebVTT.swift`）。

### Peach 侧

- FastAPI 单体，单用户，没有账号体系（`SECURITY.md`）。`/api/{route}` 由 `web_router.py` 的 handler 表分派。
- 鉴权（`routes_auth.py:_authorized`）支持三种方式：
  - 访问口令：`X-Token` 请求头或 `?t=`，口令由 `peach token` 查看；
  - 访问密码：`POST /login` 设置会话 Cookie，最长 30 天；
  - 未设口令时开放访问。
- 写请求的同源检查（`routes_auth.py:141 same_origin`）只拒绝 `sec-fetch-site: cross-site` 或 Origin 不匹配的请求。原生 App 的请求不带这两个头，可以通过。
- 存在本机限定：
  - `/api/media-processing`、`/api/thumbnail-jobs`（`routes_api.py:316`）；
  - **全部 `/api/configuration*`、`/api/diagnostics*`**（`routes_configuration.py`，每个路由先调 `local_only`）。
- 本机判定（`web_local_access.py:local_client`）：
  - 桌面部署（Windows / macOS 托盘、源码 serve）只接受回环地址；
  - Linux 无桌面 / Docker（`PEACH_HEADLESS_MANAGED=1`）额外接受私有网段直连；
  - 两者都拒绝带转发头和经隧道的请求。

### 结论

1. 先做 Provider 抽象（P0），否则 Peach 只能在 58 处调用点逐个加分支。
2. 媒体浏览、播放、互动、播放列表、云下载提交、订阅 / 关注、来源凭据都走普通 `/api/*` 路由，手机可以远程调用。
3. **服务器配置（含下载渠道、115 / PikPak 登录、索引器、访问密码、公网入口、存储、更新）只有 Docker 私有网络部署能从手机调用**；桌面部署从手机调用一律返回 403。App 必须按实际响应降级，不能假设可写。

---

## 2. 关键难点

| 问题 | 依据 | 方案 |
|---|---|---|
| 自签 HTTPS | 源码部署用本机自签 CA 签发证书（`SECURITY.md`「网络暴露」） | API 与图片：`URLSessionDelegate` 首次连接展示 CA 指纹，用户确认后固定该指纹。AVPlayer 无法挂 TLS delegate：引导用户安装 `peach-local-ca.crt` 描述文件交给系统信任；未信任时播放失败要明确提示原因，不静默回退 |
| 账号身份 | Peach 单用户，未找到返回实例 ID 的接口 | `userID` 固定为 Peach 的 `DEFAULT_PROFILE_ID`。`serverInstanceID` 优先取 CA 证书公钥 SHA-256（同一 CA 重签证书不变，换地址也不变）；HTTP 部署（Windows 独立包）回退为添加时生成的 UUID，新增线路时提示用户确认是同一台服务器。**待验证**：重新 `peach init` 后 CA 是否会重建 |
| 登录凭据 | 两套凭据见上 | 口令优先，存 Keychain（`ThisDeviceOnly`），只放请求头，不拼进 URL。密码登录作为备选：`POST /login`（form 表单，`days=30`），保存会话 Cookie；收到 401 时提示重新登录 |
| 图片鉴权 | `/cover`、`/poster`、`/thumb`、`/avatar`、`/cover-image`、`/entity-image` 都需要鉴权（`routes_media.py`） | `ImagePipeline` 增加按 host 注入请求头的能力，磁盘缓存键不含凭据 |
| 播放鉴权 | `/stream`、HLS 分片需要鉴权 | AVPlayer 传 `X-Token` 请求头。KSPlayer 需要确认 FFmpeg `headers` 选项能否透传（**待验证**）；不能透传时改用 `POST /api/external-playback` 的限时票据地址（6 小时，单资产，不含长期凭据） |
| 切换类接口不幂等 | `feedback` 的 `seen` / `dislike` / `dispose`、`watch-later` 都是再调一次即取消（`web_activity.py`） | 以响应返回的状态为准刷新 UI，不在本地自行翻转；同一按钮请求进行中禁用 |
| 接口无版本契约 | 这些接口服务 Web 前端，没有版本号 | 登录与每次启动读 `GET /api/client-updates` 记录版本；DTO 宽松解码（未知字段忽略、缺字段给 nil）；版本超出已测范围时在服务器页提示 |
| 账本只读 | 双机复制冲突时写请求返回 409 `ledger read-only`（`routes_api.py:api_post`） | 统一识别该错误，展示响应里的 `message`，写操作入口置灰 |
| 本机限定 | 见第 1 节 | 统一识别 403「本机」类响应，显示「此项需在运行 Peach 的电脑上设置」，并提供「在 Peach 网页中打开」 |

---

## 3. Provider 抽象（P0）

- `MediaServerKind` 增加 `.peach`。
- 在 VelaNetwork 定义 `MediaProvider` 核心协议：媒体库、列表查询、详情、搜索、图片 URL、选流、进度上报、已看 / 收藏切换。
- 可选能力用独立协议表达，功能层通过 `as?` 判断能力，写法与 `PlaybackEngine` 的能力协议一致（`docs/PLAN.md`「内核抽象」）：
  - 通用：`PersonBrowsing`、`PlaylistManaging`、`SubtitleListing`、`EpisodeBrowsing`、`MediaSegmentProviding`；
  - Jellyfin / Emby：`ServerAdministering`、`MetadataEditing`；
  - Peach：`PeachTaskManaging`、`PeachFollowManaging`、`PeachConfigurationManaging` 等，见第 5 节。
- `AppModel.client(forServerID:)` 改为返回 `any MediaProvider`，缓存策略不变。29 个文件按模块迁移：Data（Search / Playback / Downloads）→ Home / Library → Detail → Player → 其余。
- `ServerLoginService` 拆成按类型的登录器：现有探测逻辑保留给 Jellyfin / Emby，Peach 另走探测流程（`GET /api/client-updates` → CA 指纹确认 → 口令或密码）。
- 备选方案是不抽象、在 Features 层按 `kind` 分支。不采用：58 处调用都要加分支，之后再接其他服务器还得重复一遍。
- 验收：`swift test` 全部通过；Jellyfin / Emby 的首页、详情、播放、搜索、下载行为不变。

---

## 4. 媒体功能（P1–P4）

### P1 接入与浏览

| Vela 功能 | Peach 接口 | 说明 |
|---|---|---|
| 媒体库列表 | `GET /api/libraries` | 返回 `id`、`name`、`icon`、`color`、`folders`、`metered`、`roots`；`metered` 媒体库在蜂窝网络下沿用 Vela 预缓冲限制 |
| 海报墙 | `GET /api/items` | `limit` 1–200（默认 60）、`offset`、`sort`、`dir`、`library`、`year`，`count=0` 不算总数改用 `has_more` |
| 详情 | `GET /api/item?id=` | 附 `root_id`、`library_id` |
| 首页各行 | `/api/items` 排序组合、`/watch-later` 对应筛选 | 最近播放、新入库、没看过、稍后看。具体参数在实施前对照 `web_catalog.catalog_filter` 与 `SORT_COLUMNS` 确认 |
| 来源在线状态 | `GET /api/sources` | `offline_roots` 中的根目录在卡片上标为离线，不当作加载失败 |

`PeachAssetDTO → MediaItem` 映射：

- 标题取 `catalog_title`，没有则用 `name`；番号 `code`；
- `duration`（秒）换算为 ticks；续播位置用 `leave_ratio × duration`；
- 已看 = `feedback == "seen"`；
- `release_date` 填 `premiereDate` 与 `productionYear`；
- `performers`、`studio`、`tags` 进现有字段；`width` / `height` 用于版本标签。

测试：用真实响应裁剪出 fixture JSON，写映射单测（放在 `VelaNetworkTests`）。

### P2 播放

| 功能 | 接口 | 说明 |
|---|---|---|
| 选流 | `GET /api/stream-plan?id=&session=<UUID>&mode=` | `protocol=range` 直接播放 `src`（`/stream?id=`）；`hls` 播放 m3u8；ISO 原盘返回 415，提示改用外部播放器；`410` 表示会话已取消 |
| 停止 | `POST /api/stream-cancel` | 结束、切换版本时调用，释放服务端转码 |
| 版本 / 分卷 | `GET /api/editions`、`GET /api/parts` | 接入现有版本选择与 `partIDs` |
| 起播计数 | `POST /api/play` `{id}` | 每次起播调用一次 |
| 进度 | `POST /api/activity` `{id, position, duration, delta, ended, seeks}` | `delta` 为两次上报之间实际观看的秒数，由 `PlaybackReporter` 的 Peach 适配器累计；服务端只保存比例，不保存精确位置 |
| 外部播放 | `POST /api/external-playback?id=` | 返回 `url`、`playlist`（M3U）、`expires_in`；Vela 下载功能也复用该地址 |
| 字幕 | `GET /api/assets/:id/subtitles` | 每条有 `src`（已转 WebVTT）、`playable`、`note`；不可播放的轨道显示 `note` |
| 字幕记忆 | `GET/PUT /api/subtitles/memory?video=item:<id>` | 与 Web 共享上次选择 |
| 播放记忆 | `GET/PUT /api/player/memory?video=` | 旋转、倍速、字幕外观；Vela 只同步倍速与字幕选择，其余保留本机偏好 |
| 在线字幕 | `GET /api/subtitles/search`、`/api/subtitles/subtitlecat/...` | 接到现有远程字幕面板 |

### P3 互动与检索

| 功能 | 接口 |
|---|---|
| 评分 | `POST /api/feedback` `{id, kind: "rate", value}`：`value` 取 0–100，五星对应 20 的倍数；0 表示撤销，服务端写 NULL |
| 已看 / 不喜欢 / O 计数 | `POST /api/feedback`，`kind` 取 `seen` / `dislike` / `o` / `o-undo` |
| 收藏 | 映射为稍后看 `POST /api/watch-later` |
| 偏好标记 | `POST /api/preference` |
| 搜索 | `/api/items` 的 `q` 参数；补全 `/api/suggest`；历史 `GET/POST /api/search-history` |
| 筛选面板 | `GET /api/facets` |
| 相关推荐 | `GET /api/related` |
| 聚合搜索 | `FederatedSearchService` 增加 Peach 源 |

### P4 实体与播放列表

- `GET /api/entity?kind=&id=`（也接受 `kind` + `name`）。`PersonDetailView` 扩展为实体详情，支持 `performer`、`studio`、`creator`、`agency`、`series`、`tag`。
- 名册页：`GET /api/index`。图集：`/api/photos`、`/api/photo-set`。
- 合并后的实体 ID 会跳转到最终身份（`docs/ROUTES.md`），客户端以响应中的 id 为准。
- 播放列表：`GET /api/playlists`、`GET/POST /api/playlist`，接入播放队列。

---

## 5. 任务与设置（P5–P7）

### 入口布局

- Peach 服务器在 Vela「设置 → 服务器 → 编辑」页增加「Peach 管理」入口，与 Jellyfin 的 `ServerAdminView` 并列。
- 子页面沿用设置页的分组表单样式。Peach 的「订阅 / 关注」与 Vela 现有的 MoviePilot / Seerr 订阅日历是两套概念，不合并：前者是 Peach 服务器上的追更来源，后者是 Vela 的全局功能。

```
Peach 管理
├─ 任务中心          云下载进度、刮削入库、后台任务
├─ 云下载            提交磁力、取消、后处理；下载渠道（仅可写部署）
├─ 订阅与关注        JAV 新作订阅、创作者关注、标签、自动检查计划
├─ 想要清单          库外作品与磁力
├─ 来源与凭据        刮削来源设置、连通检查、凭据状态与写入
├─ 内容偏好          跟人走的同步设置（/api/settings）
├─ 服务器配置        媒体库、网络、存储、更新（多为只读或仅本机）
└─ 在 Peach 网页中打开
```

### P5 任务中心与云下载

| 功能 | 接口 | 远程可写 | 说明 |
|---|---|---|---|
| 下载任务列表 | `GET /api/downloads?limit=&before_id=` | — | 分页游标为 `before_id`；任务带作品封面 |
| 提交磁力 | `POST /api/downloads` `{magnet, provider, target, code, title, origin}` | 是 | `provider` 取已配置渠道（115 经 CloudDrive2，或 PikPak，ADR-0089）；`origin` 传 `"vela"` 区分来源。**待验证**：`origin` 是否有白名单 |
| 取消 / 后处理 | `POST /api/downloads/cancel`、`/api/downloads/postprocess` `{id}` | 是 | 返回最新 `task` |
| 资源搜索 | `GET /api/resources/search`、`GET /api/jav/resources` | — | 详情页「找资源 → 选磁力 → 提交下载」 |
| 想要清单磁力 | `GET /api/wants/magnets` | — | |
| 任务进度 | `GET /api/tasks`、`GET /api/tasks/{run_id}` | — | 前台定时刷新，离开页面停止 |
| 刮削入库 | `GET/POST /api/library-processing` | 是 | 按 `job_id` 暂停 / 继续 / 取消；`scope=new` 不与 `asset_ids` 混用 |
| 入库问题 | `GET /api/library-processing/issues` | — | 分页时携带首次返回的 `revision`，任务变化导致 409 时从头重读 |
| 媒体处理、缩略图任务 | `/api/media-processing`、`/api/thumbnail-jobs` | **仅本机** | App 只在可访问时显示 |

**下载渠道配置**（`/api/configuration/downloads*`，**仅本机 / Docker 私有网络**）：

- 读取：`GET /api/configuration` 的 `downloads` 区（含 `problems` 与 `config`）、`GET /api/configuration/downloads/check`。
- 写入：`POST /api/configuration/downloads`、`/downloads/check`、`/downloads/folder`。
- PikPak：`/downloads/pikpak/login`、`browser-login`（需要在 Peach 主机上弹浏览器，App 无法完成，只展示状态并引导到电脑上操作）、`logout`。
- CloudDrive 代理：`GET/POST /api/configuration/cloud-proxies`，写入带 `revision`，冲突返回 409。
- 索引器：`GET/POST /api/configuration/indexers`。
- App 侧：可访问时提供表单（不回显密码，只显示「已保存」）；403 时只读展示任务列表上的渠道名，并提示到电脑上配置。提交磁力前若渠道未配置，按钮禁用并说明原因。

### P6 订阅与关注

Peach 有两条追更线：**订阅源**（`/api/feeds*`，按 JavDB 身份追女优新作，ADR-0047 / 0083）和**关注**（`/api/follow*`，创作者站点来源，ADR-0019）。两条都走普通路由，远程可写。

| 功能 | 接口 | 说明 |
|---|---|---|
| 订阅源列表 | `GET /api/feeds` | 返回 `sources` 与未读数 `unread` |
| 订阅 / 取消 / 开关 | `POST /api/feeds/source` `{action: follow / follow-name / remove / enabled}` | 服务端自行拼来源地址，客户端只传实体 id 或站内演员 id；人物详情页增加「订阅新作」 |
| 按名字查找 | `GET /api/feeds/lookup` | 「按名字订阅」的候选 |
| 新作发现 | `GET /api/feeds/discoveries`、`POST /api/feeds/discovery` | 已读、忽略；可直接加入想要清单或转去找资源 |
| 立即检查 | `POST /api/feeds/check`、`GET /api/feeds/check` | 后台任务，轮询状态 |
| 自动检查计划 | `GET /api/feeds/schedule`、`POST /api/feeds/schedule/run` | |
| 关注时间线 | `GET /api/follow` | 作者、来源、标签、观看状态用查询参数 |
| 添加 / 移除来源 | `POST /api/follow/source` `{action: add / remove / enabled}` | 粘贴来源链接即登记，首次检查失败显示在该行，不算添加失败 |
| 作者 / 别名 / 创作者 | `GET /api/follow/authors`，`POST /api/follow/author-alias`、`/api/follow/creator` | |
| 标签 | `GET /api/follow/tags`、`POST /api/follow/tag` | |
| 帖子操作 | `POST /api/follow/status`、`/follow/save`、`/follow/media/hide` | |
| 帖子播放与进度 | `POST /api/follow/play`、`/api/follow/activity`；媒体走 `/follow-stream` | 字幕记忆的 `video` 用 `follow:<帖子 ID>:<main 或序号>` |
| 自动检查 | `GET/POST /api/follow/schedule` `{enabled, interval_minutes}`、`POST /api/follow/schedule/run`、`/api/follow/check` | |
| 建议 / 解析 | `GET /api/follow/suggest`、`POST /api/follow/resolve` | |
| 想要清单 | `GET/POST /api/wants` | 库外作品按番号登记，扫描入库时自动匹配（ADR-0090） |

UI 落点：

- 「订阅与关注」页分「订阅源」「关注来源」「计划」三段；未读数显示在 Peach 管理入口上。
- 关注时间线作为 Peach 服务器的一个独立浏览页（类似 Web 的 `/follow`），放在 P6 末尾实现。

### P6 来源与凭据

| 功能 | 接口 | 说明 |
|---|---|---|
| 来源列表与状态 | `GET /api/scraping`、`GET /api/sources` | |
| 来源设置 | `POST /api/scraping/settings` `{source, ...}` | 字段由服务端按来源定义；表单按返回结构动态生成 |
| 连通检查 | `POST /api/scraping/check` | 失败原因（冷却、代理、超时、人机验证、限流）原样显示服务端的 `message` |
| 凭据状态 | `GET /api/follow/credentials` | 只返回字段名与缺失项，不返回凭据值 |
| 写入凭据 | `POST /api/follow/credential` `{provider, values}` | 写到 Peach 主机的 `secrets/`，只接受 `CREDENTIAL_GUIDE` 里声明过的字段 |

凭据写入规则：

- 输入框用 `SecureField`，提交后立即清空，不在 Vela 本地留存；
- 日志不记录 `values`；
- 页面明确写出「凭据保存在运行 Peach 的电脑上」；
- 需要浏览器 Cookie 的来源（Cloudflare 后面的站点，ADR-0065）只展示状态，引导到电脑上处理。

### P7 内容偏好与服务器配置

**内容偏好**（`GET/POST /api/settings`，远程可写）：

- 键白名单：`sidebarOrder`、`followInitialDays`、`organizeTemplates`、`codePatterns`、订阅开关、`searchHistoryLimit` 等。写入是合并，不是整体替换。
- Vela 只提交本次改动的键；提交未知键会返回 400，这类键不展示。
- `sidebarOrder` 是 Web 侧栏顺序，Vela 不使用，不展示。

**服务器配置**（`/api/configuration*`，**仅本机 / Docker 私有网络**）：

| 分区 | 读取 | 写入 | App 处理 |
|---|---|---|---|
| 媒体库与根目录 | `GET /api/configuration` | `POST /api/configuration`（带 `revision`，409 表示已变更） | 可写时支持改名称 / 图标、新增目录；改实际位置必须传 `change_mode: "relocate"`；字段错误按 `errors` 显示在对应行下 |
| SMB 测试 | — | `POST /api/configuration/smb/test` | 显示可进入的子目录 |
| 网络与访问 | `GET /api/network-status` | `/api/configuration/access`、`/tunnel`、`/entry-links`、`/peach-proxy` | **App 不提供写入**：修改访问密码或公网入口可能让 App 自己断开连接，只读展示并引导到电脑上操作 |
| 推送发现 | 同上 `push_discovery` 区 | `/push-discovery`、`/push-discovery/secret` | 只读展示 |
| 存储 | `GET /api/configuration/storage` | `/storage/measure`、`/storage/clean`、`/storage/relocate` | measure 可调用；clean / relocate 不在 App 中提供 |
| 更新 | `GET /api/configuration/updates`、`/update-status`、`/automatic-updates` | `/update`、`/update-restart`、`/automatic-updates` | 展示版本与状态；更新并重启需二次确认，重启期间暂停请求并轮询恢复 |
| 诊断 | `GET /api/diagnostics`、`/exports` | `/diagnostics/exports` | 只读展示检查结果；诊断包下载不在 App 中提供 |
| 卸载、启动项、选择文件夹 | — | `/uninstall`、`/startup`、`/api/pick-folder` | 不提供：依赖 Peach 主机的桌面环境 |

降级规则：

- 进入「服务器配置」先调 `GET /api/configuration`。
- 403 时整页显示「此部署只允许在运行 Peach 的电脑上修改配置」，附「在 Peach 网页中打开」。网页同样受本机限制，所以说明里写清需要在那台电脑上打开。
- `section_errors` 中的分区单独显示错误与重试，其余分区正常显示。
- 返回体中 `editable == false` 时，所有写入控件禁用。

### P7 其余 Web 功能

| 功能 | 接口 | 方案 |
|---|---|---|
| 文件整理 | `/api/organize`、`/organize/example`、`/organize/preview`、`/organize/apply`、`/organize/rollback` | 原生实现，严格走预览 → 逐项确认 → apply；结果页提供 rollback |
| 回收站 / 垃圾文件 | `feedback kind=dispose`、`POST /api/trash/empty` | 原生实现，清空前显示条数与可释放的体积 |
| 标签管理 | `/api/tag-management`、`/api/tag-management/preview`、`/api/item-tag` | 原生实现 |
| 统计 / 口味 / 排行 | `/api/stats`、`/api/taste`、`/api/tops` | 原生只读页（图表用 Swift Charts） |
| 人工复核 | `/api/review`、`/api/review/decision`、`/api/review/genre` | 先走网页入口 |
| 重复文件 / 高清目标 / 数据清理 / 资源同步 | `/api/duplicates`、`/api/quality-goals`、`/api/resource-sync/*`、`/api/purge-missing`、`/api/orphan-records*` | 先走网页入口；涉及删除，后续原生化时按整理流程加确认 |
| JAV 探索 | `/api/jav/detail`、`/api/jav/discoveries`、`/api/jav/reviews` | 先走网页入口 |
| 沉浸浏览 / 播放墙 | 前端页面 | 不原生实现 |

网页入口：WKWebView 打开对应 Peach 页面地址（`docs/ROUTES.md`）。

- 密码登录时复用会话 Cookie。
- 只有口令时，**待验证**：页面路由带 `?t=` 能否建立 Cookie 会话。不能的话，网页入口要求用户额外用密码登录一次。
- 网页入口同样使用 CA 指纹固定。

---

## 6. 里程碑

| 阶段 | 内容 | 难度 | 依赖 |
|---|---|---|---|
| P0 | Provider 抽象、Peach 登录、CA 固定、图片请求头 | 高 | — |
| P1 | 媒体库、海报墙、详情、首页行 | 低 | P0 |
| P2 | 选流、进度、字幕、外部播放 | 中 | P1 |
| P3 | 评分、已看、稍后看、搜索、筛选 | 低 | P1 |
| P4 | 实体页、名册、播放列表 | 中 | P1 |
| P5 | 任务中心、云下载、刮削入库、下载渠道配置 | 中 | P1 |
| P6 | 订阅源、关注、想要清单、来源与凭据 | 中 | P4（人物页订阅入口） |
| P7 | 内容偏好、服务器配置、文件整理、回收站、标签管理、统计、网页入口 | 高 | P5 |

P2–P4 互相独立，可以并行。P5、P6 只依赖 P1 和 P4，可以与 P2 / P3 并行。

---

## 7. 验证

- 每个阶段：`cd Packages/VelaKit && swift test`；新增 DTO 映射与 Provider 适配器的单测，fixture 取自真实响应并去掉路径与番号。
- 联调环境准备两种部署，覆盖本机限定的两种分支：
  - Peach 仓库自带的 `compose.yaml`（Docker，私有网络可写配置）；
  - 一台桌面源码部署（配置仅限本机）。
- 真机重点检查：
  1. 自签 CA 的指纹确认，以及未安装描述文件时的播放提示；
  2. AVPlayer 与 KSPlayer 起播（range 与 HLS 各一次）；
  3. 进度回写后在 Web 端显示一致；
  4. 切换类接口连点时状态不出现分叉；
  5. 磁力提交到任务完成入库的完整链路；
  6. 订阅检查与发现已读；
  7. 配置页在两种部署下分别为可写和只读；
  8. 账本只读（409）时写操作入口置灰。
- 发布前在服务器页记录本次验证过的 Peach 版本区间。
