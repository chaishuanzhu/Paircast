# Paircast 文档索引

| 文档 | 用途 |
|------|------|
| [PRD.md](./PRD.md) | 产品需求（当前 **v1.5**） |
| [TECH.md](./TECH.md) | 技术说明 / 架构 / 信令 |
| [DESIGN.md](./DESIGN.md) | 设计约定 |
| [designtoken.md](./designtoken.md) | 设计 Token（色板 / 主题） |
| [design-preview/](./design-preview/) | 本地 UI 预览（静态 HTML） |

## 公开站点（GitHub Pages → paircast.chaisz.com）

| 路径 | 说明 |
|------|------|
| [en-US/](./en-US/)、[zh-Hans/](./zh-Hans/) | 隐私、支持、使用说明 |
| [invite/](./invite/) | 邀请落地页（含 App Store / TestFlight） |
| [livecontainer/](./livecontainer/) | LiveContainer / AltStore source 说明 |
| [source.json](./source.json) | LiveContainer source 清单 |
| [CNAME](./CNAME) | 自定义域 `paircast.chaisz.com` |

改完推送 `main` 后由 Pages 发布。站内链接使用根路径，例如 `/zh-Hans/privacy/`。

## 软著材料

| 路径 | 说明 |
|------|------|
| [soft-copyright/申请表填写稿.md](./soft-copyright/申请表填写稿.md) | 登记表字段 |
| [soft-copyright/软件说明书.md](./soft-copyright/软件说明书.md) | 说明书初稿 |
| `soft-copyright/generated/` | 源程序鉴别材料导出（gitignore，本地生成） |

生成源程序摘录：

```bash
python3 Scripts/export-soft-copyright-sources.py
```

## 维护约定

- 更新 PRD 版本号时，同步修改 `TECH.md` 文首引用。
- 不要把真实配置深链或密钥写进文档。
- Agent / 工程红线见仓库根目录 [AGENTS.md](../AGENTS.md)。
