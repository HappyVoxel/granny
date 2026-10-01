#!/usr/bin/env bash
# End-to-end tests for granny-helper against a sandbox hosts file.
# No root, no real /etc/hosts, no launchd.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HELPER="$REPO/GrannyAgent/.build/debug/granny-helper"
if [ ! -x "$HELPER" ]; then
  (cd "$REPO/GrannyAgent" && swift build --product granny-helper)
fi

SANDBOX="$(mktemp -d)"
trap "rm -rf '$SANDBOX'" EXIT
CHECKS=0
HOSTS="$SANDBOX/hosts"
printf '##\n# Host Database\n127.0.0.1 localhost\n' >"$HOSTS"

MARK_BEGIN="# GRANNY-BEGIN (managed by granny-agent; do not edit)"

run_helper() { GRANNY_HOSTS_FILE="$HOSTS" GRANNY_ALLOW_NONROOT=1 GRANNY_SKIP_DNS_FLUSH=1 "$HELPER" "$@"; }

fail() { echo "e2e-helper FAIL: $1" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" 2>/dev/null || fail "$1 missing: $2"; CHECKS=$((CHECKS + 1)); }
lacks() { if grep -Fq -- "$2" "$1" 2>/dev/null; then fail "$1 still has: $2"; fi; CHECKS=$((CHECKS + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; CHECKS=$((CHECKS + 1)); }
count() {
  local n
  n="$(grep -c -- "$2" "$1" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

# render: defaults include blocked domains and DoH endpoints
out="$(run_helper render)"
case "$out" in *"$MARK_BEGIN"*) CHECKS=$((CHECKS + 1)) ;; *) fail "render missing marker" ;; esac
case "$out" in *"127.0.0.1 facebook.com"*) CHECKS=$((CHECKS + 1)) ;; *) fail "render missing facebook" ;; esac
case "$out" in *"127.0.0.1 dns.google"*) CHECKS=$((CHECKS + 1)) ;; *) fail "render missing DoH endpoint" ;; esac

# apply with a domains file
printf '["facebook.com","tiktok.com"]\n' >"$SANDBOX/domains.json"
run_helper apply "$SANDBOX/domains.json" >/dev/null
has "$HOSTS" "$MARK_BEGIN"
has "$HOSTS" "127.0.0.1 facebook.com"
eq "$(count "$HOSTS" "$MARK_BEGIN")" "1" "marker count"
eq "$(stat -f '%Lp' "$HOSTS")" "644" "hosts permissions"
eq "$(run_helper status)" "blocked" "status after apply"

# re-apply is idempotent
run_helper apply "$SANDBOX/domains.json" >/dev/null
eq "$(count "$HOSTS" "$MARK_BEGIN")" "1" "marker count after re-apply"

# clear restores the file
run_helper clear >/dev/null
lacks "$HOSTS" "$MARK_BEGIN"
has "$HOSTS" "127.0.0.1 localhost"
eq "$(run_helper status)" "clear" "status after clear"

# refuse an empty domain list
printf '[]\n' >"$SANDBOX/empty.json"
if run_helper apply "$SANDBOX/empty.json" >/dev/null 2>"$SANDBOX/err.txt"; then
  fail "empty domain list was accepted"
fi
has "$SANDBOX/err.txt" "refusing"
lacks "$HOSTS" "$MARK_BEGIN"

# refuse to run as non-root when the override is absent (skip when already root)
if [ "$(id -u)" != "0" ]; then
  if env -u GRANNY_ALLOW_NONROOT GRANNY_HOSTS_FILE="$HOSTS" "$HELPER" apply "$SANDBOX/domains.json" >/dev/null 2>"$SANDBOX/err2.txt"; then
    fail "apply ran without root"
  fi
  has "$SANDBOX/err2.txt" "needs root"
fi

# install-helper.sh must work from inside the app bundle (admin dialog path)
bash -n "$REPO/scripts/install-helper.sh" || fail "install-helper.sh syntax"
CHECKS=$((CHECKS + 1))
has "$REPO/scripts/install-helper.sh" "MacOS/granny-helper"
has "$REPO/scripts/install-helper.sh" "GRANNY_USER"

echo "e2e-helper OK ($CHECKS checks)"
