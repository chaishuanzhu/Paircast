# Paircast Server

Paircast 的 Go 服务端：账号（`/account/*`）、管理后台（`/console/*`）、媒体库（`/media/*`：S3 兼容视频源、播放直链、字幕、贴纸）与观影房间（`/room/*`）。
它作为 [GO-IM](https://github.com/chaishuanzhu/GO-IM) 的一个**接入方**运行，只使用 GO-IM 的公开能力（接入说明见 GO-IM `docs/16-integration-guide.md`）：

- **账号归 Paircast**：邮箱 + 密码（bcrypt），管理员建号（随机初始密码，发邮件或显示给管理员，首次登录须改密）。
  每个账号在 GO-IM 有一个镜像用户（`users/import`，`external_id` = 账号 ID），对客户端暴露的用户 ID 是 GO-IM uid。
- **会话**：登录返回 Paircast 会话令牌（HMAC 签名，改密 / 禁用后失效）和 GO-IM 连接信息（`users/token` 签发的 IM 令牌）；
  `/media`、`/room`、`/account`、`/console` 用会话令牌认证，聊天、上传、拉黑、举报直接用 IM 令牌访问 GO-IM。
- **管理后台**：账号增删、禁用（同步禁用 IM 账号）；举报审核走 GO-IM `reports/list|get|resolve`，封禁同时停用 Paircast 账号，管理员不能被封禁。
- **房间 = GO-IM 聊天室**：建房 `groups/create`（`type: chatroom`：只投递在线成员、不存离线、不计未读、不出现在 IM 群列表，成员只能由服务端增减），进出房 `groups/members/add|remove`，过期房间清理时 `groups/dismiss`。
- **实时推送**：房间变化用群信令 `paircast.room_updated`（`data` 为 `{"group_id","room"}`）；播放同步由客户端之间直接发 `paircast.playback`。
- **播放快照**：房主在播停 / 拖动 / 后台暂停时（播放中最多每 15s 一次）`POST /room/playback` 保存进度，房间返回 `playback` + `server_time`；晚加入、回前台、请求同步无人应答的成员按快照对齐，不必等房主在线。
- **Webhook**：`/im/webhook` 接收 `group.member_left` / `group.dismissed`，同步房间成员。
- **对账**：每 5 分钟用 `groups/get` 比对房间成员与 IM 群成员，补上丢失的 webhook（聊天室不存在 → 结束房间；房间多出的人 → 移出房间；IM 群多出的人连续两轮仍在 → 移出群）。

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
| `PAIRCAST_IM_PUBLIC_URL` | 客户端连接 GO-IM 的地址（如 `https://im.example.com`），登录时返回给客户端；Paircast 与 GO-IM 各用一个域名，只有单域名反代时才留空 |
| `PAIRCAST_IM_BASE_URL` / `PAIRCAST_IM_APP_ID` | 覆盖配置中的网关地址与接入方 ID |
| `PAIRCAST_MYSQL_DSN` | 账号、房间与刮削缓存的 MySQL；为空时在内存中（重启丢失）。用 Paircast 独立的库和账号，不要用 GO-IM 的（Docker / k8s 部署会自动建 `paircast` 库与账号，密码 `PAIRCAST_MYSQL_PASSWORD`） |
| `PAIRCAST_MEDIA_<ID>_ACCESS_KEY` / `_SECRET_KEY` | 视频源密钥，`<ID>` 为源 id 大写（非字母数字转 `_`） |
| `PAIRCAST_BLOB_ACCESS_KEY` / `_SECRET_KEY` | 共享 / 在线字幕存储（`blob_store`）密钥 |
| `PAIRCAST_TMDB_ACCESS_TOKEN` / `PAIRCAST_OPENSUBTITLES_API_KEY` | 可选：TMDB 刮削、在线字幕 |

在线字幕下载按用户限流（每分钟 10 次，超出返回 429）。

## 部署

完整的运维文档（架构、Docker Compose / Kubernetes / 单独运行、全部配置项、验证、常见问题）见 [`deploy/README.md`](deploy/README.md)，
它同时是 Docker Hub [`870027381/paircast-server`](https://hub.docker.com/r/870027381/paircast-server) 的 Overview；面向自建用户的图文步骤见网站的服务端部署指南（`docs/zh-Hans/deploy/`）。

- 镜像：`docker build -t paircast-server .`（在 `server/` 目录）。
- 测试环境：Jenkins 任务 `paircast-server`（脚本 `ci/jenkins/paircast-server.groovy`）构建 `sha-<提交>` 镜像并部署到 k8s 命名空间 `go-im-test`。
- 发布：在 `main` 上运行 `paircast-server`，参数 `VERSION=X.Y.Z`（`DEPLOY` 按需），把该提交的镜像同时打上 `X.Y.Z` 与 `latest`，并同步 Docker Hub 的 Overview；只更新 Overview 用 `SYNC_OVERVIEW`。
  Overview 来自 `deploy/dockerhub/paircast-server.md`，其中 `<!-- DEPLOY -->` 替换为 `deploy/README.md`（`deploy/dockerhub/sync-readme.sh`）。
- 接口文档：`swagger_enabled: true` 时在 `/swagger/` 提供 Swagger UI（文档内嵌自 `api/openapi/openapi.yaml`）。
