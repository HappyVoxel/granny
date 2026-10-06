#!/usr/bin/env bash
# Packs the Chrome extension into dist/granny-chrome(.zip).
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build-extension.sh

OUT=dist/granny-chrome
rm -rf "$OUT" dist/granny-chrome.zip
mkdir -p "$OUT"
cp extension/build/background.js extension/build/intercept.js \
   extension/build/theme.js extension/build/options.js "$OUT/"
cp extension/shared/options.html "$OUT/"
mkdir -p "$OUT/icons"
cp extension/shared/icons/*.png "$OUT/icons/"
cp extension/chrome/manifest.json "$OUT/manifest.json"

(cd dist && zip -qr granny-chrome.zip granny-chrome)
echo "packed: dist/granny-chrome.zip"
echo "load unpacked (dev): chrome://extensions -> Load unpacked -> $OUT"
