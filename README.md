# Paircast

异地好友同步观影 + 实时聊天，iOS（SwiftUI）+ Android（Jetpack Compose），业务逻辑用 Kotlin Multiplatform 共享，IM 使用自托管 [GO-IM](https://github.com/chaishuanzhu/GO-IM)。iOS Bundle ID 仍为 `com.chaisz.tandem`，Android applicationId 为 `com.chaisz.paircast`。

> v1.x（腾讯云 IM、纯 Swift）归档在分支 `archive/ios-tencent-im`。

## 要求

- Xcode 26+ / iOS 26.0+；[Tuist](https://tuist.dev) 4.x（`brew install tuist`）
- JDK 17（Android Studio 自带 JBR 即可）+ Android SDK（compileSdk 36，minSdk 26）
- 一台 GO-IM 服务（需支持 `CmdSignal=25` 类型化瞬时信令与服务端 API）+ 本仓库的 Paircast 服务（[`server/`](server/README.md)，提供 `/media/…`、`/room/…`），部署步骤见[服务端部署指南](https://paircast.chaisz.com/zh-Hans/deploy/)

## 快速开始

```bash
make setup         # 下载 VLCKit + tuist install/generate
make test          # Kotlin 单测 + iOS 测试（Paircast scheme）
make open          # 生成并打开 iosApp/Paircast.xcworkspace
make android       # Android Debug APK
```

iOS 不需要预先构建 Kotlin：`Presentation` 目标的 “Compile Kotlin Framework” 构建阶段会调用 Gradle `embedAndSignAppleFrameworkForXcode`，按当前配置 / SDK 编译 `PaircastShared.framework`，改了 `shared/` 直接在 Xcode 里构建即可（需要 JDK 17–21，脚本会自动找 Android Studio 自带 JBR）。

目录结构对齐 GO-IM（`kmp/iosApp`）：Gradle 工程在仓库根目录，iOS 相关全部在 `iosApp/`（`Project.swift` / `Tuist.swift`、`App/`、`Presentation/`、`Scripts/`、`Vendor/VLCKitSPM`、`fastlane/` + `Gemfile`）。Tuist 命令需在 `iosApp/` 下执行（或用 `make generate`）。

## 模块

| 模块 | 职责 |
|------|------|
| `shared/core` | 纯 Kotlin：实体、规则、Gateway 接口、用例、`WatchSession` + `PlayerPort` |
| `shared/data` | GO-IM（WebSocket protobuf + REST）、Paircast 服务端片库 / 房间 / 字幕 / 贴纸客户端（`/media/…`、`/room/…`） |
| `server` | Paircast 服务端（Go）：片库与观影房间，作为 GO-IM 接入方运行，见 [server/README.md](server/README.md) |
| `shared/umbrella` | `PaircastGraph` 组装（两端共用）；iOS 导出 `PaircastShared` 框架（SKIE） |
| `iosApp/Presentation` | iOS SwiftUI 场景、VLCKit 播放器、Keychain |
| `iosApp/App` | iOS 入口与 Deep Link `paircast://` |
| `androidApp` | Android Compose 场景、libVLC 播放器、加密存储 |

依赖方向：`App / androidApp → Presentation → shared:umbrella → shared:data → shared:core`。

## 双端冒烟

管理员在 Paircast 建两个账号（`/console/users/create` 或 App「后台管理」），并在 Paircast 服务 `media.sources` 配好片源（见[服务端部署指南](docs/zh-Hans/deploy/index.html)第 5 步）；两台设备填同一服务器地址：

1. A 登录 → 开片建房 → 分享邀请链接  
2. B 登录 → 打开邀请 → 加入成功  
3. A 播放/暂停/拖动 → B 跟随；双方聊天、贴纸互通  
4. A 播放中约 5s 心跳对齐 B 进度；A 离开后 B 成为房主  
5. iOS ↔ Android 各做一次房主

## 安全说明

- 账号密码由 GO-IM 校验；会话 token 存 Keychain / EncryptedSharedPreferences
- 客户端配置只有服务器（Paircast）地址，登录后服务端告诉客户端 GO-IM 地址，由用户手动填写；对象存储 / TMDB / OpenSubtitles 凭证只在 Paircast 服务端（环境变量注入）。服务端部署见 [docs/zh-Hans/deploy](docs/zh-Hans/deploy/index.html)（线上 `https://paircast.chaisz.com/zh-Hans/deploy/`）

## 文档

- 索引：[docs/README.md](docs/README.md)
- 产品：[docs/PRD.md](docs/PRD.md)
- 设计：[docs/DESIGN.md](docs/DESIGN.md) · 本地预览 [docs/design-preview/index.html](docs/design-preview/index.html)
- 技术：[docs/TECH.md](docs/TECH.md)
- Agent 约定：[AGENTS.md](AGENTS.md)
