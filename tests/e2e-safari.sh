#!/usr/bin/env bash
# Slow end-to-end check for the Safari package: regenerate the Xcode project
# with Apple's converter, verify the bundle-id patch, and build it unsigned.
# Needs full Xcode; takes about a minute.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CHECKS=0

fail() { echo "e2e-safari FAIL: $1" >&2; exit 1; }

bash scripts/make-safari.sh >/dev/null 2>&1 || fail "safari-web-extension-converter failed"

PBXPROJ="extension/safari/app/granny/granny.xcodeproj/project.pbxproj"
[ -f "$PBXPROJ" ] || fail "converter produced no project"
CHECKS=$((CHECKS + 1))

if grep -qE 'granny\.(granny|Granny-Agent)' "$PBXPROJ"; then
  fail "bundle-id patch did not apply"
fi
grep -q 'io.github.happyvoxel.granny.safari.Extension' "$PBXPROJ" || fail "extension id missing"
CHECKS=$((CHECKS + 2))

output="$(xcodebuild -project "extension/safari/app/granny/granny.xcodeproj" \
  -scheme "granny" -configuration Debug -derivedDataPath extension/safari/build \
  CODE_SIGNING_ALLOWED=NO build 2>&1)" || { echo "$output" | tail -20; fail "xcodebuild failed"; }

case "$output" in
  *"BUILD SUCCEEDED"*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "no BUILD SUCCEEDED marker" ;;
esac

# Keep the test build product out of Launchpad / Open dialogs.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$REPO/extension/safari/build/Build/Products/Debug/granny.app" 2>/dev/null || true

echo "e2e-safari OK ($CHECKS checks)"
