#!/usr/bin/env bash
# Prepare macOS keychain access for non-interactive codesign (self-hosted CI).
# Optional: set KEYCHAIN_PASSWORD to unlock + rewrite key partition lists.
set -euo pipefail

LOGIN_KC="${LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
IOS_DEV_KC="${IOS_DEV_KEYCHAIN:-$HOME/Library/Keychains/iOSDevKeychain-db}"

if [[ ! -f "$LOGIN_KC" ]]; then
  echo "Login keychain not found: $LOGIN_KC" >&2
  exit 1
fi

# Prefer a stable search order: login first, then optional iOSDev keychain.
SEARCH=("$LOGIN_KC")
if [[ -f "$IOS_DEV_KC" ]]; then
  SEARCH+=("$IOS_DEV_KC")
fi
security list-keychains -d user -s "${SEARCH[@]}"
security default-keychain -s "$LOGIN_KC"

if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  echo "Unlocking keychain(s) for CI signing…"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOGIN_KC"
  security set-keychain-settings -lut 21600 "$LOGIN_KC"
  # Allow codesign / security to use private keys without UI prompts.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$LOGIN_KC" >/dev/null
  if [[ -f "$IOS_DEV_KC" ]]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$IOS_DEV_KC" 2>/dev/null || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$IOS_DEV_KC" >/dev/null 2>&1 || true
  fi
else
  echo "KEYCHAIN_PASSWORD unset — relying on already-unlocked keychain + runner session."
fi

echo "Codesigning identities:"
security find-identity -v -p codesigning
