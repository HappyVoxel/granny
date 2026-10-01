#!/usr/bin/env bash
# Granny Agent - Phase 0 prototype.
# Hosts-based site blocking plus a greeting dialog, driven by a LaunchAgent.
#
# Requires stock macOS tooling: bash 3.2, python3, osascript.
# `self-test` verifies the pure functions; no sudo, no network.

set -euo pipefail

LABEL="io.github.happyvoxel.granny.proto"
STATE_DIR="${GRANNY_STATE_DIR:-$HOME/.local/state/granny}"
LAUNCH_AGENT="${GRANNY_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/$LABEL.plist}"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Test seams: tests/e2e.sh stubs the system out through these variables.
# SUDO is intentionally unquoted at use sites so tests can set it empty.
HOSTS_FILE="${GRANNY_HOSTS_FILE:-/etc/hosts}"
SUDO="${GRANNY_SUDO-sudo}"
OSA_CMD="${GRANNY_OSA_CMD:-osascript}"
LAUNCHCTL="${GRANNY_LAUNCHCTL:-launchctl}"

MARK_BEGIN="# GRANNY-BEGIN (managed by granny-agent; do not edit)"
MARK_END="# GRANNY-END"

# ponytail: hosts-only block in Phase 0. pf hardening and the root helper
# daemon land in Phase 1a/2; YouTube Shorts granularity is Phase 1b.
BLOCK_DOMAINS="facebook.com www.facebook.com m.facebook.com instagram.com www.instagram.com tiktok.com www.tiktok.com"

TASKS_FILE="$STATE_DIR/tasks.json"
DAYOFF_FILE="$STATE_DIR/dayoff"

# ---------------------------------------------------------------- pure helpers
# These are covered by `self-test` and never touch the system.

render_hosts() { # render_hosts <source-hosts> <dest>
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" -v domains="$BLOCK_DOMAINS" '
    $0 == begin { skipping = 1; next }
    skipping && $0 == end { skipping = 0; next }
    skipping { next }
    { print }
    END {
      print ""
      print begin
      n = split(domains, d, " ")
      for (i = 1; i <= n; i++) print "127.0.0.1 " d[i]
      print end
    }
  ' "$1" >"$2"
}

strip_hosts() { # strip_hosts <source-hosts> <dest>
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0 == begin { skipping = 1; next }
    skipping && $0 == end { skipping = 0; next }
    skipping { next }
    { print }
  ' "$1" >"$2"
}

blocked_now() {
  grep -q "$MARK_BEGIN" "$HOSTS_FILE" 2>/dev/null
}

today() { date +%Y-%m-%d; }

is_dayoff() {
  [ -f "$DAYOFF_FILE" ] && [ "$(<"$DAYOFF_FILE")" = "$(today)" ]
}

tasks_saved_today() {
  [ -f "$TASKS_FILE" ] && grep -q "\"$(today)\"" "$TASKS_FILE"
}

