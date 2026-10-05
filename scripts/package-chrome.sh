#!/usr/bin/env bash
# Packs the Chrome extension into dist/granny-chrome(.zip).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist/granny-chrome
rm -rf "$OUT" dist/granny-chrome.zip
mkdir -p "$OUT"
cp extension/shared/background.js extension/shared/intercept.js \
   extension/shared/options.html extension/shared/options.js "$OUT/"
mkdir -p "$OUT/icons"
cp extension/shared/icons/*.png "$OUT/icons/"
cp extension/chrome/manifest.json "$OUT/manifest.json"

(cd dist && zip -qr granny-chrome.zip granny-chrome)
echo "packed: dist/granny-chrome.zip"
echo "load unpacked (dev): chrome://extensions -> Load unpacked -> $OUT"
