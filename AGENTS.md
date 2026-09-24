# Paircast — Agent / 协作者说明

本文件给人和 Agent 用。细节产品说明见 `docs/`，工程启动见根目录 `README.md`。

## 模块与依赖

```
App → Presentation / Data → Domain
```

- **Domain**：纯 Swift，无 UI / 无网络 SDK；Entities、UseCases、Gateway 协议、规则
- **Data**：Keychain、S3 兼容存储、腾讯云 IM、字幕、元数据、播放器适配
- **Presentation**：SwiftUI Scenes / ViewModels
- **App**：组装依赖、Deep Link（`paircast://`）

禁止：Presentation/Data 反向依赖、Domain 引入 UIKit/第三方 IM·VLC。

## 工程约定

- 用 **Tuist** 生成工程：`make setup` / `tuist generate`；不要手改生成的 `*.xcodeproj` / `*.xcworkspace`（已 gitignore）
- 版本号在 `Projects/App/Project.swift`：`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
- 商店文案在 `metadata/`；公开隐私/支持/邀请页在 `docs/`（GitHub Pages → `paircast.chaisz.com`）
- 最低系统：**iOS 26.0**

## 密钥与隐私（硬规则）

- **禁止**把真实 IM SecretKey、对象存储密钥、`paircast://config?args=` 完整载荷、证书/描述文件提交进 git
- 配置、审核备注里的 demo 深链只放 App Store Connect，不入库
- 本地产物：`.asc/`、`.agent-cache/`、`.agent-state/`、软著 `docs/soft-copyright/generated/` 已 ignore

## 文档怎么改

| 类型 | 路径 | 说明 |
|------|------|------|
| 产品 | `docs/PRD.md` | 改需求时同步版本号，并核对 `docs/TECH.md` 引用 |
| 技术 | `docs/TECH.md` | 架构/信令/安全；开头应对齐当前 PRD 版本 |
| 设计 | `docs/DESIGN.md` + `docs/design-preview/` | UI 约定与预览 |
| 公开站 | `docs/en-US/`、`docs/zh-Hans/`、`invite/`… | 改完推 `main` 即发布到 Pages |
| 索引 | `docs/README.md` | 文档地图 |

公开域名：**`https://paircast.chaisz.com/`**（无 `/Paircast/` 前缀）。旧 `blog.chaisz.com` / `apps.chaisz.com` 不要再写回。

## 发布相关

- IPA：打 tag `v*` 触发 `.github/workflows/release-ipa.yaml`（self-hosted）
- TestFlight / ASC：本机 `asc` + keychain；Agent 环境若无完整网络则在本机终端执行
- LiveContainer：`Scripts/update-livecontainer-source.sh` + `docs/source.json`

## Agent Skills

- 项目工作流：`.cursor/skills/paircast-workflow/SKILL.md`
- Swift 并发（通用）：`.agents/skills/swift-concurrency/SKILL.md`
- Cursor 规则：`.cursor/rules/paircast.mdc`
