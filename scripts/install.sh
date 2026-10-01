#!/usr/bin/env bash
# One-command install from source.
#
#   ./scripts/install.sh                # everything
#   ./scripts/install.sh --dry-run      # show what would happen
#   ./scripts/install.sh --no-helper    # skip the sudo helper step
#   ./scripts/install.sh --no-extension # skip browser extensions
#
# Requirements: macOS 14+, full Xcode (SwiftUI macros need its toolchain).
#
# The only steps a human must do afterwards are consent toggles Apple and
# Google require and no script can press:
#   - Safari: Settings > Extensions > tick "granny Extension"
#   - Chrome-family: chrome://extensions > Load unpacked > dist/granny-chrome
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
WITH_HELPER=1
WITH_EXTENSION=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-helper) WITH_HELPER=0 ;;
    --no-extension) WITH_EXTENSION=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done
export GRANNY_DRY_RUN="$DRY_RUN"

say() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

if [ ! -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
  say "Xcode is required (the app target needs its SwiftUI macro toolchain)."
  say "Install Xcode from the App Store, open it once, then rerun."
  exit 1
fi

say "== 1/4 build the app"
run bash scripts/build-app.sh

say "== 2/4 install the app + login agent"
run bash scripts/install-app.sh

if [ "$WITH_HELPER" = "1" ]; then
  say "== 3/4 install the root helper (asks for your password once)"
  run sudo bash scripts/install-helper.sh
else
  say "== 3/4 helper skipped (--no-helper)"
fi

if [ "$WITH_EXTENSION" = "1" ]; then
  say "== 4/4 install browser extensions"
  run bash scripts/install-extension.sh
else
  say "== 4/4 extensions skipped (--no-extension)"
fi

say ""
say "done. three one-time consent toggles remain (Apple/Google require a human):"
say "  Safari:        Settings > Extensions > tick 'granny Extension'"
say "  Chrome-family: chrome://extensions > Load unpacked > dist/granny-chrome"
say "  (recommended) Safari: Settings > Advanced > 'Show features for web developers',"
say "                then Develop > 'Allow JavaScript from Apple Events' - lets"
say "                granny purge a tab's service-worker cache before closing it"
say ""
say "then open granny from the menubar > Settings… and paste your API keys (BYOK)."
say "the extension pairs itself with the daemon - no token to paste."
