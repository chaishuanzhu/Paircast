#!/bin/bash
# Paircast production deploy. Install as paircast-deploy.sh in the directory that holds docker-compose.paircast.yml
# and its .env on every production host. The Jenkins job paircast calls it after a release with a dedicated SSH key
# that authorized_keys restricts to this script:
#   command="<dir>/paircast-deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 ... jenkins-paircast-prod
# The only argument is the version X.Y.Z (SSH_ORIGINAL_COMMAND when called over SSH).
# Pull 870027381/paircast-server:X.Y.Z → set PAIRCAST_TAG in .env → recreate paircast → /health; restore the previous
# tag on failure. After changing this file, copy it to the hosts again (see ci/jenkins/README.md).
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
COMPOSE=(docker compose -f docker-compose.paircast.yml)
ver="${SSH_ORIGINAL_COMMAND:-${1:-}}"
if ! [[ "$ver" =~ ^[1-9][0-9]*\.[0-9]+\.[0-9]+$ ]]; then
    echo "版本号须为 X.Y.Z：$ver" >&2
    exit 2
fi

cd "$DIR"
exec 9>"$DIR/.paircast-deploy.lock"
flock -n 9 || { echo "已有 Paircast 部署在进行" >&2; exit 3; }

old=$(sed -n 's/^PAIRCAST_TAG=//p' .env)
port=$(sed -n 's/^PAIRCAST_PORT=//p' .env)
port=${port:-8090}
echo "Paircast 生产部署：${old:-latest} → $ver"

set_tag() {
    if grep -q '^PAIRCAST_TAG=' .env; then
        sed -i "s/^PAIRCAST_TAG=.*/PAIRCAST_TAG=$1/" .env
    else
        echo "PAIRCAST_TAG=$1" >> .env
    fi
}

healthy() {
    local out=''
    for _ in $(seq 1 24); do
        out=$(curl -fsS --max-time 5 "http://127.0.0.1:$port/health" 2>&1) && [ "$out" = ok ] && { echo "/health: ok"; return 0; }
        sleep 5
    done
    echo "健康检查失败：$out" >&2
    return 1
}

PAIRCAST_TAG="$ver" timeout 900 "${COMPOSE[@]}" pull -q paircast

set_tag "$ver"
"${COMPOSE[@]}" up -d paircast
if healthy; then
    "${COMPOSE[@]}" ps paircast --format '{{.Image}} {{.Status}}'
    docker image prune -f >/dev/null
    exit 0
fi

"${COMPOSE[@]}" logs paircast --tail 50 || true
if [ -n "$old" ] && [ "$old" != "$ver" ]; then
    echo "回滚到 $old" >&2
    set_tag "$old"
    "${COMPOSE[@]}" up -d paircast
    healthy || true
fi
exit 1
