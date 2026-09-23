#!/usr/bin/env bash
# Install ImSDK_Plus xcframework into Vendor/, using a machine-local zip/fw cache
# so self-hosted CI does not re-download on every run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/ImSDKSPM/ImSDK_Plus.xcframework"
VERSION="9.0.7652"
URL="https://im.sdk.cloud.tencent.cn/download/plus/${VERSION}/ImSDK_Plus_${VERSION}.xcframework.zip"
CHECKSUM="561a3e647b5f3b704d81dfe3dae7d804a743a25646e97b1cb999c7bed1ca39a2"
NAME="ImSDK_Plus.xcframework"

CACHE_ROOT="${PAIRCAST_VENDOR_CACHE:-$HOME/Library/Caches/Paircast/vendor}"
CACHE_DIR="$CACHE_ROOT/imsdk/${VERSION}"
CACHED_ZIP="$CACHE_DIR/${NAME}.zip"
CACHED_FW="$CACHE_DIR/${NAME}"

if [[ -d "$DEST" ]]; then
  echo "ImSDK_Plus already present at $DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")" "$CACHE_DIR"

restore_fw() {
  local src="$1"
  echo "Restoring ImSDK_Plus from cache: $src"
  rm -rf "$DEST"
  cp -R "$src" "$DEST"
}

if [[ -d "$CACHED_FW" ]]; then
  restore_fw "$CACHED_FW"
  exit 0
fi

verify_zip() {
  local zip="$1"
  local actual
  actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
  if [[ "$actual" != "$CHECKSUM" ]]; then
    echo "Checksum mismatch for $zip: expected $CHECKSUM got $actual" >&2
    return 1
  fi
}

VENDOR_ZIP="$ROOT/Vendor/ImSDKSPM/${NAME}.zip"
if [[ -f "$CACHED_ZIP" ]] && verify_zip "$CACHED_ZIP"; then
  echo "Using cached zip: $CACHED_ZIP"
elif [[ -f "$VENDOR_ZIP" ]] && verify_zip "$VENDOR_ZIP"; then
  echo "Seeding cache from $VENDOR_ZIP"
  cp "$VENDOR_ZIP" "$CACHED_ZIP"
else
  rm -f "$CACHED_ZIP"
  echo "Downloading ImSDK_Plus (~12MB) → $CACHED_ZIP"
  curl -L --retry 5 --retry-delay 2 -C - -o "${CACHED_ZIP}.partial" "$URL"
  mv "${CACHED_ZIP}.partial" "$CACHED_ZIP"
  verify_zip "$CACHED_ZIP" || {
    rm -f "$CACHED_ZIP"
    exit 1
  }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$CACHED_ZIP" -d "$TMP"
if [[ -d "$TMP/$NAME" ]]; then
  FOUND="$TMP/$NAME"
else
  FOUND="$(find "$TMP" -maxdepth 2 -type d -name "$NAME" | head -1)"
fi
if [[ -z "${FOUND:-}" || ! -d "$FOUND" ]]; then
  echo "Could not find $NAME inside zip" >&2
  exit 1
fi

rm -rf "$CACHED_FW"
mv "$FOUND" "$CACHED_FW"
restore_fw "$CACHED_FW"
echo "Installed $DEST (cached under $CACHE_DIR)"
