# Paircast Jenkins 任务

Jenkins（https://jenkins.chaisz.com，仅内网）上的 Paircast 构建与发布。任务都是 Pipeline script（非 SCM），脚本以本目录为准，改完用
Jenkins CLI `update-job` 或任务配置页同步过去。

| 任务 | 脚本 | 作用 |
|------|------|------|
| `paircast` | `paircast.groovy` | iOS IPA（App Store 签名）→ TestFlight、Android 签名 APK、触发 `paircast-server`；正式包另发 GitHub Release |
| `paircast-server` | `paircast-server.groovy` | 服务端镜像推送 Docker Hub（`sha-<提交>`；正式包另打 `X.Y.Z` + `latest`），部署测试环境 `go-im-test` |
| `paircast-tags` | `paircast-tags.groovy` | 每 3 分钟查 GitHub，新 tag `vX.Y.Z` → 以 `TAG` 启动 `paircast` |

节点：`docker`（ci-01，解析提交、发版校验、镜像构建与部署）、`node-mac`（单测、Android、iOS、TestFlight、GitHub Release）。

## 正式包

1. 在分支上准备发版内容并提交：
   - 版本号：`iosApp/Project.swift` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 与 `gradle.properties` 的
     `paircast.versionName` / `paircast.versionCode` 一致，构建号高于 TestFlight 上已有的；`paircast.goimVersion` 为依赖的 GO-IM 版本
   - 文档：隐私协议、用户协议、使用说明、部署文档（`docs/`），`docs/PRD.md` / `docs/TECH.md`
   - 提审文案：`metadata/version/X.Y.Z/{zh-Hans,en-US}.json`（`whatsNew` 也是 TestFlight 的测试说明）、`metadata/REVIEW_NOTES.md`；
     演示账号只填在 App Store Connect
   - 本地 `Scripts/release.sh check vX.Y.Z` 通过
2. 合入 `main`，在 `main` 上打 tag 并推送：`git tag vX.Y.Z && git push origin vX.Y.Z`
3. `paircast-tags` 启动 `paircast`（`TAG=vX.Y.Z`）：
   - 校验 `Scripts/release.sh check`（版本号、提审文案、GO-IM 版本）与 `on-main`（tag 指向的提交已在 `main` 上）
   - 共享层单测 → 签名 APK → App Store IPA（fastlane `archive_appstore`）
   - TestFlight：上传到内部测试组与 External Testers，提交 Beta 审核（`SUBMIT_REVIEW`）
   - 同时 `paircast-server`：镜像 `870027381/paircast-server:X.Y.Z` + `latest`、同步 Docker Hub Overview、部署测试环境
   - 部署生产（`DEPLOY_PROD`，前面全部成功后）：见下文
   - GitHub Release `vX.Y.Z`：IPA + APK，说明由 `Scripts/release.sh notes` 生成；再重建 LiveContainer 源 `docs/source.json` 推到 `main`

App Store 正式版本的提交仍在 App Store Connect 里选这次的构建后提审。

## 部署

| 包 | 环境 | 方式 |
|----|------|------|
| 测试包 | 测试环境 k8s `go-im-test`（https://paircast.test.chaisz.com） | `paircast-server` 的 `DEPLOY`：`kubectl set image` 为 `sha-<提交>`，失败回滚 |
| 正式包 | 先测试环境（镜像 `X.Y.Z`），再各生产主机 | `paircast` 的 `Deploy prod` |

生产主机、地址与域名只记录在 Jenkins 凭据 `paircast-prod-targets` 里，不写进仓库。

生产部署：`paircast` 在 ci-01 上按 `paircast-prod-targets` 的顺序逐台执行 `ssh <主机> X.Y.Z`。专用密钥 `paircast-prod-ssh` 在主机的
authorized_keys 中被限制为只能运行 `paircast-deploy.sh`（即 `server/deploy/docker/prod-deploy.sh`，放在
`docker-compose.paircast.yml` 所在目录）：拉取 `870027381/paircast-server:X.Y.Z` → 改 `.env` 的 `PAIRCAST_TAG` → 重建 `paircast`
→ 本机 `/health`，失败恢复原版本；随后 Jenkins 检查公网 `/health`。任一台失败即停止，后面的主机不部署。只更新 Paircast 服务，
GO-IM 网关由 GO-IM 的流水线发布，发版前确认生产的 GO-IM 不低于 `paircast.goimVersion`。

- 改了 `prod-deploy.sh` 后同步到每台主机的 `paircast-deploy.sh`
- 加一台生产主机：拷贝脚本、在 authorized_keys 加上述受限公钥（`jenkins-paircast-prod`），在 `paircast-prod-targets` 加一行
  `名称 地址 端口 公网地址 主机公钥类型 主机公钥`（主机公钥用 `ssh-keyscan -t ed25519 -p <端口> <地址>` 获取）
- 手动重部署 / 回滚到某个版本：在主机上执行 `paircast-deploy.sh X.Y.Z`

## 测试包

在 Jenkins 手动运行 `paircast`，`TAG` 留空，`BRANCH` 填要测的分支（可以是当前开发分支）：

- IPA 构建号为 `<CURRENT_PROJECT_VERSION - 1>.<Jenkins 构建号>`（例如 `14.7`），高于上一个正式包、低于下一个，只进 TestFlight 内部测试组，不提审。
  发版后先提高版本号 / 构建号再出测试包
- APK 的 versionName 为 `X.Y.Z-test.<Jenkins 构建号>`，与正式包同一签名，在构建的 Artifacts 里下载
- 服务端镜像 `sha-<提交>` 部署测试环境（`DEPLOY_TEST`），不打版本标签
- 不发 GitHub Release

## 凭据

| ID | 类型 | 用途 |
|----|------|------|
| `paircast-ios-keychain-password` | Secret text | node-mac 上 `~/Library/Keychains/iOSDevKeychain-db`（Apple Distribution 证书）的密码 |
| `paircast-android-keystore` | Secret file | Android 正式签名 keystore（PKCS12，alias `paircast`） |
| `paircast-android-signing` | Username with password | 用户名 = key alias，密码 = keystore / key 密码 |
| `goim-asc-api-key` / `goim-asc-api-ids` | Secret file / Username with password | App Store Connect API Key（同一团队 8PHCHYD8X3） |
| `github-token` | Secret text | 发布 Release、推送 LiveContainer 源 |
| `dockerhub`、`k8s-deployer-kubeconfig` | | `paircast-server` 推镜像与部署 |
| `paircast-prod-ssh` | SSH Username with private key | 生产主机 root，只能执行 `paircast-deploy.sh` |
| `paircast-prod-targets` | Secret file | 生产主机列表（地址、端口、主机公钥、公网地址），不进仓库 |

Android keystore 一旦用于发布就不能更换（否则已安装的用户无法升级），备份不进仓库。
