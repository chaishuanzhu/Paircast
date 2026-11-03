# Paircast Server

Paircast 的 Go 服务端：账号（`/account/*`）、管理后台（`/console/*`）、媒体库（`/media/*`：S3 兼容视频源、播放直链、字幕、贴纸）与观影房间（`/room/*`）。
它作为 [GO-IM](https://github.com/chaishuanzhu/GO-IM) 的一个**接入方**运行，只使用 GO-IM 的公开能力（接入说明见 GO-IM `docs/16-integration-guide.md`）：

- **账号归 Paircast**：邮箱 + 密码（bcrypt），管理员建号（随机初始密码，发邮件或显示给管理员，首次登录须改密）。
  每个账号在 GO-IM 有一个镜像用户（`users/import`，`external_id` = 账号 ID），对客户端暴露的用户 ID 是 GO-IM uid。
- **会话**：登录返回 Paircast 会话令牌（HMAC 签名，改密 / 禁用后失效）和 GO-IM 连接信息（`users/token` 签发的 IM 令牌）；
  `/media`、`/room`、`/account`、`/console` 用会话令牌认证，聊天、上传、拉黑、举报直接用 IM 令牌访问 GO-IM。
- **管理后台**：账号增删、禁用（同步禁用 IM 账号）；举报审核走 GO-IM `reports/list|get|resolve`，封禁同时停用 Paircast 账号，管理员不能被封禁。
- **房间 = GO-IM 群**：建房 `groups/create`，进出房 `groups/members/add|remove`，过期房间清理时 `groups/dismiss`。
- **实时推送**：房间变化用群信令 `paircast.room_updated`（`data` 为 `{"group_id","room"}`）；播放同步由客户端之间直接发 `paircast.playback`。
- **Webhook**：`/im/webhook` 接收 `group.member_left` / `group.dismissed`，同步房间成员。

## 目录

| 路径 | 内容 |
|------|------|
| `cmd/paircast` | 入口与配置加载 |
| `internal/account` | 账号：存储（内存 / MySQL `paircast_users`）、会话令牌、IM 镜像用户、管理员引导、SMTP、`/account/*` 与 `/console/*` |
| `internal/api` | 媒体库与房间 HTTP 接口、GO-IM 适配（群、信令、webhook） |
| `internal/media` | 媒体库（数据源注册、字幕、贴纸、TMDB 刮削）；`s3source` 为 S3 兼容数据源 |
| `internal/watchroom` | 观影房间（内存 / MySQL 存储、房主转移、清理） |
| `internal/config` | 媒体库配置 |

## 运行

```bash
cp configs/paircast.example.json configs/paircast.json   # 填 media.sources、im.base_url
PAIRCAST_SESSION_SECRET=$(openssl rand -hex 32) PAIRCAST_ADMIN_EMAIL=you@example.com \
PAIRCAST_IM_SECRET=... PAIRCAST_IM_WEBHOOK_SECRET=... go run ./cmd/paircast/
# 或在仓库根目录：make server / make server-test
```

GO-IM 网关配置 `gateway.server_api.apps` 中登记同一个 `app_id`，`webhook_url` 指向本服务的 `/im/webhook`，
`webhook_events` 含 `group.member_left` 与 `group.dismissed`；网关用 `GOIM_APP_<ID>_SECRET` / `GOIM_APP_<ID>_WEBHOOK_SECRET` 读取同一对密钥。

环境变量（密钥不要写进配置文件）：

| 变量 | 作用 |
|------|------|
| `PAIRCAST_SESSION_SECRET` | 会话令牌密钥（必需，≥ 16 字符） |
| `PAIRCAST_ADMIN_EMAIL` | 启动时确保该管理员存在；新建时初始密码发邮件（未配置发信则写日志） |
| `PAIRCAST_MAIL_PASSWORD` | SMTP 密码（配置 `mail.enabled` 时） |
| `PAIRCAST_IM_SECRET` / `PAIRCAST_IM_WEBHOOK_SECRET` | GO-IM 服务端 API 与 webhook 密钥（必需 / 推荐）；未设置时读网关同名变量 `GOIM_APP_PAIRCAST_SECRET` / `_WEBHOOK_SECRET` |
| `PAIRCAST_IM_PUBLIC_URL` | 客户端连接 GO-IM 的地址；为空表示与本服务同域名 |
| `PAIRCAST_IM_BASE_URL` / `PAIRCAST_IM_APP_ID` | 覆盖配置中的网关地址与接入方 ID |
| `PAIRCAST_MYSQL_DSN` | 账号、房间与刮削缓存的 MySQL；为空时在内存中（重启丢失） |
| `PAIRCAST_MEDIA_<ID>_ACCESS_KEY` / `_SECRET_KEY` | 视频源密钥，`<ID>` 为源 id 大写（非字母数字转 `_`） |
| `PAIRCAST_BLOB_ACCESS_KEY` / `_SECRET_KEY` | 共享 / 在线字幕存储（`blob_store`）密钥 |
| `PAIRCAST_TMDB_ACCESS_TOKEN` / `PAIRCAST_OPENSUBTITLES_API_KEY` | 可选：TMDB 刮削、在线字幕 |

在线字幕下载按用户限流（每分钟 10 次，超出返回 429）。

## 部署

- 镜像：`docker build -t paircast-server .`（在 `server/` 目录），Docker Hub `870027381/paircast-server`。
- 测试环境：Jenkins 任务 `paircast-server`（脚本 `ci/jenkins/paircast-server.groovy`）构建 `sha-<提交>` 镜像并部署到 k8s 命名空间 `go-im-test`。
- Docker：`deploy/docker/`，与 GO-IM 最小化部署放在同一目录、共用 `.env` 与 `apps.env`，加入其网络 `go-im_default`（步骤见 `docs/zh-Hans/deploy/` 第 2–4 步）。
- Kubernetes：`deploy/k8s/`，与 GO-IM 部署在同一命名空间、共用 Secret `goim-apps`，Ingress 把 `/account`、`/console`、`/media`、`/room` 转给本服务（说明见 `kustomization.yaml` 头部）。
- 其它反向代理：同域名下 `/account`、`/console`、`/media`、`/room` 转到 8090，其余转 GO-IM 网关。
