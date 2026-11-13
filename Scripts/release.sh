#!/usr/bin/env bash
# Release helpers shared by the IPA / APK workflows and the Jenkins paircast-server job. A tag vX.Y.Z releases
# the iOS app, the Android app and the server image 870027381/paircast-server:X.Y.Z from the same commit.
#
# Usage (repo root or anywhere):
#   Scripts/release.sh check   vX.Y.Z          tag = iOS MARKETING_VERSION = Android versionName, builds equal,
#                                              GO-IM v<paircast.goimVersion> contains the imserver SDK in server/go.mod
#   Scripts/release.sh notes   vX.Y.Z          print the GitHub Release body
#   Scripts/release.sh publish vX.Y.Z <file>   create the release if needed, upload <file>, (re)write the body (needs gh + GH_TOKEN)
# GH_TOKEN is optional for check / notes (GitHub API rate limit).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=870027381/paircast-server
GOIM_REPO=chaishuanzhu/GO-IM

prop() { sed -n "s/^paircast\.$1=//p" gradle.properties; }
ios_setting() { sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" iosApp/Project.swift | head -1; }

ios_version=$(ios_setting MARKETING_VERSION)
ios_build=$(ios_setting CURRENT_PROJECT_VERSION)
android_version=$(prop versionName)
android_code=$(prop versionCode)
goim_version=$(prop goimVersion)
imserver=$(awk '$1 == "github.com/chaishuanzhu/GO-IM/pkg/imserver" { print $2; exit }' server/go.mod)

# Pseudo-version v0.0.0-<time>-<sha12> → commit; a real module version → its tag pkg/imserver/<version>.
imserver_ref() {
    if [[ "$imserver" =~ -([0-9a-f]{12})$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "pkg/imserver/$imserver"; fi
}

github_api() {
    curl -fsS --retry 3 -H 'Accept: application/vnd.github+json' ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
        "https://api.github.com/$1"
}

parse_tag() {
    [[ "${1:-}" =~ ^v([1-9][0-9]*\.[0-9]+\.[0-9]+)$ ]] || { echo "tag 须为 vX.Y.Z：${1:-}" >&2; exit 2; }
    version="${BASH_REMATCH[1]}"
}

check() {
    parse_tag "$1"
    local fail=0
    [ "$ios_version" = "$version" ] || { echo "iosApp/Project.swift MARKETING_VERSION=${ios_version}，与 tag $1 不一致" >&2; fail=1; }
    [ "$android_version" = "$version" ] || { echo "gradle.properties paircast.versionName=${android_version}，与 tag $1 不一致" >&2; fail=1; }
    [ "$ios_build" = "$android_code" ] || { echo "CURRENT_PROJECT_VERSION=$ios_build 与 paircast.versionCode=$android_code 不一致" >&2; fail=1; }
    [[ "$goim_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "gradle.properties paircast.goimVersion 未设置或格式不对：$goim_version" >&2; fail=1; }
    [ -n "$imserver" ] || { echo "server/go.mod 里没有 GO-IM imserver 依赖" >&2; fail=1; }
    [ "$fail" = 0 ] || exit 1

    # base...head: "behind" / "identical" = the SDK commit is contained in the GO-IM release tag.
    local status
    status=$(github_api "repos/$GOIM_REPO/compare/v$goim_version...$(imserver_ref)" |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["status"])') ||
        { echo "无法比较 GO-IM v$goim_version 与 imserver ${imserver}（tag 不存在或 GitHub API 不可用）" >&2; exit 1; }
    case "$status" in
        behind | identical) ;;
        *) echo "GO-IM v$goim_version 不包含 server/go.mod 使用的 imserver ${imserver}（${status}）：提高 paircast.goimVersion 或等 GO-IM 发版" >&2; exit 1 ;;
    esac
    echo "release $1: app $version ($ios_build), server $IMAGE:$version, GO-IM >= $goim_version (imserver $imserver)"
}

notes() {
    parse_tag "$1"
    cat <<EOF
Paircast **$1**：iOS、Android 与服务端同版本发布。

| 组件 | 产物 | 版本 |
|------|------|------|
| iOS | \`Paircast-$1-build$ios_build.ipa\`（App Store 签名） | $ios_version ($ios_build) |
| Android | \`Paircast-$1-build$android_code.apk\` | $android_version ($android_code) |
| 服务端 | Docker 镜像 [\`$IMAGE:$version\`](https://hub.docker.com/r/$IMAGE/tags)（同时为 \`latest\`） | $version |

### 依赖的 GO-IM

- 需要 GO-IM **$goim_version** 或更新的版本：网关镜像 \`870027381/go-im-gateway:$goim_version\`（[GO-IM v$goim_version](https://github.com/$GOIM_REPO/releases/tag/v$goim_version)）
- 服务端 SDK：\`github.com/$GOIM_REPO/pkg/imserver $imserver\`
- 升级顺序：GO-IM → Paircast 服务 → App。部署见[服务端部署指南](https://paircast.chaisz.com/zh-Hans/deploy/)。
EOF
}

publish() {
    parse_tag "$1"
    local file="${2:?usage: $0 publish vX.Y.Z <file>}" body
    test -f "$file"
    body=$(notes "$1")
    # The IPA and APK jobs run concurrently: whoever loses the create race just uploads.
    gh release view "$1" >/dev/null 2>&1 ||
        gh release create "$1" --title "$1" --notes "$body" --target "$(git rev-parse HEAD)" ||
        gh release view "$1" >/dev/null
    gh release upload "$1" "$file" --clobber
    gh release edit "$1" --notes "$body"
    echo "published $(basename "$file") to release $1"
}

cmd="${1:-}"
shift || true
case "$cmd" in
    check) check "$@" ;;
    notes) notes "$@" ;;
    publish) publish "$@" ;;
    *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
