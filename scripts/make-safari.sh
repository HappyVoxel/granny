#!/usr/bin/env bash
# Generates the Safari web-extension Xcode project with Apple's converter.
# Requires full Xcode (this script uses DEVELOPER_DIR, no xcode-select needed).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SRC=dist/granny-safari-src
rm -rf "$SRC" extension/safari/app
mkdir -p "$SRC"
cp extension/shared/background.js extension/shared/intercept.js \
   extension/shared/options.html extension/shared/options.js "$SRC/"
cp extension/safari/manifest.json "$SRC/manifest.json"

xcrun safari-web-extension-converter "$SRC" \
  --project-location extension/safari/app \
  --app-name "granny" \
  --bundle-identifier io.github.happyvoxel.granny.safari \
  --macos-only --no-open --no-prompt

# Keep the generated project and its builds out of Spotlight/Launchpad.
touch extension/safari/.metadata_never_index

# The converter derives the host app id from the app name (dropping the
# identifier we passed); patch it so the embedded extension validates.
PBXPROJ="extension/safari/app/granny/granny.xcodeproj/project.pbxproj"
sed -i '' -E 's/io\.github\.happyvoxel\.granny\.(granny|Granny-Agent)/io.github.happyvoxel.granny.safari/g' "$PBXPROJ"

echo "Safari project: extension/safari/app"
echo "Open it in Xcode, Run once to install; the extension then appears in"
echo "Safari > Settings > Extensions (enable it once)."
