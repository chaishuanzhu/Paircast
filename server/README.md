# Paircast Server

Paircast 的 Go 服务端：媒体库（`/media/*`：S3 兼容视频源、播放直链、字幕、贴纸）与观影房间（`/room/*`）。
它作为 [GO-IM](https://github.com/chaishuanzhu/GO-IM) 的一个**接入方**运行，只使用 GO-IM 的公开能力（接入说明见 GO-IM `docs/16-integration-guide.md`）：

- **认证**：客户端带 GO-IM 用户令牌（`uid` + `token` 参数或 `Authorization: Bearer`），服务端用 `tokens/verify` 校验（缓存 60 秒）。
- **房间 = GO-IM 群**：建房 `groups/create`，进出房 `groups/members/add|remove`，过期房间清理时 `groups/dismiss`。
- **实时推送**：房间变化用群信令 `paircast.room_updated`（`data` 为 `{"group_id","room"}`）；播放同步由客户端之间直接发 `paircast.playback`。
- **Webhook**：`/im/webhook` 接收 `group.member_left` / `group.dismissed`，同步房间成员。

## 目录

| 路径 | 内容 |
|------|------|
| `cmd/paircast` | 入口与配置加载 |
| `internal/api` | HTTP 接口与 GO-IM 适配（令牌校验、群、信令、webhook） |
| `internal/media` | 媒体库（数据源注册、字幕、贴纸、TMDB 刮削）；`s3source` 为 S3 兼容数据源 |
| `internal/watchroom` | 观影房间（内存 / MySQL 存储、房主转移、清理） |
| `internal/config` | 媒体库配置 |

## 运行

```bash
cp configs/paircast.example.json configs/paircast.json   # 填 media.sources、im.base_url
PAIRCAST_IM_SECRET=... PAIRCAST_IM_WEBHOOK_SECRET=... go run ./cmd/paircast/
# 或在仓库根目录：make server / make server-test
```

GO-IM 网关配置 `gateway.server_api.apps` 中登记同一个 `app_id`，`webhook_url` 指向本服务的 `/im/webhook`，
`webhook_events` 含 `group.member_left` 与 `group.dismissed`；网关用 `GOIM_APP_<ID>_SECRET` / `GOIM_APP_<ID>_WEBHOOK_SECRET` 读取同一对密钥。

环境变量（密钥不要写进配置文件）：

| 变量 | 作用 |
|------|------|
| `PAIRCAST_IM_SECRET` / `PAIRCAST_IM_WEBHOOK_SECRET` | GO-IM 服务端 API 与 webhook 密钥（必需 / 推荐） |
| `PAIRCAST_IM_BASE_URL` / `PAIRCAST_IM_APP_ID` | 覆盖配置中的网关地址与接入方 ID |
| `PAIRCAST_MYSQL_DSN` | 房间与刮削缓存的 MySQL；为空时在内存中 |
| `PAIRCAST_MEDIA_<ID>_ACCESS_KEY` / `_SECRET_KEY` | 视频源密钥，`<ID>` 为源 id 大写（非字母数字转 `_`） |
| `PAIRCAST_BLOB_ACCESS_KEY` / `_SECRET_KEY` | 共享 / 在线字幕存储（`blob_store`）密钥 |
| `PAIRCAST_TMDB_ACCESS_TOKEN` / `PAIRCAST_OPENSUBTITLES_API_KEY` | 可选：TMDB 刮削、在线字幕 |

在线字幕下载按用户限流（每分钟 10 次，超出返回 429）。

## 部署

- 镜像：`docker build -t paircast-server .`（在 `server/` 目录），Docker Hub `870027381/paircast-server`。
- Docker：`deploy/docker/`，与 GO-IM 最小化部署放在同一目录、共用 `.env`，加入其网络 `go-im_default`（步骤见 `docs/zh-Hans/deploy/` 第 5 步）。
- Kubernetes：`deploy/k8s/`，与 GO-IM 部署在同一命名空间，Ingress 把 `/media`、`/room` 转给本服务（说明见 `kustomization.yaml` 头部）。
- 其它反向代理：同域名下 `/media`、`/room` 转到 8090，其余转 GO-IM 网关。
