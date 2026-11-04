#!/usr/bin/env bash
# 把 server/deploy/dockerhub/paircast-server.md（插入 server/deploy/README.md 部署指南）同步为 Docker Hub 仓库的 Overview 和简介。
#
# 用法: DH_USER=<用户名> DH_TOKEN=<访问令牌> [DH_NAMESPACE=<命名空间>] server/deploy/dockerhub/sync-readme.sh
# 令牌需要 Read & Write 权限。
set -euo pipefail

: "${DH_USER:?需要 DH_USER}"
: "${DH_TOKEN:?需要 DH_TOKEN}"
NS="${DH_NAMESPACE:-$DH_USER}"
DIR="$(cd "$(dirname "$0")" && pwd)"
API=https://hub.docker.com/v2
REPO=paircast-server
SHORT_DESC="Paircast 一起看服务端：账号、片库、观影房间（GO-IM 接入方，Go）"

jwt=$(curl -fsS --retry 3 -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,os;print(json.dumps({"username":os.environ["DH_USER"],"password":os.environ["DH_TOKEN"]}))')" \
  "$API/users/login" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

body=$(SHORT_DESC="$SHORT_DESC" python3 -c '
import json, os, re, sys
page = open(sys.argv[1], encoding="utf-8").read()
lines, fenced = [], False
for line in open(sys.argv[2], encoding="utf-8").read().splitlines():
    if line.startswith("```"):
        fenced = not fenced
    elif not fenced and re.match(r"#+ ", line):
        line = "#" + line
    lines.append(line)
guide = "\n".join(lines)
page = page.replace("<!-- DEPLOY -->", guide.strip() + "\n")
print(json.dumps({"description": os.environ["SHORT_DESC"], "full_description": page}))
' "$DIR/$REPO.md" "$DIR/../README.md")

code=$(curl -sS --retry 3 -o /tmp/dh-sync.out -w '%{http_code}' -X PATCH \
  -H "Authorization: JWT $jwt" -H 'Content-Type: application/json' \
  -d "$body" "$API/repositories/$NS/$REPO/")
if [ "$code" != 200 ]; then
  echo "$REPO: HTTP $code" >&2
  cat /tmp/dh-sync.out >&2
  exit 1
fi
echo "$REPO: overview 已更新"
