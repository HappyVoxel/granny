#!/usr/bin/env bash
# Typechecks engine/src and bundles the Pi Durable sidecar into a single ESM
# file (engine/build/granny-engine.mjs) using Node's built-in node:sqlite.
set -euo pipefail
cd "$(dirname "$0")/../engine"

if [ ! -d node_modules ]; then
  npm ci --silent
fi
npm run build --silent
echo "engine built: engine/build/granny-engine.mjs"
