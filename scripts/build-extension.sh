#!/usr/bin/env bash
# Compiles the extension's TypeScript (extension/src) into plain JavaScript
# (extension/build). The packaging scripts and the Safari converter consume
# the build output; browsers never see the TypeScript.
set -euo pipefail
cd "$(dirname "$0")/../extension"

if [ ! -d node_modules ]; then
  npm ci --silent
fi
npx tsc -p tsconfig.json
echo "extension built: extension/build"
