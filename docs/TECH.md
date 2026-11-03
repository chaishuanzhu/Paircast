# Paircast 技术说明

对应 PRD v2.1 与本地设计预览 `docs/design-preview/index.html`。

## 架构

Clean Architecture：UI → shared(data) → shared(core)。业务逻辑用 **Kotlin Multiplatform** 共享，两端 UI 原生实现。

```
iOS:     App → Presentation (SwiftUI + VLCKit + Kingfisher) ─┐
Android: androidApp (Compose + libVLC + Coil) ───────────────┼→ shared:umbrella (PaircastGraph)
                                                             └→ shared:data → shared:core
```

| 模块 | 内容 |
|------|------|
| `shared/core` | 纯 Kotlin：实体、规则（播控/转让/配置码/校验）、Gateway 接口、用例、`WatchSession` + `PlayerPort` |
| `shared/data` | GO-IM（Wire protobuf over WebSocket + Ktor REST）、服务端片库 / 房间 / 字幕 / 贴纸客户端（`ServerMediaApi` + `Server*Gateway`）、字幕 GBK 转码、安全存储接口 |
| `shared/umbrella` | `PaircastGraph` 组装依赖（两端共用）；iOS 由 Xcode 构建阶段 `embedAndSignAppleFrameworkForXcode` 编译 `PaircastShared` 框架（SKIE：`suspend` → `async throws`，`Flow` → `AsyncSequence`） |
| `iosApp/Presentation` | SwiftUI 场景、`VLCPlayerController`（实现 `PlayerPort`）、Keychain / UserDefaults 平台存储 |
| `iosApp/App` | iOS 入口、Deep Link；`iosApp/Project.swift` 为唯一 Tuist 工程清单（Paircast / Presentation 两个 target） |
| `androidApp` | Compose 场景、`VlcPlayer`（libVLC，实现 `PlayerPort`）、EncryptedSharedPreferences |

- `shared:core` 不依赖 Ktor / 平台 SDK；播放器只通过 `PlayerPort` 接入
- 观影页编排（加入、三路监听、心跳、远端应用、切片、字幕共享、离开转让）全部在 `WatchSession`，两端 UI 只渲染 `StateFlow<WatchUiState>` 并转发 `WatchEvent`
- 文案：两端共用 `iosApp/App/Resources/Localizable.xcstrings`（Android 构建时复制进 assets）；共享层只抛 `AppError` / `UiText`（key = 英文模板）
- 最低系统：**iOS 26.0**、**Android 8.0（API 26）**

构建：

```bash
make setup        # VLCKit + tuist generate（Kotlin 框架在 Xcode 构建时自动编译）
make shared-test  # Kotlin 单测（Android 单元 + iOS 模拟器）
make test         # shared-test + iOS 测试（Paircast scheme）
make android      # Debug APK
```

## 登录与安全

