# Tandem

异地好友同步观影 + 实时聊天的 iOS App（SwiftUI · Clean Architecture · Tuist）。

## 要求

- Xcode 26+ / iOS 26.0+
- [Tuist](https://tuist.dev) 4.x（`brew install tuist`）

## 快速开始

```bash
make setup    # tuist install && tuist generate
make test     # 跑各模块单测
make open     # 打开生成的 workspace
```

或手动：

```bash
tuist install
tuist generate
tuist test
```

## 模块

| 模块 | 职责 |
|------|------|
| Domain | Entities / UseCases / Gateway 协议 / 纯规则 |
| Data | Keychain、UserSig、七牛目录、元数据、IM/房间内存适配、字幕、播放器适配 |
| Presentation | SwiftUI Scenes + ViewModels（对照 `docs/design-preview`） |
| App | 组装与 Deep Link `tandem://` |

依赖方向：`App → Presentation/Data → Domain`。

## 安全说明（MVP）

持有配置中的 IM `SecretKey` 即可为任意 `userID` 签发 UserSig；登录密码仅为非空弱校验，真实成败以 IM login 为准。配置请存 Keychain，导出二维码勿公开分享。

## 文档

- 产品：[docs/PRD.md](docs/PRD.md)
- 设计：[docs/DESIGN.md](docs/DESIGN.md) · 本地预览 [docs/design-preview/index.html](docs/design-preview/index.html)
- 技术：[docs/TECH.md](docs/TECH.md)
