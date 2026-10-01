#!/usr/bin/env bash
# Installs the root helper for hard blocking.
#
# What it does, exactly:
#   1. copies granny-helper to /usr/local/libexec/granny/ (root:wheel 755)
#   2. writes /etc/sudoers.d/granny granting the invoking user NOPASSWD for
#      exactly this binary, subcommands "apply" and "clear" only
#   3. validates the sudoers file with visudo before installing it
#
# Run with sudo: sudo scripts/install-helper.sh
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "run me with sudo: sudo $0" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_HELPER="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/MacOS/granny-helper"
HELPER_SRC="${1:-}"
if [ -z "$HELPER_SRC" ]; then
  for candidate in \
    "$REPO_DIR/dist/granny.app/Contents/MacOS/granny-helper" \
    "$REPO_DIR/GrannyAgent/.build/release/granny-helper" \
    "$REPO_DIR/GrannyAgent/.build/debug/granny-helper" \
    "$BUNDLE_HELPER"; do
    if [ -x "$candidate" ]; then
      HELPER_SRC="$candidate"
      break
    fi
  done
fi

if [ -z "$HELPER_SRC" ] || [ ! -x "$HELPER_SRC" ]; then
  echo "granny-helper binary not found; build first: scripts/build-app.sh" >&2
  exit 1
fi

DEST_DIR=/usr/local/libexec/granny
DEST_BIN="$DEST_DIR/granny-helper"
# GRANNY_USER lets the app run this through the admin dialog (no sudo, no
# SUDO_USER in that path); plain `sudo` sets SUDO_USER instead.
USER_NAME="${GRANNY_USER:-${SUDO_USER:-$(id -un)}}"

if [ "$USER_NAME" = "root" ]; then
  echo "SUDO_USER is unset or root; refusing to guess the user for sudoers" >&2
  exit 1
fi

install -d -m 755 -o root -g wheel "$DEST_DIR"
install -m 755 -o root -g wheel "$HELPER_SRC" "$DEST_BIN"

SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT
printf '%s ALL=(root) NOPASSWD: %s apply *, %s clear\n' \
  "$USER_NAME" "$DEST_BIN" "$DEST_BIN" >"$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP"
install -m 440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/granny

echo "helper installed: $DEST_BIN"
echo "sudoers entry:    /etc/sudoers.d/granny (NOPASSWD apply/clear for $USER_NAME)"
echo "uninstall with:   sudo scripts/uninstall-helper.sh"