- 账号归属：**账号由 Paircast 服务管理**（`server/internal/account`，MySQL `paircast_users`，bcrypt 密码）。每个账号在 GO-IM 有一个镜像用户（服务端 API `users/import`，`external_id` = Paircast 账号 ID），对客户端暴露的用户 ID 始终是 IM uid。App 不提供注册；GO-IM 侧建议关闭自助注册（`gateway.auth.disable_registration`）
- 管理员：Paircast 配置 `account.admin_email`（或 `PAIRCAST_ADMIN_EMAIL`）启动时自动创建，随机初始密码配了 SMTP 就发信，否则打到服务日志；首次登录强制改密
- 添加用户（仅管理员，`User.isAdmin`）：`CreateUserUseCase(email, nickname)` → `AccountAdminGateway.createUser` → Paircast `POST /console/users/create`（email、nickname 可选）。校验在 `AccountRules`（邮箱格式转小写、昵称留空交给服务端）；服务端生成随机初始密码并置 `must_change_password`，配了 SMTP 就发到对方邮箱（`mailed: true`），否则返回 `initial_password`，`CreatedAccount.initialPassword` 非空时 UI 显示并可复制。错误映射：400 邮箱 / 昵称、403 非管理员、409 邮箱已存在
- 用户管理（仅管理员）：`LoadUsersUseCase` → `GET /console/users?offset&limit`（每页 50，`ManagedUser` 含 role / `is_disabled` / avatar_url）；`SetUserDisabledUseCase` → `POST /console/users/disable`（Paircast 先停用 IM 镜像用户——GO-IM CmdKick `account disabled`——再停用本地账号并吊销会话）；`DeleteUserUseCase` → `POST /console/users/delete`（同时删除 IM 用户）。`AccountRules.canManage` 拒绝操作自己与其他管理员（`AppError.CannotManageAccount`），服务端 400 `cannot … yourself` 同样映射；`not found` → `AppError.UserNotFound`
- 删除账号：`DeleteAccountUseCase(password)` → Paircast `POST /account/delete`（校验密码后删除本地账号与 IM 用户；管理员账号 403）→ 登出、清本机配置 / 会话 / 缓存。满足 App Store 5.1.1(v)
- 协议同意：`LoginUseCase` 带 `agreedToTerms`，先过 `LegalRules.requireAgreement`（未同意抛 `Validation`，不发请求）；链接由 `LegalRules.termsUrl` / `privacyUrl` 生成（`https://paircast.chaisz.com/{zh-Hans|en-US}/terms|privacy/`）。勾选状态放在 `AppSession` / `AppState`，默认不勾选、不持久化
- 登录：Paircast `POST /account/login`（账号 = UID 或邮箱 + 密码）→ Paircast 会话令牌 `token`（`pc1.…`，默认 30 天）+ `must_change_password` + `im{url, uid, token, expires_at}`（GO-IM 地址与 IM 令牌；`url` 为空即与 Paircast 同域名）。`must_change_password` 为真时强制 `POST /account/password` 后才进片库；改密返回新 `token`（旧会话全部失效）
- 两套令牌分工：Paircast 令牌用于 `/account/*`、`/console/*`、`/media/*`、`/room/*`；IM 令牌用于 GO-IM 的 WebSocket、`/upload`、`/user/profiles`、屏蔽与举报提交。IM 令牌由 `GET /account/session` 刷新：App 启动恢复会话时、以及 GO-IM 拒绝 IM 令牌时（`GoImConnection.refreshSession`）；刷新返回 401 才算会话失效，网络错误保留本机会话
- 会话（serverUrl、uid、token、appToken、imUrl）存安全存储：iOS Keychain（AfterFirstUnlockThisDeviceOnly），Android EncryptedSharedPreferences
- token 失效 / 被踢（WebSocket `KICK`）→ 先清掉本机保存的会话（`GoImConnection.onSessionEnded` → `SessionStore.clear`），再发 `SessionEvent` → 回登录页；重开 App 不会用旧 token 自动登录（否则会把另一台设备踢回去）
- 配置只有 Paircast 服务器地址（GO-IM 地址由登录返回）：不含 IM 密钥，也不含对象存储 / TMDB / OpenSubtitles 凭证（v2.1 起全部在服务端）

## 服务配置

- 只有一个字段：服务器（Paircast）地址，用户手动填写；`ConfigValidation.normalizedServerUrl` 补 `https://`、去掉路径与结尾 `/`，局域网可显式 `http://`
- v2.1 起**不再提供配置分享 / 导入**：删除 `ConfigQRCodec`、`ConfigLinkCodec` / `ConfigShareLink`（AES-GCM）、导入导出用例与二维码 / 扫码 UI，Android 去掉 CameraX / ML Kit / ZXing 依赖与相机权限，iOS 去掉存相册权限；`paircast://config?args=…` 不再注册处理（`paircast://` scheme 仍用于 `watch`）
- 已登录时保存了不同的服务器地址 → 退出登录、清元数据缓存、回登录页并提示「服务器已更换，请重新登录」
- 本机安全存储（键 `paircast.cloud-config.v4` 保持不变）只存 `serverUrl` / `updatedAtMs` / `configVersion`；读到旧版遗留的 `accessKey` / `secretKey` / `subtitleApiKey` / `tmdbAccessToken` 时立即重写清除。iOS 1.x Keychain 旧配置直接删除
- 配置页附两个外链：`https://paircast.chaisz.com/{zh-Hans|en-US}/guide/`（使用说明）与 `/deploy/`（服务端部署指南：Docker 最小化部署、HTTPS、SMTP 与管理员、`/console/users/create`、片库 / 字幕 / 海报 / 表情包）

## GO-IM 传输

- WebSocket：`ws(s)://host/ws?token=&device_id=&platform=ios|android`，每帧一个 protobuf `im.Message`
- 心跳 25s（`CmdHeartbeat=6`），连续 3 次无响应重连；指数退避重连；`CmdAck=2` 匹配本机发出的消息
- 回前台 `PaircastGraph.onAppForeground()`：已连接则立即探活（5s 无 pong 断开重连），退避等待中则立即重连
- 群生命周期：由服务端房间接口托管——`POST /room/create` 同时建群（`groupId` = `g_…`），`/room/join` 入群，`/room/leave` 退群（最后一人离开结束房间并删群）
- 聊天：`CmdChat=1`，`chat_type=2`（群）；文本 `msg_type=1`（系统消息前缀 `[sys]`）；贴纸 `msg_type=6` + JSON `StickerRef`；本人消息收到 Ack 后本地回显
- 播控：`CmdSignal=25` 瞬时信令（`chat_type=2`、`to`=群 ID；服务端校验成员身份、跨网关转发，不落库、不计未读、不回显给发送者），`content` 为 `{"type":"paircast.playback","data":<下方信令 JSON>}`；GO-IM 丢弃没有 `type` 的信令，客户端也只解析自己认识的类型（`SignalCodec`）

