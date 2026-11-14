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
   - GitHub Release `vX.Y.Z`：IPA + APK，说明由 `Scripts/release.sh notes` 生成；再重建 LiveContainer 源 `docs/source.json` 推到 `main`

App Store 正式版本的提交仍在 App Store Connect 里选这次的构建后提审。

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

Android keystore 一旦用于发布就不能更换（否则已安装的用户无法升级），备份不进仓库。