save_tasks() { # save_tasks "<task>; <task>; ..."
  mkdir -p "$STATE_DIR"
  python3 - "$1" "$TASKS_FILE" <<'PY'
import datetime, json, sys

raw, path = sys.argv[1], sys.argv[2]
tasks = [t.strip() for t in raw.split(";") if t.strip()]
doc = {
    "date": datetime.date.today().isoformat(),
    "tasks": [{"title": t, "done": False} for t in tasks],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

print_tasks() {
  [ -f "$TASKS_FILE" ] || { echo "  (none)"; return 0; }
  python3 - "$TASKS_FILE" <<'PY'
import json, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
for task in doc["tasks"]:
    mark = "x" if task["done"] else " "
    print(f"  [{mark}] {task['title']}")
PY
}

mark_all_done() {
  [ -f "$TASKS_FILE" ] || return 0
  python3 - "$TASKS_FILE" <<'PY'
import json, sys

path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for task in doc["tasks"]:
    task["done"] = True
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

# ------------------------------------------------------------ system operations
# Everything below can touch /etc/hosts or launchd and therefore needs sudo.

apply_block() {
  local tmp
  tmp="$(mktemp)"
  render_hosts "$HOSTS_FILE" "$tmp"
  # shellcheck disable=SC2086  # $SUDO may be empty in tests
  $SUDO tee "$HOSTS_FILE" <"$tmp" >/dev/null
  rm -f "$tmp"
  flush_dns
  echo "Block applied."
}

remove_block() {
  local tmp
  tmp="$(mktemp)"
  strip_hosts "$HOSTS_FILE" "$tmp"
  # shellcheck disable=SC2086  # $SUDO may be empty in tests
  $SUDO tee "$HOSTS_FILE" <"$tmp" >/dev/null
  rm -f "$tmp"
  flush_dns
  echo "Block removed."
}

# ponytail: sudo reads the TTY, so these verbs only work from a Terminal.
# The Phase 1a helper daemon removes this limitation.
flush_dns() {
  if [ "${GRANNY_SKIP_DNS_FLUSH:-}" = "1" ]; then return 0; fi
  # shellcheck disable=SC2086
  $SUDO dscacheutil -flushcache >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  $SUDO killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ UI helpers

ask() { # ask <prompt> [default] -> stdout; non-zero on cancel
  "$OSA_CMD" -e "text returned of (display dialog \"$1\" default answer \"${2:-}\" with title \"Granny\")" 2>/dev/null
}

confirm() { # confirm <prompt> -> 0 yes, 1 no
  "$OSA_CMD" -e "button returned of (display dialog \"$1\" buttons {\"Quay lại\", \"Đồng ý\"} default button \"Đồng ý\" with title \"Granny\")" 2>/dev/null | grep -q "Đồng ý"
}

notify() { # notify <message> [title]
  "$OSA_CMD" -e "display notification \"$1\" with title \"${2:-Granny}\"" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- commands

cmd_greet() {
  if is_dayoff; then
    echo "Today is a day off. Nothing to do."
    return 0
  fi
  if tasks_saved_today && [ "${1:-}" != "--force" ]; then
    echo "Already greeted today. Use --force to redo."
    return 0
  fi

  local raw
  raw="$(ask "Hôm nay cháu của ta sẽ làm những gì đây? (ngăn cách bằng dấu ;)")" || {
    echo "Cancelled."
    return 0
  }
  [ -n "$raw" ] || { echo "Empty list, nothing saved."; return 0; }

  save_tasks "$raw"
  apply_block
  notify "Ngoại đã ghi sổ. Làm xong thì báo ngoại nhé."
  echo "Today's tasks:"
  print_tasks
}

cmd_done() {
  confirm "Cháu báo đã xong hết hôm nay?" || {
    echo "Chưa xong thì làm tiếp."
    return 0
  }
  mark_all_done
  remove_block
  notify "Tốt lắm cháu. Đi chơi đi, nhớ về trước 23 giờ."
}

cmd_dayoff() {
  confirm "Chắc chưa? Ngoại ghi sổ đấy. Hôm nay nghỉ thật à?" || {
    echo "Vậy làm việc tiếp nhé."
    return 0
  }
  mkdir -p "$STATE_DIR"
  today >"$DAYOFF_FILE"
  if blocked_now; then remove_block; fi
  notify "Ngoại ghi sổ rồi. Nghỉ ngơi đi cháu."
  echo "Day off recorded."
}

cmd_block() { apply_block; }

cmd_unblock() { remove_block; }

cmd_status() {
  if blocked_now; then echo "Block: ON"; else echo "Block: OFF"; fi
  if is_dayoff; then
    echo "Mode: day off"
  elif tasks_saved_today; then
    echo "Tasks:"
    print_tasks
  else
    echo "Tasks: none for today"
  fi
}

cmd_remind() {
  if is_dayoff || tasks_saved_today; then return 0; fi
  notify "Hôm nay cháu của ta sẽ làm những gì đây? Mở Terminal và chạy: $SCRIPT_PATH greet"
}

cmd_install() {
  mkdir -p "$(dirname "$LAUNCH_AGENT")"
  cat >"$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_PATH</string>
    <string>remind</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
  echo "Installed $LABEL (notifies at login)."
}

cmd_uninstall() {
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  echo "Uninstalled $LABEL."
}

# ------------------------------------------------------------------- self-test

cmd_self_test() {
  local dir checks=0
  dir="$(mktemp -d)"
  trap "rm -rf '$dir'" EXIT

  selftest_fail() {
    echo "self-test FAIL: $1" >&2
    exit 1
  }

  cat >"$dir/in" <<'EOF'
##
# Host Database
127.0.0.1 localhost
255.255.255.255 broadcasthost
EOF

  render_hosts "$dir/in" "$dir/blocked"
  grep -q "$MARK_BEGIN" "$dir/blocked" || selftest_fail "block marker missing"
  grep -q "127.0.0.1 www.tiktok.com" "$dir/blocked" || selftest_fail "tiktok not blocked"
  grep -q "127.0.0.1 localhost" "$dir/blocked" || selftest_fail "user lines lost"
  [ "$(grep -c "$MARK_BEGIN" "$dir/blocked" || true)" = "1" ] || selftest_fail "marker not unique"
  checks=$((checks + 1))

  render_hosts "$dir/blocked" "$dir/blocked2"
  [ "$(grep -c "$MARK_BEGIN" "$dir/blocked2" || true)" = "1" ] || selftest_fail "render not idempotent"
  [ "$(grep -c "facebook.com" "$dir/blocked2" || true)" = "3" ] || selftest_fail "unexpected facebook count"
  checks=$((checks + 1))

  strip_hosts "$dir/blocked2" "$dir/stripped"
  grep -q "$MARK_BEGIN" "$dir/stripped" && selftest_fail "marker survived strip"
  grep -q "tiktok.com" "$dir/stripped" && selftest_fail "domain survived strip"
  grep -q "127.0.0.1 localhost" "$dir/stripped" || selftest_fail "user lines lost on strip"
  checks=$((checks + 1))

  strip_hosts "$dir/in" "$dir/untouched"
  [ "$(grep -c "127.0.0.1 localhost" "$dir/untouched" || true)" = "1" ] || selftest_fail "strip altered clean file"
  checks=$((checks + 1))

  echo "self-test OK ($checks checks)"
}

usage() {
  cat <<'EOF'
granny proto - Phase 0 prototype

  greet [--force]    Ask for today's tasks, save them, apply the block (sudo)
  done               Confirm everything is done, remove the block (sudo)
  dayoff             Mark today as a day off, remove the block (sudo)
  block | unblock    Apply or remove the block only (sudo)
  status             Show block state, today's tasks, day-off state
  remind             Notification only; used by the LaunchAgent
  install | uninstall  Manage the LaunchAgent
  self-test          Verify the pure functions; no sudo, no network

State: ~/.local/state/granny/   Override with GRANNY_STATE_DIR.
Tests: tests/e2e.sh stubs the system via the GRANNY_* env overrides.
EOF
}

case "${1:-}" in
  greet) shift; cmd_greet "$@" ;;
  done) cmd_done ;;
  dayoff) cmd_dayoff ;;
  block) cmd_block ;;
  unblock) cmd_unblock ;;
  status) cmd_status ;;
  remind) cmd_remind ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  self-test) cmd_self_test ;;
  *) usage; exit 1 ;;
esac
