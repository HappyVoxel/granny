#!/usr/bin/env bash
# End-to-end tests for scripts/proto.sh.
# Sandboxed: stubbed sudo, osascript, and launchctl; a scratch "hosts" file;
# a scratch state dir. No network, no GUI, no /etc/hosts, no launchd.
#
# Usage: bash tests/e2e.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO="$REPO/scripts/proto.sh"
SANDBOX="$(mktemp -d)"
trap "rm -rf '$SANDBOX'" EXIT
CHECKS=0

[ -x "$PROTO" ] || { echo "e2e FAIL: $PROTO not executable" >&2; exit 1; }

# Single source of truth for the marker: read it from the script itself.
MARK_BEGIN="$(sed -n 's/^MARK_BEGIN="\(.*\)"$/\1/p' "$PROTO")"
[ -n "$MARK_BEGIN" ] || { echo "e2e FAIL: cannot extract marker from proto.sh" >&2; exit 1; }

TODAY="$(date +%Y-%m-%d)"

# ------------------------------------------------------------------- stubs

cat >"$SANDBOX/osa" <<'STUB'
#!/usr/bin/env bash
# osascript stub. Reads canned answers from queue files; logs notifications.
set -euo pipefail
sandbox="$GRANNY_TEST_SANDBOX"

script=""
while [ $# -gt 0 ]; do
  case "$1" in
    -e) script="$2"; shift 2 ;;
    *) shift ;;
  esac
done

pop() { # pop <queue-file> -> stdout; 1 when empty
  local file="$1" first
  [ -s "$file" ] || return 1
  first="$(head -1 "$file")"
  awk 'NR > 1' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
  printf '%s\n' "$first"
}

case "$script" in
  *"text returned"*) pop "$sandbox/ask-queue" ;;
  *"button returned"*) pop "$sandbox/confirm-queue" || echo "Quay lại" ;;
  *"display notification"*) echo "$script" >>"$sandbox/notifications.log" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$SANDBOX/osa"

cat >"$SANDBOX/launchctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GRANNY_TEST_SANDBOX/launchctl.log"
exit 0
STUB
chmod +x "$SANDBOX/launchctl"

printf '##\n# Host Database\n127.0.0.1 localhost\n' >"$SANDBOX/hosts"
mkdir -p "$SANDBOX/state"

run_proto() {
  env \
    GRANNY_STATE_DIR="$SANDBOX/state" \
    GRANNY_HOSTS_FILE="$SANDBOX/hosts" \
    GRANNY_LAUNCH_AGENT="$SANDBOX/agent.plist" \
    GRANNY_SUDO="" \
    GRANNY_SKIP_DNS_FLUSH=1 \
    GRANNY_OSA_CMD="$SANDBOX/osa" \
    GRANNY_LAUNCHCTL="$SANDBOX/launchctl" \
    GRANNY_TEST_SANDBOX="$SANDBOX" \
    "$PROTO" "$@"
}

# ---------------------------------------------------------------- asserts

fail() { echo "e2e FAIL: $1" >&2; exit 1; }

contains() { # contains <haystack> <needle> <what>
  case "$1" in
    *"$2"*) CHECKS=$((CHECKS + 1)) ;;
    *) fail "$3 missing: $2" ;;
  esac
}

has() { # has <file> <needle>
  grep -q -- "$2" "$1" 2>/dev/null || fail "$1 missing: $2"
  CHECKS=$((CHECKS + 1))
}

lacks() { # lacks <file> <needle>
  if grep -q -- "$2" "$1" 2>/dev/null; then fail "$1 still contains: $2"; fi
  CHECKS=$((CHECKS + 1))
}

