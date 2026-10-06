#!/usr/bin/env bash
# Builds dist/granny.app (ad-hoc signed, runs locally).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Releases pass GRANNY_VERSION; the literal stays in sync with the cask and
# the extension manifests (tests/e2e-extension.sh checks that).
VERSION="${GRANNY_VERSION:-0.1.2}"

# SwiftPM records the deployment target as the SDK version in the Mach-O,
# which keeps macOS 26+ on the legacy design. Re-stamp the real SDK version
# (the deployment target stays 14.0) so Liquid Glass is adopted.
SDK_VERSION=$(xcrun --show-sdk-version --sdk macosx)
swift build -c release --package-path GrannyAgent \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
BIN_DIR="GrannyAgent/.build/release"
APP="dist/granny.app"

bash scripts/make-icon.sh || echo "warning: icon generation failed; building without icon"

rm -rf "$APP" dist/GrannyAgent.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/granny-agent" "$BIN_DIR/granny-helper" "$APP/Contents/MacOS/"
cp scripts/install-helper.sh "$APP/Contents/Resources/"
if [ -f scripts/assets/granny.icns ]; then
  cp scripts/assets/granny.icns "$APP/Contents/Resources/granny.icns"
fi

# Ship a load-unpacked-ready Chrome extension inside the app, so Homebrew
# users can install it without the source tree.
bash scripts/build-extension.sh
EXT_DIR="$APP/Contents/Resources/extension"
mkdir -p "$EXT_DIR/icons"
cp extension/build/background.js extension/build/intercept.js \
   extension/build/theme.js extension/build/options.js "$EXT_DIR/"
cp extension/shared/options.html "$EXT_DIR/"
cp extension/shared/icons/*.png "$EXT_DIR/icons/"
cp extension/chrome/manifest.json "$EXT_DIR/manifest.json"

# Keep build output out of Spotlight/Launchpad.
touch dist/.metadata_never_index

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.happyvoxel.granny</string>
  <key>CFBundleName</key><string>granny</string>
  <key>CFBundleDisplayName</key><string>granny</string>
  <key>CFBundleExecutable</key><string>granny-agent</string>
  <key>CFBundleIconFile</key><string>granny.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed (app still runs locally)"

# Keep the build output out of Launchpad / Open dialogs: the installed copy
# in ~/Applications is the one that should be registered.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$PWD/$APP" 2>/dev/null || true

echo "built $APP"
