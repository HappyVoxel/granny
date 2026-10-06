#!/usr/bin/env bash
# Builds the release archive for GitHub Releases and the Homebrew cask:
#   dist/release/granny-<version>.zip         the app
#   dist/release/granny-<version>.zip.sha256  its digest
#   dist/release/granny-<version>.dmg         drag-to-Applications disk image
#
# After running: create the GitHub release, upload the zip and the dmg, and
# copy the sha256 into packaging/homebrew/Casks/granny.rb before pushing the
# tap.
set -euo pipefail
cd "$(dirname "$0")/.."

# Same literal as build-app.sh; CI overrides it with the resolved release
# version.
VERSION="${GRANNY_VERSION:-0.1.2}"
OUT="dist/release"

bash scripts/build-app.sh

rm -rf "$OUT"
mkdir -p "$OUT"

ditto -c -k --sequesterRsrc --keepParent "dist/granny.app" "$OUT/granny-$VERSION.zip"
shasum -a 256 "$OUT/granny-$VERSION.zip" | awk '{print $1}' >"$OUT/granny-$VERSION.zip.sha256"

# The dmg carries the drag-to-Applications affordance non-technical users
# expect; the zip stays because the updater and the cask read it. create-dmg
# draws the Finder layout (background, icon slots, drop link) that a plain
# `hdiutil -srcfolder` image lacks.
STAGE="$(mktemp -d)"
cp -R "dist/granny.app" "$STAGE/granny.app"
command -v create-dmg >/dev/null || {
  echo "create-dmg missing: brew install create-dmg" >&2
  exit 1
}
create-dmg \
  --volname "granny" \
  --background "$PWD/scripts/assets/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 420 \
  --icon-size 120 \
  --icon "granny.app" 170 200 \
  --hide-extension "granny.app" \
  --app-drop-link 490 200 \
  --no-internet-enable \
  "$OUT/granny-$VERSION.dmg" "$STAGE"
rm -rf "$STAGE"

# A stable asset name so the landing page can link
# .../releases/latest/download/granny-macos.dmg across versions.
cp "$OUT/granny-$VERSION.dmg" "$OUT/granny-macos.dmg"

echo "release: $OUT/granny-$VERSION.zip"
echo "sha256:  $(cat "$OUT/granny-$VERSION.zip.sha256")"
echo "dmg:     $OUT/granny-$VERSION.dmg (and granny-macos.dmg)"
echo ""
echo "next:"
echo "  1. gh release create v$VERSION $OUT/granny-$VERSION.zip $OUT/granny-$VERSION.dmg $OUT/granny-macos.dmg"
echo "  2. put the sha256 above into packaging/homebrew/Casks/granny.rb"
echo "  3. copy that cask into the HappyVoxel/homebrew-tap repository"
