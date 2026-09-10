#!/usr/bin/env bash
# Archive + export a signed App Store IPA for Paircast (self-hosted CI / local).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARTIFACTS="${ARTIFACTS_DIR:-$ROOT/.asc/artifacts}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ARTIFACTS/Paircast.xcarchive}"
IPA_PATH="${IPA_PATH:-$ARTIFACTS/Paircast.ipa}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-$ROOT/.github/ci/ExportOptions.plist}"
SCHEME="${SCHEME:-Paircast}"
CONFIGURATION="${CONFIGURATION:-Release}"

mkdir -p "$ARTIFACTS"

if [[ ! -d "$ROOT/Paircast.xcworkspace" ]]; then
  echo "Paircast.xcworkspace missing — run: tuist install && tuist generate --no-open" >&2
  exit 1
fi

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
  echo "ExportOptions not found: $EXPORT_OPTIONS" >&2
  exit 1
fi

echo "==> Archiving $SCHEME ($CONFIGURATION)"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -workspace "$ROOT/Paircast.xcworkspace" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=8PHCHYD8X3

echo "==> Exporting IPA → $IPA_PATH"
rm -f "$IPA_PATH"
EXPORT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXPORT_DIR"' EXIT

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

shopt -s nullglob
EXPORTED=( "$EXPORT_DIR"/*.ipa )
if [[ ${#EXPORTED[@]} -eq 0 ]]; then
  echo "No IPA produced in $EXPORT_DIR" >&2
  ls -la "$EXPORT_DIR" >&2 || true
  exit 1
fi
cp "${EXPORTED[0]}" "$IPA_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE_PATH/Info.plist")"
echo "==> Done: $IPA_PATH (version $VERSION build $BUILD)"
ls -lah "$IPA_PATH"
