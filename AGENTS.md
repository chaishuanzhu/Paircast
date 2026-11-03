# Paircast — Agent / 协作者说明

本文件给人和 Agent 用。细节产品说明见 `docs/`，工程启动见根目录 `README.md`。

## 模块与依赖

```
iOS:     App → Presentation ─┐
Android: androidApp ─────────┼→ shared:umbrella → shared:data → shared:core
```

- **shared:core**：纯 Kotlin（commonMain），无 Ktor / 平台 SDK；Entities、Rules、Gateway 接口、UseCases、`WatchSession` + `PlayerPort`
- **shared:data**：GO-IM（WebSocket protobuf + REST）、Paircast 服务端片库 / 房间 / 字幕 / 贴纸客户端（`/media/…`、`/room/…`；存储与第三方密钥只在服务端）
- **shared:umbrella**：`PaircastGraph` 组装（iOS / Android 共用的组合根）；iOS 导出 `PaircastShared` 框架（SKIE）
- **Presentation**（iOS）：SwiftUI Scenes / ViewModel 适配层、VLCKit 播放器（实现 `PlayerPort`）、Keychain
- **App**（iOS）：组装 `PaircastGraph`、Deep Link（`paircast://`）
- **androidApp**：Compose 场景、libVLC 播放器（实现 `PlayerPort`）、EncryptedSharedPreferences、Deep Link

禁止：core 反向依赖 data / 平台代码；业务规则写进 UI 层（应放 shared）。两端 UI 只渲染共享层状态。

## 工程约定

- iOS 全部放在 `iosApp/`（对齐 GO-IM 的 `kmp/iosApp`）：单个 Tuist 清单 `iosApp/Project.swift`（Paircast app + Presentation 静态框架），`make setup` / `cd iosApp && tuist generate`；fastlane / Gemfile / VLCKit 也在 `iosApp/` 下；不要手改生成的 `*.xcodeproj` / `*.xcworkspace`（已 gitignore）
- iOS 构建时由 `Presentation` 的 “Compile Kotlin Framework” 阶段（`iosApp/Scripts/xcode-build-shared.sh` → `embedAndSignAppleFrameworkForXcode`）自动编译 Kotlin，无需手动重建；Gradle 用根目录 `./gradlew`（JDK 17–21）
- 版本号：iOS 在 `iosApp/Project.swift`（`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`），Android 在 `gradle.properties`（`paircast.versionName` / `paircast.versionCode`），两边保持一致
- 文案：两端共用 `iosApp/App/Resources/Localizable.xcstrings`（key = 英文模板）
- 商店文案在 `metadata/`；公开隐私/支持/邀请页在 `docs/`（GitHub Pages → `paircast.chaisz.com`）
- 最低系统：**iOS 26.0**、**Android 8.0（API 26）**

## 密钥与隐私（硬规则）

- **禁止**把真实对象存储密钥、GO-IM 账号密码 / token、`paircast://config?args=` 完整载荷、证书/描述文件/keystore 提交进 git
- 配置、审核备注里的 demo 深链与账号只放 App Store Connect，不入库
- 本地产物：`.asc/`、`.agent-cache/`、`.agent-state/`、软著 `docs/soft-copyright/generated/` 已 ignore

## 文档怎么改

| 类型 | 路径 | 说明 |
|------|------|------|
| 产品 | `docs/PRD.md` | 改需求时同步版本号，并核对 `docs/TECH.md` 引用 |
| 技术 | `docs/TECH.md` | 架构/信令/安全；开头应对齐当前 PRD 版本 |
| 设计 | `docs/DESIGN.md` + `docs/design-preview/` | UI 约定与预览 |
| 公开站 | `docs/en-US/`、`docs/zh-Hans/`（隐私 / 支持 / `guide/` 使用说明 / `deploy/` 服务端部署指南）、`invite/`… | 改完推 `main` 即发布到 Pages |
| 索引 | `docs/README.md` | 文档地图 |

公开域名：**`https://paircast.chaisz.com/`**（无 `/Paircast/` 前缀）。旧 `blog.chaisz.com` / `apps.chaisz.com` 不要再写回。

## 发布相关

- IPA：打 tag `v*` 触发 `.github/workflows/release-ipa.yaml`（self-hosted，先跑 Kotlin 单测，归档时 Xcode 自动编译 KMP 框架）
- APK：`.github/workflows/android.yaml`（PR / main 出 Debug；tag 出 Release，签名走 `PAIRCAST_KEYSTORE_*` secrets）
- TestFlight / ASC：本机 `asc` + keychain；Agent 环境若无完整网络则在本机终端执行
- LiveContainer：`Scripts/update-livecontainer-source.sh` + `docs/source.json`
- 服务端：`server/`（Go 模块 `github.com/chaishuanzhu/Paircast/server`，`/media/…`、`/room/…`，接口定义 `server/api/openapi.yaml`），作为 GO-IM 接入方运行（服务端 API + webhook，SDK `github.com/chaishuanzhu/GO-IM/pkg/imserver`）；`make server-test`。依赖 GO-IM 的 `CmdSignal=25` 类型化信令：播控 `paircast.playback`（客户端互发）、房间快照 `paircast.room_updated`（服务端推送），`content` 为 `{"type","data"}`

## Agent Skills

- 项目工作流：`.cursor/skills/paircast-workflow/SKILL.md`
- Swift 并发（通用）：`.agents/skills/swift-concurrency/SKILL.md`
- Cursor 规则：`.cursor/rules/paircast.mdc`
