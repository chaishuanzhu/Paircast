# Tandem 技术说明（MVP）

对应 PRD v1.4 与本地设计预览 `docs/design-preview/index.html`。

## 架构

Clean Architecture（参考 tuan188）：Domain ← Data / Presentation ← App。

- Domain：纯 Swift，可单测的规则与用例
- Data：Keychain 配置、本地 UserSig、七牛/OMDb、内存 IM 适配（可替换为腾讯云 IM SDK / VLCKit）
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

`tandem://watch?roomId={id}`

## 元数据

缓存 → 豆瓣（当前跳过）→ OMDb（需 `omdbApiKey`）→ 文件名 `{Title}.{Year}`。

## 播放器

默认 `AVPlayer`；`.mkv` 映射为不支持提示。可在 Data 层将 `PlayerGateway` 换为 VLCKit 而不改 Domain。

## 测试

```bash
make test
```

优先覆盖 Domain Rules / UseCases。
