# Paircast 服务部署指南

Paircast 服务（镜像 `870027381/paircast-server`，`linux/amd64` + `linux/arm64`）是 Paircast App 的业务后端：账号与管理后台、片库、观影房间。聊天、在线信令、文件存储由 [GO-IM](https://github.com/chaishuanzhu/GO-IM) 提供，Paircast 服务以 GO-IM「接入方」的身份调用它的服务端 API，所以**先部署 GO-IM，再部署本服务**。

面向自建用户的图文步骤见 [服务端部署指南](https://paircast.chaisz.com/zh-Hans/deploy/)；本文是运维参考：架构、三种部署方式、全部配置项、验证与排错。

## 架构

```
            Paircast 域名（App 里填这个）            GO-IM 域名（登录时由服务端告诉 App）
App ──────▶ paircast.example.com ──▶ Paircast 服务 :8090
App ──────▶ im.example.com ──────────────────────────────▶ GO-IM 网关 :8080（WebSocket、上传、拉黑、举报）
                       Paircast 服务 ── 签名的服务端 API（/server/v1/*）──▶ GO-IM 网关
                       Paircast 服务 ◀── webhook（/im/webhook）────────── GO-IM 网关
```

- **两个域名**：Paircast 与 GO-IM 各用一个域名。App 只填 Paircast 的地址，GO-IM 的对外地址由 `im.public_url` 配置，随登录返回给 App。
- **账号**：账号存在 Paircast（邮箱 + 密码，管理员建号）；每个账号在 GO-IM 有一个镜像用户，App 看到的用户 ID 是 GO-IM uid。
- **数据**：账号、房间和刮削缓存存在 MySQL，Paircast **独立的库和账号**（与 GO-IM 可以同一个 MySQL 实例，但不要共用 GO-IM 的库）；共享字幕 / 在线下载的字幕存在 S3 兼容存储（`blob_store`）；视频本身留在你的对象存储里，播放时签发直链，视频流不经过服务器。
- **无状态**：所有状态都在 MySQL，可以多副本（在线字幕下载的限流按副本计）。

## 镜像

| 标签 | 说明 |
|------|------|
| `latest` | 最新发布版本 |
| `1.0.0` 等 | 固定版本，生产环境建议使用 |
| `sha-<commit>` | 某次提交的构建（测试环境用） |

容器监听 `8090`，配置文件路径 `CONFIG_PATH`（默认 `/etc/paircast/paircast.json`），密钥全部用环境变量提供。健康检查 `GET /health`（MySQL 不可用时 503）。

## 前置条件

1. **GO-IM 已运行**，并登记 Paircast 为接入方。在网关配置 `gateway.server_api.apps` 加一项：
   ```json
   {"app_id": "paircast", "webhook_url": "http://paircast:8090/im/webhook",
    "webhook_events": ["group.member_left", "group.dismissed"]}
   ```
   接入方密钥只放在环境变量里，网关和 Paircast 服务读同一对：
   ```bash
   GOIM_APP_PAIRCAST_SECRET=$(openssl rand -hex 32)
   GOIM_APP_PAIRCAST_WEBHOOK_SECRET=$(openssl rand -hex 32)
   ```
   Docker 放在 `apps.env`，Kubernetes 放在 Secret `goim-apps`，改完重启网关。建议同时关闭 GO-IM 的自助注册（`gateway.auth.disable_registration: true`）。
2. **MySQL**：一个给 Paircast 用的库和账号。下面的 Docker / Kubernetes 方式会在 GO-IM 自带的 MySQL 上自动创建（库 `paircast`、账号 `paircast`，只授权这个库）。
3. **视频源**：S3 兼容对象存储（阿里云 OSS、腾讯云 COS、七牛、MinIO、RustFS 等）里的 `mp4` / `m4v` / `mkv`，以及一对**只读**密钥。
4. **字幕存储**（可选）：一个可读写的 S3 兼容桶，用于房主共享字幕和在线字幕下载；不配则这两项不可用。
5. **域名**（推荐）：Paircast 与 GO-IM 两个子域名，用于 HTTPS。

## 方式一：Docker Compose

与 GO-IM 的 `docker-compose.minimal.yml` 放在同一目录、共用 `.env` 与 `apps.env`，加入其网络 `go-im_default`，用服务名访问 `gateway` / `mysql` / `rustfs`。

```bash
cd go-im
base=https://raw.githubusercontent.com/chaishuanzhu/Paircast/main/server/deploy/docker
curl -fsSLO $base/docker-compose.paircast.yml
curl -fsSLO $base/paircast.json        # 改 media.sources 等，见下方「配置」

cat >> .env <<EOF
PAIRCAST_SESSION_SECRET=$(openssl rand -hex 32)
PAIRCAST_IM_PUBLIC_URL=https://im.example.com
PAIRCAST_ADMIN_EMAIL=you@example.com
PAIRCAST_MYSQL_PASSWORD=$(openssl rand -hex 16)
MEDIA_OSS_ACCESS_KEY=只读AccessKey
MEDIA_OSS_SECRET_KEY=只读SecretKey
EOF

docker compose -f docker-compose.paircast.yml up -d
docker compose -f docker-compose.paircast.yml logs paircast    # 出现 listening on :8090 即就绪
```

- `paircast-db` 是一次性服务：每次启动时用 GO-IM 的 `MYSQL_ROOT_PASSWORD` 幂等地建库、建账号并同步 `PAIRCAST_MYSQL_PASSWORD`，然后退出；Paircast 服务等它成功后才启动。
- `.env` 里 Paircast 相关的变量：

  | 变量 | 说明 |
  |------|------|
  | `PAIRCAST_SESSION_SECRET` | 必填，会话令牌密钥（≥ 16 字符） |
  | `PAIRCAST_IM_PUBLIC_URL` | 必填，App 连接 GO-IM 的地址，如 `https://im.example.com` |
  | `PAIRCAST_ADMIN_EMAIL` | 首个管理员邮箱 |
  | `PAIRCAST_MYSQL_PASSWORD` | Paircast 数据库账号密码，默认 `paircast-dev` |
  | `PAIRCAST_MAIL_PASSWORD` | SMTP 密码（`paircast.json` 的 `mail.enabled` 为 true 时） |
  | `MEDIA_OSS_ACCESS_KEY` / `MEDIA_OSS_SECRET_KEY` | 片源 `oss` 的只读密钥；其它源 id 在 compose 的 `environment` 里按 `PAIRCAST_MEDIA_<大写ID>_*` 添加 |
  | `TMDB_ACCESS_TOKEN` / `OPENSUBTITLES_API_KEY` | 可选：TMDB 刮削、在线字幕搜索 |
  | `PAIRCAST_TAG` | 镜像版本，默认 `latest`，生产环境建议固定 |
  | `PAIRCAST_PORT` | 宿主机端口，默认 `8090`（只绑定 127.0.0.1，由反向代理对外） |
  | `MYSQL_ROOT_PASSWORD` / `RUSTFS_SECRET_KEY` | 与 GO-IM 共用 |

- 改 `paircast.json`、`.env` 或 `apps.env` 后：`docker compose -f docker-compose.paircast.yml up -d --force-recreate`。

## 方式二：Kubernetes

清单在 [`server/deploy/k8s`](https://github.com/chaishuanzhu/Paircast/tree/main/server/deploy/k8s)，部署到 GO-IM 所在的命名空间（默认 `go-im`），在 GO-IM 之后应用。

```bash
git clone https://github.com/chaishuanzhu/Paircast.git && cd Paircast/server/deploy/k8s

# 1. GO-IM 侧：Secret goim-apps（网关 envFrom 读取，本服务也读），然后重启网关
kubectl -n go-im create secret generic goim-apps \
  --from-literal=GOIM_APP_PAIRCAST_SECRET=$(openssl rand -hex 32) \
  --from-literal=GOIM_APP_PAIRCAST_WEBHOOK_SECRET=$(openssl rand -hex 32)
kubectl -n go-im rollout restart deployment/gateway

# 2. 修改：
#    paircast.json        media.sources、im.public_url（GO-IM 对外地址）；需要发信时加 mail
#    kustomization.yaml   SESSION_SECRET、ADMIN_EMAIL、MYSQL_PASSWORD、MEDIA_* 密钥、镜像版本 newTag
#    ingress.yaml         Paircast 域名、ingressClassName / tls
kubectl apply -k .
kubectl -n go-im rollout status deployment/paircast
```

- initContainer `db-init` 用 GO-IM 的 `goim-infra` / `MYSQL_ROOT_PASSWORD` 在集群内 MySQL 上建库建账号；`PAIRCAST_MYSQL_DSN` 由 `MYSQL_PASSWORD` 拼出。用外部 MySQL 时删掉 `db-init`，自己建库建账号，并把 `PAIRCAST_MYSQL_DSN` 改成完整 DSN。
- 升级：改 `kustomization.yaml` 的 `newTag` 后重新 `apply`，或 `kubectl -n go-im set image deployment/paircast paircast=870027381/paircast-server:<版本>`。滚动更新为 `maxSurge 1 / maxUnavailable 0`，新旧版本会短暂同时运行。

## 方式三：单独运行容器

GO-IM 部署在别处时，只需让本服务能访问 GO-IM 网关的内网地址、GO-IM 能回调本服务的 `/im/webhook`：

```bash
docker run -d --name paircast --restart unless-stopped -p 8090:8090 \
  -v $(pwd)/paircast.json:/etc/paircast/paircast.json:ro \
  -e PAIRCAST_SESSION_SECRET=$(openssl rand -hex 32) \
  -e PAIRCAST_IM_SECRET=<GOIM_APP_PAIRCAST_SECRET> \
  -e PAIRCAST_IM_WEBHOOK_SECRET=<GOIM_APP_PAIRCAST_WEBHOOK_SECRET> \
  -e PAIRCAST_IM_PUBLIC_URL=https://im.example.com \
  -e PAIRCAST_MYSQL_DSN='paircast:<密码>@tcp(<mysql>:3306)/paircast?parseTime=true&loc=UTC' \
  -e PAIRCAST_ADMIN_EMAIL=you@example.com \
  -e PAIRCAST_MEDIA_OSS_ACCESS_KEY=... -e PAIRCAST_MEDIA_OSS_SECRET_KEY=... \
  870027381/paircast-server:latest
```

`paircast.json` 里 `im.base_url` 填 GO-IM 网关的内网地址；GO-IM 侧 `webhook_url` 填 `http://<本服务地址>:8090/im/webhook`。数据库要自己建：

```sql
CREATE DATABASE paircast CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'paircast'@'%' IDENTIFIED BY '<密码>';
GRANT ALL PRIVILEGES ON paircast.* TO 'paircast'@'%';
```

## 配置

`paircast.json`（完整注释示例：[`server/configs/paircast.example.json`](https://github.com/chaishuanzhu/Paircast/blob/main/server/configs/paircast.example.json)）：

| 字段 | 说明 |
|------|------|
| `http_addr` | 监听地址，默认 `:8090` |
| `swagger_enabled` | 在 `/swagger/` 提供接口文档（Swagger UI），默认 `false` |
| `im.base_url` | **必填**，GO-IM 网关的内网地址（服务端 API），如 `http://gateway:8080` |
| `im.public_url` | App 连接 GO-IM 的对外地址，如 `https://im.example.com`；只有单域名反代时才留空（= 与本服务同源） |
| `im.app_id` | **必填**，接入方 ID，与 GO-IM `server_api.apps` 一致，默认部署用 `paircast` |
| `im.token_ttl` | 签发给 App 的 IM 令牌有效期，默认 GO-IM 的上限 |
| `account.session_ttl` | 会话有效期，默认 `720h` |
| `mail` | SMTP：`enabled` / `host` / `port`（465 隐式 TLS，其它 STARTTLS）/ `username` / `from`；用于给新账号发初始密码 |
| `media.sources` | **必填，至少一个**视频源：`id`（写进影片 ID，上线后不要改）、`name`、`type: "s3"`、`s3.endpoint`（不含协议，不要填 CDN 域名）/ `bucket` / `region` / `prefix` / `use_ssl` / `path_style` |
| `media.default_source` | 默认片源，空 = 第一个 |
| `media.play_url_ttl` / `list_cache_ttl` | 播放直链有效期（默认 `6h`）/ 影片列表缓存（默认 `60s`） |
| `media.tmdb_language` / `metadata_ttl` | TMDB 语言（默认 `zh-CN`）/ 刮削缓存（默认 `168h`） |
| `media.stickers_source` / `stickers_prefix` | 表情包所在片源与前缀（可选） |
| `media.room_retention` | 无人房间保留时长，默认 `72h` |
| `blob_store` | 共享 / 在线字幕存储（S3 兼容，读写）；`endpoint` 为空则不提供这两项功能 |
| `blob_prefix` | 字幕对象键前缀，默认空 |

环境变量（密钥只用环境变量，不要写进配置文件）：

| 变量 | 作用 |
|------|------|
| `PAIRCAST_SESSION_SECRET` | **必填**，会话令牌密钥（≥ 16 字符）；更换会让所有人重新登录 |
| `PAIRCAST_IM_SECRET` / `PAIRCAST_IM_WEBHOOK_SECRET` | GO-IM 接入方密钥（必填 / 推荐）；未设置时读 `GOIM_APP_<ID>_SECRET` / `_WEBHOOK_SECRET`（与网关共用 `apps.env` / `goim-apps`） |
| `PAIRCAST_IM_BASE_URL` / `PAIRCAST_IM_APP_ID` / `PAIRCAST_IM_PUBLIC_URL` | 覆盖对应配置 |
| `PAIRCAST_ADMIN_EMAIL` | 启动时确保该管理员存在；新建时随机初始密码发到邮箱，未配置或发信失败写日志 |
| `PAIRCAST_MAIL_PASSWORD` | SMTP 密码 |
| `PAIRCAST_MYSQL_DSN` | MySQL DSN；为空时数据在内存中（重启丢失，仅开发用） |
| `PAIRCAST_MEDIA_<ID>_ACCESS_KEY` / `_SECRET_KEY` | 视频源密钥，`<ID>` 为源 id 大写、非字母数字转 `_` |
| `PAIRCAST_BLOB_ACCESS_KEY` / `_SECRET_KEY` | 字幕存储密钥 |
| `PAIRCAST_TMDB_ACCESS_TOKEN` | 可选，TMDB 的 API Read Access Token（v4） |
| `PAIRCAST_OPENSUBTITLES_API_KEY` | 可选，OpenSubtitles consumer 的 API Key |
| `CONFIG_PATH` | 配置文件路径，镜像默认 `/etc/paircast/paircast.json` |

## 反向代理

Paircast 域名整站转到 8090，GO-IM 域名转到 8080（需透传 WebSocket）。Caddy 示例：

```
paircast.example.com {
    reverse_proxy 127.0.0.1:8090
}
im.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

App 的服务器地址填 `paircast.example.com`。

## 验证

```bash
P=https://paircast.example.com
curl -s $P/health                                   # ok
curl -s -o /dev/null -w '%{http_code}\n' $P/media/sources   # 401（需要登录）
curl -s -X POST $P/account/login -d account=you@example.com -d password='初始密码'
# 返回 token、must_change_password 与 im{url, uid, token}；im.url 应为 GO-IM 的对外地址
curl -s "$P/media/sources" -H "Authorization: Bearer <token>"   # 片源列表与 online_subtitles / stickers 开关
```

接口文档：设 `swagger_enabled: true` 后访问 `https://paircast.example.com/swagger/`。

## 运维

- **日志**：`docker compose -f docker-compose.paircast.yml logs -f paircast` / `kubectl -n go-im logs deploy/paircast`。启动时会打印管理员建号结果与 `listening on :8090`。
- **升级 / 回滚**：Docker 改 `PAIRCAST_TAG` 后 `up -d`；Kubernetes 改 `newTag` 或 `set image`。表结构启动时自动迁移，只做向后兼容的变更。
- **备份**：Paircast 的 MySQL 库（账号、房间、刮削缓存）与字幕存储桶。刮削缓存丢失只需重新刮削。
- **管理员**：忘记管理员密码时，在库里删除该账号（`paircast_users`）后重启，服务会按 `PAIRCAST_ADMIN_EMAIL` 重新建号并发送新的初始密码（新账号对应一个新的 GO-IM 用户，旧的聊天记录不会带过来）。
- **更换密钥**：接入方密钥要在 GO-IM 与本服务同时更换；`PAIRCAST_SESSION_SECRET` 更换后所有会话失效。

## 常见问题

| 现象 | 原因与处理 |
|------|------|
| 启动失败 `im.base_url, im.app_id and im.secret ... are required` | 没有拿到接入方密钥：检查 `apps.env` / Secret `goim-apps` 是否挂给了本服务 |
| 启动失败 `media.sources is empty` | 至少配置一个视频源 |
| `paircast-db` / `db-init` 失败 | MySQL 未就绪或 root 密码不对；看该容器日志 |
| 登录返回 401 `invalid account or password` | 账号在 Paircast，不是 GO-IM 的账号；管理员初始密码见邮件或服务日志 |
| 能登录但聊天连不上 | `im.public_url` 没配或填错：App 会去连登录响应里的 `im.url` |
| 房间成员退出后不同步 | GO-IM 侧 `webhook_url` / `webhook_events` 未配置，或 `PAIRCAST_IM_WEBHOOK_SECRET` 与网关不一致（启动日志会有 WARNING） |
| 片库提示服务器未配置 / 503 | 片源密钥缺失或无权限；看服务日志 |
| 没有海报 / 没有在线字幕 | 未配置 TMDB / OpenSubtitles；补上后重启。之前「没找到」的刮削结果缓存 1 小时 |
| 域名返回 404 | 反向代理没有把 Paircast 域名转到本服务 |
