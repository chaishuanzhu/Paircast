#!/usr/bin/env bash
# Install VLCKit xcframework into Vendor/, using a machine-local zip/fw cache
# so self-hosted CI does not re-download ~740MB on every run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/VLCKitSPM/VLCKit-all.xcframework"
VERSION="3.6.0"
URL="https://github.com/tylerjonesio/vlckit-spm/releases/download/${VERSION}/VLCKit-all.xcframework.zip"
CHECKSUM="5da4747e001900bbb4153f58db2be4695096c9c2350aea00376ad67b39c053f6"
NAME="VLCKit-all.xcframework"

CACHE_ROOT="${PAIRCAST_VENDOR_CACHE:-$HOME/Library/Caches/Paircast/vendor}"
CACHE_DIR="$CACHE_ROOT/vlckit/${VERSION}"
CACHED_ZIP="$CACHE_DIR/${NAME}.zip"
CACHED_FW="$CACHE_DIR/${NAME}"

if [[ -d "$DEST" ]]; then
  echo "VLCKit already present at $DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")" "$CACHE_DIR"

restore_fw() {
  local src="$1"
  echo "Restoring VLCKit from cache: $src"
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

VENDOR_ZIP="$ROOT/Vendor/VLCKitSPM/${NAME}.zip"
if [[ -f "$CACHED_ZIP" ]] && verify_zip "$CACHED_ZIP"; then
  echo "Using cached zip: $CACHED_ZIP"
elif [[ -f "$VENDOR_ZIP" ]] && verify_zip "$VENDOR_ZIP"; then
  echo "Seeding cache from $VENDOR_ZIP"
  cp "$VENDOR_ZIP" "$CACHED_ZIP"
else
  rm -f "$CACHED_ZIP"
  echo "Downloading VLCKit (~740MB) → $CACHED_ZIP"
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
