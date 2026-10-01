#!/usr/bin/env bash
# Builds the release archive for GitHub Releases and the Homebrew cask:
#   dist/release/granny-<version>.zip         the app
#   dist/release/granny-<version>.zip.sha256  its digest
#
# After running: create the GitHub release, upload the zip, and copy the
# sha256 into packaging/homebrew/Casks/granny.rb before pushing the tap.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${GRANNY_VERSION:-0.1.0}"
OUT="dist/release"

bash scripts/build-app.sh

rm -rf "$OUT"
mkdir -p "$OUT"

ditto -c -k --sequesterRsrc --keepParent "dist/granny.app" "$OUT/granny-$VERSION.zip"
shasum -a 256 "$OUT/granny-$VERSION.zip" | awk '{print $1}' >"$OUT/granny-$VERSION.zip.sha256"

echo "release: $OUT/granny-$VERSION.zip"
echo "sha256:  $(cat "$OUT/granny-$VERSION.zip.sha256")"
echo ""
echo "next:"
echo "  1. gh release create v$VERSION $OUT/granny-$VERSION.zip"
echo "  2. put the sha256 above into packaging/homebrew/Casks/granny.rb"
echo "  3. copy that cask into the HappyVoxel/homebrew-tap repository"