count() { # count <file> <needle> -> stdout
  local n
  n="$(grep -c -- "$2" "$1" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; CHECKS=$((CHECKS + 1)); }

# --------------------------------------------------------------- scenarios

# greet: tasks saved, block applied, notification sent
printf '%s\n' 'Apply 5 jobs; Đọc blog AI' >"$SANDBOX/ask-queue"
out="$(run_proto greet)"
contains "$out" "Block applied." "greet output"
contains "$out" "Today's tasks:" "greet output"
has "$SANDBOX/hosts" "127.0.0.1 www.tiktok.com"
has "$SANDBOX/hosts" "127.0.0.1 localhost"
eq "$(count "$SANDBOX/hosts" "$MARK_BEGIN")" "1" "marker count after greet"
has "$SANDBOX/state/tasks.json" "\"$TODAY\""
eq "$(count "$SANDBOX/state/tasks.json" '"title"')" "2" "task count"
has "$SANDBOX/notifications.log" "Ngoại đã ghi sổ"

# greet again the same day: no-op, still one marker
out="$(run_proto greet)"
contains "$out" "Already greeted today" "second greet"
eq "$(count "$SANDBOX/hosts" "$MARK_BEGIN")" "1" "marker count after second greet"

# status: block on, tasks listed
out="$(run_proto status)"
contains "$out" "Block: ON" "status"
contains "$out" "Apply 5 jobs" "status"

# done with "not yet": block stays
printf '%s\n' 'Quay lại' >"$SANDBOX/confirm-queue"
out="$(run_proto done)"
contains "$out" "Chưa xong" "done-no"
has "$SANDBOX/hosts" "$MARK_BEGIN"

# done with confirm: block removed, tasks marked done
printf '%s\n' 'Đồng ý' >"$SANDBOX/confirm-queue"
out="$(run_proto done)"
contains "$out" "Block removed." "done-yes"
lacks "$SANDBOX/hosts" "$MARK_BEGIN"
has "$SANDBOX/notifications.log" "Tốt lắm cháu"
python3 - "$SANDBOX/state/tasks.json" <<'PY' || fail "tasks not marked done"
import json, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["tasks"] and all(t["done"] for t in doc["tasks"]), doc
PY
CHECKS=$((CHECKS + 1))

# remind with today's tasks: stays quiet
before="$(count "$SANDBOX/notifications.log" "Mở Terminal")"
run_proto remind >/dev/null
eq "$(count "$SANDBOX/notifications.log" "Mở Terminal")" "$before" "remind quiet with tasks"

# block again, then dayoff: flag set, block removed, greet and status agree
run_proto block >/dev/null
printf '%s\n' 'Đồng ý' >"$SANDBOX/confirm-queue"
out="$(run_proto dayoff)"
contains "$out" "Day off recorded." "dayoff"
lacks "$SANDBOX/hosts" "$MARK_BEGIN"
eq "$(<"$SANDBOX/state/dayoff")" "$TODAY" "dayoff flag date"
out="$(run_proto status)"
contains "$out" "Mode: day off" "status dayoff"
out="$(run_proto greet)"
contains "$out" "day off" "greet on day off"

# remind on day off: stays quiet
before="$(count "$SANDBOX/notifications.log" "Mở Terminal")"
run_proto remind >/dev/null
eq "$(count "$SANDBOX/notifications.log" "Mở Terminal")" "$before" "remind quiet on day off"

# no state at all: remind notifies
rm -rf "$SANDBOX/state"
mkdir -p "$SANDBOX/state"
run_proto remind >/dev/null
has "$SANDBOX/notifications.log" "Mở Terminal"

# install/uninstall: plist written with the right label, launchctl called
run_proto install >/dev/null
has "$SANDBOX/agent.plist" "io.github.happyvoxel.granny.proto"
has "$SANDBOX/agent.plist" "<string>remind</string>"
has "$SANDBOX/launchctl.log" "bootstrap"
run_proto uninstall >/dev/null
if [ -f "$SANDBOX/agent.plist" ]; then fail "plist not removed on uninstall"; fi
CHECKS=$((CHECKS + 1))
has "$SANDBOX/launchctl.log" "bootout"

echo "e2e OK ($CHECKS checks)"
