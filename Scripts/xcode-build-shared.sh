#!/bin/bash
# Xcode build phase: compile the KMP umbrella for the current CONFIGURATION / SDK / ARCHS into
# shared/umbrella/build/xcode-frameworks/$CONFIGURATION/$SDK_NAME (official KMP direct integration).
set -euo pipefail

if [ "${OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED:-}" = "YES" ]; then
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Gradle / Kotlin need JDK 17–21; Xcode does not inherit the shell's JAVA_HOME.
jdk_supported() {
  local major
  major="$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$1/release" 2>/dev/null)"
  [ -n "$major" ] && [ "$major" -ge 17 ] && [ "$major" -le 21 ]
}
if [ -z "${JAVA_HOME:-}" ] || ! jdk_supported "$JAVA_HOME"; then
  for candidate in \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
    "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && jdk_supported "$candidate"; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi
# The umbrella also declares the Android target, so Gradle configuration needs an SDK path.
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

cd "$ROOT"
./gradlew :shared:umbrella:embedAndSignAppleFrameworkForXcode
