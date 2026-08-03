# Tandem 技术说明（MVP）

对应 PRD v1.4 与本地设计预览 `docs/design-preview/index.html`。

## 架构

Clean Architecture（参考 tuan188）：Domain ← Data / Presentation ← App。

- Domain：纯 Swift，可单测的规则与用例
- Data：Keychain 配置、本地 UserSig、七牛/OMDb、**腾讯云 IM**（登录 / Meeting 群聊天 / 自定义播控信令）；观影页使用 **VLCKit**（`Vendor/VLCKitSPM`，首次 `make setup` / `Scripts/download-vlckit.sh`）；IM SDK 见 `Vendor/ImSDKSPM`（`Scripts/download-imsdk.sh`）
- Presentation：SwiftUI SPA，无 Tab；「我的」在右上角 Sheet
- 最低系统：**iOS 26.0**

## 登录与安全

- 密码：**弱校验（非空）**；成败以 AuthGateway.login 为准
- UserSig：本地 HMAC 签发；SecretKey 仅 Keychain
- 持有 IM SecretKey 即可签任意 userID —— 配置码等同环境根密钥

## 配置二维码

```json
{
  "v": 1,
  "type": "tandem-config",
  "im": { "sdkAppId": 123, "secretKey": "..." },
  "qiniu": {
    "accessKey": "...",
    "secretKey": "...",
    "bucket": "movies",
    "endpoint": "s3-cn-east-1.qiniucs.com",
    "domain": null,
    "prefix": "films/"
  },
  "subtitleApiKey": null,
  "omdbApiKey": null
}
```

编码 UTF-8 约 ≤ 2KB；非法码不覆盖现有配置。

## 播控信令 JSON

```json
{
  "action": "play|pause|seek|heartbeat|movie_change|host_transfer",
  "positionMs": 0,
  "movieId": "films/Inception.2010.mp4",
  "hostUserId": "alice",
  "senderId": "alice",
  "clientTs": 1710000000000,
  "playbackRate": 1.0,
  "seq": 12
}
```

规则：

- 仅当前 `hostUserId` 的 play/pause/seek/heartbeat/movie_change 生效
- `seq` 单调；旧序丢弃
- 心跳偏差 > 1200ms 才 Seek
- 房主离开 45s 逻辑下按 joinOrder 转让；最后一人结束房间

## Deep Link

`tandem://watch?roomId={id}&movieId={id}&hostUserId={id}`

房间状态写入七牛 `_tandem/rooms/{roomId}.json`（跨设备可加入）。

**腾讯云 IM（播控 + 聊天）：**

- 登录：`TencentIMAuthGateway` + 本地 UserSig → `V2TIMManager.login`
- 观影群：Meeting 群，`groupID = tandem_{roomId}`（`WatchRoom.imGroupId`）；`IMSyncedRoomGateway` 在 create/join 时 `ensureMeetingGroup`
- 聊天：群文本；系统消息前缀 `[sys]`
- 播控：群自定义消息（`sendGroupCustomMessage`），payload 为上方信令 JSON；房主约每 5s 发 heartbeat（播放中）
- 踢下线 / UserSig 过期：`Notification.Name.tandemIMKickedOffline` / `.tandemIMUserSigExpired` → 回登录页
## 元数据

缓存 → 豆瓣 → IMDb suggestion（无 Key，补海报）→ OMDb（需 `omdbApiKey`）→ 文件名 `{Title}.{Year}` / `{Title} (Year)`。

## 片库（七牛 S3 兼容）

- Endpoint 示例：`s3.cn-east-1.qiniucs.com`（也兼容历史写法 `s3-cn-east-1.qiniucs.com`）
- 列表：`ListObjectsV2` + **AWS Signature V4**；自动按 `NextContinuationToken` 翻页（每页最多 1000，最多 50 页）
- 播放：对 `/{bucket}/{key}` 生成 **AWS SigV4 预签名 GET**（默认 **6h**）；不走未签名自定义域名，避免私有桶 403
- 观影页播放器：**MobileVLCKit**（`VLCPlayerController`），用预签名 URL 拉取后本地解码，支持 `.mp4` / `.m4v` / `.mkv`
- 仅展示 `.mp4` / `.m4v` / `.mkv`；失败返回明确错误；刷新取消不会清空已有列表

## 测试

```bash
make test
```

优先覆盖 Domain Rules / UseCases。