## 播控信令 JSON（`paircast.playback` 的 `data`）

```json
{
  "action": "play|pause|seek|heartbeat|movie_change|host_transfer|subtitle_change",
  "positionMs": 0,
  "movieId": "oss:films/Inception.2010.mp4",
  "hostUserId": "10001",
  "senderId": "10001",
  "clientTs": 1710000000000,
  "playbackRate": 1.0,
  "seq": 12,
  "subtitleObjectKey": "blob:paircast/subtitles/<roomId>/<id>.srt",
  "subtitleLabel": "简体中文"
}
```

规则：

- 仅当前 `hostUserId` 的 play/pause/seek/heartbeat/movie_change/subtitle_change 生效
- `seq` 单调；旧序丢弃
- 房主播放中约每 5s 发 heartbeat；成员用**本机播放器实时进度**与房主 `positionMs` 比较，> 1200ms 才 Seek
- 房主离开：先发 `host_transfer`（目标 = joinOrder 下一位），再 `POST /room/leave`（`transfer_seq`），服务端按加入顺序落库转让；最后一人离开结束房间
- `subtitleObjectKey` 字段名沿用旧版，内容是服务端字幕 ref（见「字幕」）
- **前后台**：`WatchSession.onBackground()` 本机暂停（房主播放中发 `pause`），后台期间不执行远端播控；`onForeground()` 离开 ≥15s 或播放器报错则用新 URL 重新 prepare 并 seek 回原进度、恢复当前字幕。`PlayerPort.enterBackground/enterForeground` 由平台处理渲染面（Android 后台 `detachViews` + 关视频轨，回前台重新挂载）
- **字幕共享**：房主选片库外挂字幕时直接广播其 ref（`src:…`）；在线 / 其他字幕经 `POST /media/subtitles/share` 上传到 GO-IM 文件存储得到 `blob:…` ref，服务端同时写入房间 `subtitle_ref` 供后加入者加载；随后发 `subtitle_change`。成员按 ref 调 `GET /media/subtitle` 拉取。成员自选字幕仅本机；时间轴偏移始终本机；内嵌轨不同步

## 头像与资料

- 上传：`POST /upload`（GO-IM 文件存储）→ `file_id`，再 Paircast `POST /account/profile` 写 `avatar_file_id`（Paircast 经 `users/import` 同步给 GO-IM，GO-IM 校验文件属于该用户且是图片后标为公开头像）；公开地址 `/avatar/{id}`
- 观影页成员条：`/user/profiles` 批量拉取（带短缓存）；头像外圈环形进度反映播放进度
- 播放器控件：5s 无操作自动隐藏；全屏自动横屏；房主拖动进度条发 `seek`
- 字幕：内嵌（VLC 轨）/ 片库外挂（服务端匹配同目录 srt/vtt/ass）/ 在线搜索（服务端代理 OpenSubtitles）；本机偏移 ±30s（按 movieId 记忆）

## Deep Link

| URL | 行为 |
|-----|------|
| `paircast://watch?roomId={id}&movieId={id}&hostUserId={id}` | 加入观影房（未登录则暂存邀请） |
| `https://paircast.chaisz.com/invite/?roomId=…` | 同上（邀请落地页；Android 声明了 intent-filter） |

## 服务端片库与房间（GO-IM，v2.1）

接口由本仓库的 Paircast 服务（`server/`，定义见 `server/api/openapi.yaml`）提供，与 GO-IM 同域名（反向代理按 `/account`、`/console`、`/media`、`/room` 分流），客户端仍只填一个服务器地址。片源、TMDB、OpenSubtitles 凭证都在 Paircast 服务配置的 `media` 段（密钥走环境变量 `PAIRCAST_MEDIA_<ID>_ACCESS_KEY` / `_SECRET_KEY`、`PAIRCAST_TMDB_ACCESS_TOKEN`、`PAIRCAST_OPENSUBTITLES_API_KEY`，见 `server/README.md`）。所有接口都要 Paircast 会话令牌（`/account/login` 返回的 `token`）；服务端未配置片库返回 **503**（客户端提示「服务器尚未配置片库」），片源不支持某能力返回 **501**。

