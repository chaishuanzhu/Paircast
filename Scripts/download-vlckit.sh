#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/VLCKitSPM/VLCKit-all.xcframework"
ZIP="$ROOT/Vendor/VLCKitSPM/VLCKit-all.xcframework.zip"
URL="https://github.com/tylerjonesio/vlckit-spm/releases/download/3.6.0/VLCKit-all.xcframework.zip"
CHECKSUM="5da4747e001900bbb4153f58db2be4695096c9c2350aea00376ad67b39c053f6"
CACHED_ZIP="$ROOT/Tuist/.build/artifacts/vlckit-spm/VLCKit-all.xcframework.zip"
CACHED_FW="$ROOT/Tuist/.build/artifacts/vlckit-spm/VLCKit-all/VLCKit-all.xcframework"

if [[ -d "$DEST" ]]; then
  echo "VLCKit already present at $DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"

if [[ -d "$CACHED_FW" ]]; then
  echo "Using cached xcframework from Tuist/.build"
  cp -R "$CACHED_FW" "$DEST"
  exit 0
fi

if [[ -f "$CACHED_ZIP" ]]; then
  echo "Using cached zip from Tuist/.build"
  cp "$CACHED_ZIP" "$ZIP"
elif [[ ! -f "$ZIP" ]]; then
  echo "Downloading VLCKit (~740MB)…"
  curl -L --retry 5 --retry-delay 2 -C - -o "$ZIP" "$URL"
fi

ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [[ "$ACTUAL" != "$CHECKSUM" ]]; then
  echo "Checksum mismatch: expected $CHECKSUM got $ACTUAL" >&2
  exit 1
fi

TMP="$(mktemp -d)"
unzip -q "$ZIP" -d "$TMP"
# zip root may be the xcframework itself or a folder containing it
if [[ -d "$TMP/VLCKit-all.xcframework" ]]; then
  mv "$TMP/VLCKit-all.xcframework" "$DEST"
else
  FOUND="$(find "$TMP" -maxdepth 2 -type d -name 'VLCKit-all.xcframework' | head -1)"
  mv "$FOUND" "$DEST"
fi
rm -rf "$TMP"
echo "Installed $DEST"
