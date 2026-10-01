#!/usr/bin/env bash
# Installs the granny extension into every browser found on this Mac.
#
# Automates everything macOS allows: builds the Safari app extension,
# packages the Chrome bundle, opens the exact settings panes. The final
# toggle (Safari) and Load-unpacked click (Chrome-family) are consent steps
# Apple/Google require; no script can press them.
#
# Dry run: GRANNY_DRY_RUN=1 scripts/install-extension.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DRY_RUN="${GRANNY_DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------- browsers

browsers=()
for dir in "/Applications" "$HOME/Applications"; do
  [ -d "$dir/Safari.app" ] && browsers+=("Safari")
done
for app in "Google Chrome" "Brave Browser" "Microsoft Edge" "Arc" "Chromium" "Vivaldi" "Opera"; do
  for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir/$app.app" ] && browsers+=("$app")
  done
done
[ -d "/Applications/Firefox.app" ] && browsers+=("Firefox")

# dedupe while keeping order (bash 3.2 safe array expansion under set -u)
unique=()
for browser in ${browsers[@]+"${browsers[@]}"}; do
  case " ${unique[*]:-} " in *" $browser "*) ;; *) unique+=("$browser") ;; esac
done
browsers=(${unique[@]+"${unique[@]}"})

if [ ${#browsers[@]} -eq 0 ]; then
  say "no supported browser found (Safari, Chrome, Brave, Edge, Arc, Chromium, Vivaldi, Opera, Firefox)"
  exit 1
fi
say "browsers found: ${browsers[*]}"
# ------------------------------------------------------- options (port/token)

OPTIONS="$(python3 - <<'PY'
import json, pathlib
path = pathlib.Path.home() / ".config/granny/config.json"
try:
    cfg = json.loads(path.read_text())
    print(f"{cfg.get('decidePort', 47899)} {cfg.get('token', '')}")
except Exception:
    print("47899 ")
PY
)"
PORT="${OPTIONS%% *}"
TOKEN="${OPTIONS#* }"

# ------------------------------------------------------------- chrome bundle

run bash scripts/package-chrome.sh

# ------------------------------------------------------------------- per browser

for browser in "${browsers[@]}"; do
  case "$browser" in
    Safari)
      say ""
      say "== Safari =="
      if [ ! -d "extension/safari/app/granny/granny.xcodeproj" ]; then
        run bash scripts/make-safari.sh
      fi
      if [ "$DRY_RUN" = "1" ]; then
        say "[dry-run] xcodebuild -project 'extension/safari/app/granny/granny.xcodeproj' -scheme 'granny' ... build"
      else
        xcodebuild -project "extension/safari/app/granny/granny.xcodeproj" \
          -scheme "granny" -configuration Debug \
          -derivedDataPath extension/safari/build \
          CODE_SIGN_IDENTITY=- build >/dev/null 2>&1 || true
        touch extension/safari/build/.metadata_never_index 2>/dev/null || true
      fi
      SAFARI_APP="extension/safari/build/Build/Products/Debug/granny.app"
      if [ -d "$SAFARI_APP" ]; then
        # The containing app only hosts the extension: hide it from
        # Launchpad and the Dock.
        run plutil -replace LSUIElement -bool true "$SAFARI_APP/Contents/Info.plist"
        run codesign --force --deep --sign - "$SAFARI_APP"
        run mkdir -p "$HOME/Applications"
        run rm -rf "$HOME/Applications/granny for Safari.app"
        run cp -R "$SAFARI_APP" "$HOME/Applications/granny for Safari.app"
        # Only the installed copy stays registered with LaunchServices.
        LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        run "$LSR" -u "$PWD/$SAFARI_APP"
        run "$LSR" -f "$HOME/Applications/granny for Safari.app"
        run open "$HOME/Applications/granny for Safari.app"
        run pluginkit -a "$HOME/Applications/granny for Safari.app/Contents/PlugIns/granny Extension.appex" 2>/dev/null || true
        run pluginkit -e use -i io.github.happyvoxel.granny.safari.Extension 2>/dev/null || true
      else
        say "  (build skipped or failed - run the project from Xcode once: open 'extension/safari/app/granny/granny.xcodeproj', Cmd+R)"
      fi
      run open -a Safari
      say "  one-time toggle: Safari > Settings > Extensions > tick 'granny'"
      say "  not listed? open the project in Xcode and Cmd+R once, then check again"
      say "  options: open the extension's settings and set port/token (see below)"
      ;;
    Firefox)
      say ""
      say "== Firefox =="
      say "  temporary: about:debugging#/runtime/this-firefox > Load Temporary Add-on > pick dist/granny-chrome/manifest.json"
      ;;
    *)
      say ""
      say "== $browser =="
      run open -a "$browser" "chrome://extensions"
      run open "dist/granny-chrome"
      say "  then: Developer mode on > Load unpacked > choose dist/granny-chrome"
      say "  options: open the extension's Options and set port/token (see below)"
      ;;
  esac
done

say ""
say "extension options for every browser:"
say "  port:  $PORT"
say "  token: $TOKEN"
say ""
say "note: the daemon must be running (granny-agent) for verdicts; without it the"
say "extension still fail-closes on facebook/instagram/tiktok."
