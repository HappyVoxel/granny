#!/usr/bin/env bash
# The identity a local build signs with.
#
# A stable identity is what keeps macOS grants across rebuilds: notifications,
# Automation (the janitor), and the Safari extension all key off the signature.
# Ad-hoc signatures ("-") change bytes on every build, so the grants are
# re-prompted and Safari stops trusting the extension.
#
# GRANNY_CODESIGN_IDENTITY overrides the choice (the test seam); otherwise the
# first Apple Development certificate is used, and a machine without one falls
# back to ad-hoc so the build still works.
set -euo pipefail

if [ -n "${GRANNY_CODESIGN_IDENTITY:-}" ]; then
  printf '%s' "$GRANNY_CODESIGN_IDENTITY"
  exit 0
fi

found=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
printf '%s' "${found:--}"
