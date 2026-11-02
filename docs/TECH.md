# Paircast 技术说明

对应 PRD v2.0 与本地设计预览 `docs/design-preview/index.html`。

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
| `shared/data` | GO-IM（Wire protobuf over WebSocket + Ktor REST）、S3 兼容存储（SigV4）、房间 JSON、片库/元数据（NFO + TMDB）、字幕（OpenSubtitles + GBK 转码）、贴纸、安全存储接口 |
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

- 账号由管理员在 GO-IM `/admin/users/create` 预置；App 内**无注册**
- 登录：`POST /login`（账号 = UID 或邮箱 + 密码）→ `token` + `must_change_password`；为真时强制 `POST /change-password` 后才进片库
- 会话（serverUrl、uid、token）存安全存储：iOS Keychain（AfterFirstUnlockThisDeviceOnly），Android EncryptedSharedPreferences
- token 失效 / 被踢（WebSocket `KICK`）→ `SessionEvent` → 回登录页
- 配置不再包含任何 IM 密钥，只有 GO-IM 服务器地址

## 配置分享（加密深链）

```
paircast://config?args=<base64url(AES-GCM(JSON))>
```

- `args`：AES-GCM sealed box（nonce ‖ ciphertext ‖ tag）的 base64url（无 padding），UTF-8 明文 ≤ 2KB
- 密钥：App 内嵌派生（`SHA256("Tandem.iOS.ConfigShare.v1")`），仅作传输混淆，**不能**替代对接收方的信任
- 导入：打开深链、粘贴完整 URL 或扫码；非法/篡改载荷不覆盖现有配置；导入前脱敏确认
- **v4** 载荷：`im.serverUrl`。导入 v1–v3（腾讯云 IM 时代）链接时丢弃 `sdkAppId` / `secretKey`，保留存储与扩展配置，并提示补填服务器地址
- 1.x 升级：iOS 首次启动把旧 Keychain 配置迁移为 v4（服务器地址留空）

```json
{
  "v": 4,
  "type": "paircast-config",
  "im": { "serverUrl": "https://im.example.com" },
  "storage": {
    "provider": "qiniu",
    "accessKey": "...",
    "secretKey": "...",
    "bucket": "movies",
    "endpoint": "s3.cn-south-1.qiniucs.com",
    "prefix": "films/",
    "useSSL": true,
    "forcePathStyle": true
  },
  "subtitleApiKey": null,
  "tmdbAccessToken": null
}
```

## GO-IM 传输

- WebSocket：`ws(s)://host/ws?token=&device_id=&platform=ios|android`，每帧一个 protobuf `im.Message`
- 心跳 25s（`CmdHeartbeat=6`），连续 3 次无响应重连；指数退避重连；`CmdAck=2` 匹配本机发出的消息
- 群生命周期：房主建房 `POST /group/create` → `groupId`（`g_…`）写入房间 JSON；成员读 JSON 后 `POST /group/join`；离开 `POST /group/leave`（最后一人离开服务端自动删群）
- 聊天：`CmdChat=1`，`chat_type=2`（群）；文本 `msg_type=1`（系统消息前缀 `[sys]`）；贴纸 `msg_type=6` + JSON `StickerRef`；本人消息收到 Ack 后本地回显
- 播控：`CmdGroupSignal=25` 瞬时群信令（服务端校验成员身份、跨网关转发，不落库、不计未读、不回显给发送者），`content` 为下方信令 JSON

## 播控信令 JSON

```json
{
  "action": "play|pause|seek|heartbeat|movie_change|host_transfer|subtitle_change",
  "positionMs": 0,
  "movieId": "films/Inception.2010.mp4",
  "hostUserId": "10001",
  "senderId": "10001",
  "clientTs": 1710000000000,
  "playbackRate": 1.0,
  "seq": 12,
  "subtitleObjectKey": "films/Inception.2010.srt",
  "subtitleLabel": "简体中文"
}
```

规则：

- 仅当前 `hostUserId` 的 play/pause/seek/heartbeat/movie_change/subtitle_change 生效
- `seq` 单调；旧序丢弃
- 房主播放中约每 5s 发 heartbeat；成员用**本机播放器实时进度**与房主 `positionMs` 比较，> 1200ms 才 Seek
- 房主离开按 joinOrder 转让（`host_transfer`）；最后一人结束房间
- **字幕共享**：房主下载外挂/在线字幕后上传到影片同目录同名文件，发 `subtitle_change`；成员按 key 拉取加载。成员自选字幕仅本机；时间轴偏移始终本机；内嵌轨不同步

## 头像与资料

- 上传：`POST /upload`（GO-IM 文件存储）→ `file_id`，再 `POST /user/profile` 写 `avatar_file_id`；公开地址 `/avatar/{id}`
- 观影页成员条：`/user/profiles` 批量拉取（带短缓存）；头像外圈环形进度反映播放进度
- 播放器控件：5s 无操作自动隐藏；全屏自动横屏；房主拖动进度条发 `seek`
- 字幕：内嵌（VLC 轨）/ 存储同目录外挂（srt/vtt/ass）/ OpenSubtitles 在线搜索；本机偏移 ±30s（按 movieId 记忆）

## Deep Link

| URL | 行为 |
|-----|------|
| `paircast://watch?roomId={id}&movieId={id}&hostUserId={id}` | 加入观影房（未登录则暂存邀请） |
| `https://paircast.chaisz.com/invite/?roomId=…` | 同上（邀请落地页；Android 声明了 intent-filter） |
| `paircast://config?args={encrypted}` | 打开服务配置并弹出脱敏确认导入 |

房间状态写入对象存储 `_paircast/rooms/{roomId}.json`（含 `groupId`），约 2s 轮询。

## 元数据

1. **存储 sidecar 优先**：同目录 `{base}.nfo` + `{base}-poster.jpg` + `{base}-fanart.jpg` 存在则直接读取，不再刮削
2. 否则：内存缓存 → TMDB（需 `tmdbAccessToken`）→ 文件名 `{Title}.{Year}` / `{Title} (Year)`
3. 刮削成功后写回存储（NFO + 海报；无背景图时用海报兼作 fanart）

## 片库（S3 兼容）

- **Endpoint**（必填）为 S3 API 主机；列表 / 播放 / 海报 / 房间 JSON 全部 SigV4 预签名，不支持自定义域名
- 列表：`ListObjectsV2`，按 `NextContinuationToken` 翻页（每页 ≤1000，最多 50 页）
- 播放：预签名 GET（默认 6h），两端 VLC 直接拉流解码；仅 `.mp4` / `.m4v` / `.mkv`

## 测试

```bash
make shared-test   # core 规则/用例/WatchSession + data（SigV4、NFO、DTO、GO-IM 协议）
make test          # + iOS（Paircast scheme：PaircastTests + PresentationTests）
make android-test
```
