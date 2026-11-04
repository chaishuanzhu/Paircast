# Paircast Server

[Paircast](https://paircast.chaisz.com) 一起看 App 的服务端：账号与管理后台、片库（S3 兼容对象存储 + TMDB 刮削 + 在线字幕）、观影房间。聊天与实时信令由 [GO-IM](https://github.com/chaishuanzhu/GO-IM) 提供，本服务作为 GO-IM 的接入方调用其服务端 API。

- 源码：https://github.com/chaishuanzhu/Paircast（`server/`）
- 项目介绍 / App 下载：https://paircast.chaisz.com
- 依赖镜像：[`870027381/go-im-gateway`](https://hub.docker.com/r/870027381/go-im-gateway)（需要先部署 GO-IM）

<!-- DEPLOY -->
