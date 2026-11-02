# Paircast

异地好友同步观影 + 实时聊天，iOS（SwiftUI）+ Android（Jetpack Compose），业务逻辑用 Kotlin Multiplatform 共享，IM 使用自托管 [GO-IM](https://github.com/chaishuanzhu/GO-IM)。iOS Bundle ID 仍为 `com.chaisz.tandem`，Android applicationId 为 `com.chaisz.paircast`。

> v1.x（腾讯云 IM、纯 Swift）归档在分支 `archive/ios-tencent-im`。

## 要求

- Xcode 26+ / iOS 26.0+；[Tuist](https://tuist.dev) 4.x（`brew install tuist`）
- JDK 17（Android Studio 自带 JBR 即可）+ Android SDK（compileSdk 36，minSdk 26）
- 一台 GO-IM 服务（需包含 `CmdGroupSignal=25` 瞬时群信令）

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
| `shared/data` | GO-IM（WebSocket protobuf + REST）、S3 兼容存储、元数据、字幕、贴纸 |
| `shared/umbrella` | `PaircastGraph` 组装（两端共用）；iOS 导出 `PaircastShared` 框架（SKIE） |
| `iosApp/Presentation` | iOS SwiftUI 场景、VLCKit 播放器、Keychain |
| `iosApp/App` | iOS 入口与 Deep Link `paircast://` |
| `androidApp` | Android Compose 场景、libVLC 播放器、加密存储 |

依赖方向：`App / androidApp → Presentation → shared:umbrella → shared:data → shared:core`。

## 双端冒烟

管理员在 GO-IM 建两个账号（`/admin/users/create`），两台设备配置同一 GO-IM 地址与对象存储：

1. A 登录 → 开片建房 → 分享邀请链接  
2. B 登录 → 打开邀请 → 加入成功  
3. A 播放/暂停/拖动 → B 跟随；双方聊天、贴纸互通  
4. A 播放中约 5s 心跳对齐 B 进度；A 离开后 B 成为房主  
5. iOS ↔ Android 各做一次房主

## 安全说明

- 账号密码由 GO-IM 校验；会话 token 存 Keychain / EncryptedSharedPreferences
- 配置只含 GO-IM 地址与对象存储凭证；分享链接 `paircast://config?args=…` 含加密后的存储密钥，勿公开传播

## 文档

- 索引：[docs/README.md](docs/README.md)
- 产品：[docs/PRD.md](docs/PRD.md)
- 设计：[docs/DESIGN.md](docs/DESIGN.md) · 本地预览 [docs/design-preview/index.html](docs/design-preview/index.html)
- 技术：[docs/TECH.md](docs/TECH.md)
- Agent 约定：[AGENTS.md](AGENTS.md)