| 接口 | 说明 |
|------|------|
| `GET /media/sources` | 片源列表（`id` / `name` / `type` / `capabilities`），以及 `online_subtitles` / `stickers` 开关 |
| `GET /media/items?source=&cursor=&refresh=` | 影片分页（每页 500，`next_cursor` 翻页），服务端缓存列表 |
| `GET /media/item?id=` | 单片元数据（刮削并缓存在 `media_metadata` 表） |
| `GET /media/play?id=` | 播放直链 `{url, expires_at, format}`（S3 预签名，两端 VLC 直接拉流） |
| `GET /media/subtitles?id=&room_id=` | 外挂字幕 + 房主共享字幕 ref 列表 |
| `GET /media/subtitle?ref=` | 字幕原始字节，`X-Subtitle-Format` 头给出扩展名；客户端转 UTF-8 后加载 |
| `GET /media/subtitles/search?q=&year=` | 在线字幕搜索（`os:<fileId>` ref） |
| `POST /media/subtitles/fetch` | `ref=os:…` → 下载到服务端存储，返回可读 ref |
| `POST /media/subtitles/share` | multipart：`room_id` / `label` / `file`；仅房主；返回 `blob:…` ref 并写入房间 |
| `GET /media/stickers`、`/media/stickers/pack?id=` | 贴纸目录 / 包清单（每张注入签名 `url`，7 天有效） |
| `GET /room?room_id=`、`POST /room/create`、`/room/join`、`/room/leave`、`/room/update` | 观影房间（MySQL `watch_rooms`；`revision` 单调） |

- **影片 ID**：`<sourceId>:<nativeId>`（如 `oss:films/A.mkv`），为后续 openlist / Emby / Jellyfin 片源预留；无前缀的旧 ID 归入默认片源
- **字幕 ref**：`src:<sourceId>:<key>`（片源外挂）、`blob:paircast/subtitles/…`（共享 / 在线下载后存入 GO-IM 文件存储）、`os:<fileId>`（在线搜索结果）
- **房间**：服务端维护成员、`joinOrder`、房主、`movieId`、`subtitle_ref`、两个 seq 与 `revision`。仅房主可改片 / 转让 / 结束（传未变化的值不算越权）；换片清空共享字幕。每次变更由 Paircast 服务经 GO-IM 服务端 API（`signals/send`）推送 `CmdSignal` `{"type":"paircast.room_updated","data":{"group_id":…,"room":{…}}}`（不回给操作者）；客户端另以 15s 轮询 `GET /room` 兜底，只接受更大的 `revision`。房间是 GO-IM 群：建房 / 进出房由服务端调用 `groups/*`，GO-IM 侧的退群 / 解散经 webhook（`group.member_left` / `group.dismissed`）同步回房间
- **元数据**：服务端刮削——同目录 `{base}.nfo` / `-poster` / `-fanart` 优先 → TMDB → 文件名；结果（含无结果）缓存，无海报的结果 1 小时后重试；不再写回片源目录。客户端只对无海报的影片调用 `/media/item`
- 对象存储里不再需要 `_paircast/` 目录（房间改存 MySQL，共享字幕存 GO-IM 文件存储）

## 聊天屏蔽与举报（v2.1）

- GO-IM `internal/moderation`：`user_blocks`（owner_uid, target_uid）与 `user_reports`（reporter / target / message_id / context=房间 ID / content ≤500 字 / status `pending|ignored|banned`）两张表，启动自动建表；无 MySQL 时存内存
- 用户接口：`POST /user/block`、`/user/unblock`（幂等）、`GET /user/blocks`、`POST /user/report`（同一举报人对同一条消息的待处理举报去重）
- 管理接口（Paircast 转 GO-IM 服务端 API `reports/list|get|resolve`）：`GET /console/reports?status=pending|handled|all`（附双方昵称、`target_disabled`、`pending` 总数）、`POST /console/reports/resolve`（`action=ignore|ban`；`ban` = GO-IM 停用 IM 用户 + CmdKick `account disabled` + 关闭该用户其余待处理举报，Paircast 同时停用本地账号；不能封禁 Paircast 管理员）
- 客户端：`ModerationGateway`（`GoImModerationGateway`）；`ChatSafetyStore` 是服务端屏蔽名单的本机副本（离线也能隐藏消息），未上传成功的屏蔽记为 pending。`WatchSession.start` 调 `SyncBlockListUseCase`：先补传 pending（首次同步时把旧版本机屏蔽全部上传），再以服务端名单为准；`BlockUserUseCase` 先本机隐藏再上传；`ReportMessageUseCase` 直接提交服务器（不再打开 GitHub Issues）
- 管理员身份：`/account/login` 与 `/account/session` 的 `role == "admin"` → `User.isAdmin`；「我的」里仅管理员可见「后台管理」（用户管理〔含添加用户〕/ 举报处理；各用例也会校验）

## 测试

```bash
make shared-test   # core 规则/用例/WatchSession + data（服务端 DTO / 错误映射 / room_updated、GO-IM 协议与类型化信令、配置清理）
make server-test   # Paircast 服务端（Go）
make test          # + iOS（Paircast scheme：PaircastTests + PresentationTests）
make android-test
```
