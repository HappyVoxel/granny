#!/usr/bin/env bash
# Copies the app to ~/Applications and installs the login-item LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="dist/granny.app"
[ -d "$APP_SRC" ] || { echo "build first: scripts/build-app.sh" >&2; exit 1; }

DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/granny.app"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP" "$DEST_DIR/GrannyAgent.app"
cp -R "$APP_SRC" "$DEST_APP"

# The installed copy is the one Launchpad / Open dialogs should see.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$PWD/$APP_SRC" 2>/dev/null || true
"$LSR" -f "$DEST_APP" 2>/dev/null || true

LABEL=io.github.happyvoxel.granny
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Legacy labels from the pre-rebrand (personal-branding) builds. Kept so a
# dev machine that installed the old build is migrated cleanly instead of
# keeping a stale agent pointing at a removed app.
for OLD_LABEL in io.github.binhlien.granny io.github.binhlien.granny.agent io.github.binhlien.granny.proto; do
  launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
done

mkdir -p "$(dirname "$PLIST")"
cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST_APP/Contents/MacOS/granny-agent</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout can leave the old process running (it survives as an orphan and
# keeps the decision server's port): kill any straggler outright, or the
# fresh copy fails to bind 47899 and every decision goes unanswered.
pkill -f "$DEST_APP/Contents/MacOS/granny-agent" 2>/dev/null || true
sleep 1
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  # Transient launchd races happen right after replacing the bundle.
  sleep 2
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || {
    echo "warning: login agent not loaded; rerun scripts/install-app.sh" >&2
  }
fi

# The installed copy is the one app; drop the build output so Launchpad and
# Open dialogs never see a duplicate.
rm -rf "$APP_SRC"

echo "installed $DEST_APP and login agent $LABEL"
echo "next: sudo $DEST_APP/Contents/Resources/install-helper.sh   # hard blocking"
