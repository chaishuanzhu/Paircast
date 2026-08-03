#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/ImSDKSPM/ImSDK_Plus.xcframework"
ZIP="$ROOT/Vendor/ImSDKSPM/ImSDK_Plus.xcframework.zip"
URL="https://im.sdk.cloud.tencent.cn/download/plus/9.0.7652/ImSDK_Plus_9.0.7652.xcframework.zip"
CHECKSUM="561a3e647b5f3b704d81dfe3dae7d804a743a25646e97b1cb999c7bed1ca39a2"

if [[ -d "$DEST" ]]; then
  echo "ImSDK_Plus already present at $DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"

if [[ ! -f "$ZIP" ]]; then
  echo "Downloading ImSDK_Plus (~12MB)…"
  curl -L --retry 5 --retry-delay 2 -C - -o "$ZIP" "$URL"
fi

ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [[ "$ACTUAL" != "$CHECKSUM" ]]; then
  echo "Checksum mismatch: expected $CHECKSUM got $ACTUAL" >&2
  exit 1
fi

TMP="$(mktemp -d)"
unzip -q "$ZIP" -d "$TMP"
if [[ -d "$TMP/ImSDK_Plus.xcframework" ]]; then
  mv "$TMP/ImSDK_Plus.xcframework" "$DEST"
else
  FOUND="$(find "$TMP" -maxdepth 2 -type d -name 'ImSDK_Plus.xcframework' | head -1)"
  mv "$FOUND" "$DEST"
fi
rm -rf "$TMP"
echo "Installed $DEST"
