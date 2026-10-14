#!/usr/bin/env bash
# End-to-end tests for granny-agent: CLI (status/decide) and the HTTP server.
# Sandboxed via GRANNY_CONFIG_FILE, GRANNY_STATE_DIR and GRANNY_HOSTS_FILE; the
# real config, state and /etc/hosts are never touched - the last section
# asserts that with the hosts file's own hash, because a sandboxed run used to
# reach the installed root helper through sudo and write the real file.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AGENT="$REPO/GrannyAgent/.build/debug/granny-agent"
if [ ! -x "$AGENT" ]; then
  (cd "$REPO/GrannyAgent" && swift build --product granny-agent)
fi

SANDBOX="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT
CHECKS=0

PORT=$((47000 + RANDOM % 2000))
TOKEN=e2e-token

mkdir -p "$SANDBOX/state"
# The relay-proxy kill seam, sandboxed: every granny-agent run in this suite
# gets a sentinel, so no suite can ever signal the machine's real
# networkserviceproxy.
KILL_LOG="$SANDBOX/killall.log"
cat >"$SANDBOX/killall" <<SH
#!/bin/sh
echo "\$@" >> "$KILL_LOG"
SH
chmod +x "$SANDBOX/killall"
# wakeHour 0 / bedtimeHour 24: the phase assertions must not depend on the
# wall clock of the CI runner (a 05:55 UTC run used to sit in the night
# phase and fail "status missing: phase: working"; bedtime is exclusive, so
# 23 would still fail a 23:xx run).
cat >"$SANDBOX/config.json" <<JSON
{"token":"$TOKEN","decidePort":$PORT,"wakeHour":0,"bedtimeHour":24}
JSON

fail() { echo "e2e-agent FAIL: $1" >&2; exit 1; }
contains() { case "$1" in *"$2"*) CHECKS=$((CHECKS + 1)) ;; *) fail "$3 missing: $2" ;; esac; }

write_state() { # write_state <dayOff> <tasksJson>
  local today
  today="$(date +%Y-%m-%d)"
  cat >"$SANDBOX/state/state.json" <<JSON
{"date":"$today","dayOff":$1,"greeted":true,"tasks":$2}
JSON
}

run_agent() {
  GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
    GRANNY_HOSTS_FILE="$SANDBOX/hosts" GRANNY_KILLALL="$SANDBOX/killall" \
    "$AGENT" "$@"
}

# working day, one open task
write_state false '[{"id":"1","title":"Apply 5 jobs","purpose":"","allowedSurfaces":["linkedin.com/jobs*"],"done":false}]'

out="$(run_agent --status)"
contains "$out" "phase: working" "status"
contains "$out" "blocks active: true" "status"

out="$(run_agent --decide https://www.facebook.com/)"
contains "$out" '"action" : "block"' "decide facebook"

out="$(run_agent --decide https://www.linkedin.com/jobs/search/?q=ios)"
contains "$out" '"action" : "allow"' "decide linkedin jobs"

out="$(run_agent --decide https://www.youtube.com/shorts/abc)"
contains "$out" '"action" : "block"' "decide shorts"

out="$(run_agent --decide https://vnexpress.net/tin-tuc)"
contains "$out" '"action" : "allow"' "decide unknown host"

out="$(run_agent --decide https://www.pornhub.com/)"
contains "$out" '"action" : "block"' "decide pornhub"

out="$(run_agent --decide https://gamevui.vn/)"
contains "$out" '"action" : "block"' "decide gamevui"

out="$(run_agent --decide https://www.y8.com/games/x)"
contains "$out" '"action" : "block"' "decide y8"

# HTTP server
GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
  GRANNY_KILLALL="$SANDBOX/killall" \
  "$AGENT" --serve >"$SANDBOX/serve.log" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 40); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" != "1" ]; then
  cat "$SANDBOX/serve.log" >&2
  fail "server did not come up"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")"
[ "$code" = "401" ] || fail "health without token: got $code"
CHECKS=$((CHECKS + 1))

# Tokenless pairing on loopback: the extension fetches its token from here.
body="$(curl -s "http://127.0.0.1:$PORT/hello")"
contains "$body" '"token":"e2e-token"' "hello pairing endpoint"

body="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/health")"
contains "$body" '"ok"' "health with token"

body="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/decide?url=https%3A%2F%2Fwww.facebook.com%2F")"
contains "$body" '"action":"block"' "http decide facebook"

body="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/status")"
contains "$body" '"phase":"working"' "http status"

# Content workflow: YouTube without a title asks for context; forced retry
# with a title falls through to the model tier (no keys -> fail open).
body="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/decide?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc")"
contains "$body" '"action":"need-context"' "http need-context"

# The browser's placeholder title is not a content signal: the engine must
# still ask for the real one instead of judging - and caching - "YouTube".
body="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/decide?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc&title=YouTube&kind=video")"
contains "$body" '"action":"need-context"' "http placeholder title needs context"

body="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/decide?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc&title=Phim+hanh+dong&force=1")"
contains "$body" '"action":"allow"' "http forced decide fails open"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# all done -> rewarded, entertainment allowed
write_state false '[{"id":"1","title":"Apply 5 jobs","purpose":"","allowedSurfaces":[],"done":true}]'
out="$(run_agent --status)"
contains "$out" "phase: rewarded" "status rewarded"
out="$(run_agent --decide https://www.facebook.com/)"
contains "$out" '"action" : "allow"' "decide facebook rewarded"

# day off
write_state true '[{"id":"1","title":"x","purpose":"","allowedSurfaces":[],"done":false}]'
out="$(run_agent --status)"
contains "$out" "phase: dayOff" "status day off"

# --- The pomodoro break window. A running, earned break lifts the block at
# the decision server, and the block returns by itself when the break expires.
# The dials are 1 minute - the clamped floor - so the window is ~60 s and this
# section takes about two and a half minutes; the assertions are not loosened
# to make that faster.
BREAK_DIR="$SANDBOX/break"
mkdir -p "$BREAK_DIR/state"
BREAK_PORT=$((49000 + RANDOM % 1000))
cat >"$BREAK_DIR/config.json" <<JSON
{"token":"$TOKEN","decidePort":$BREAK_PORT,"wakeHour":0,"bedtimeHour":24,"pomodoro":{"workMinutes":1,"shortBreakMinutes":1,"longBreakMinutes":1}}
JSON
write_break_state() { # write_break_state <stage> <finished>
  cat >"$BREAK_DIR/state/state.json" <<JSON
{"date":"$(date +%Y-%m-%d)","dayOff":false,"greeted":true,"tasks":[{"id":"1","title":"Apply 5 jobs","purpose":"","allowedSurfaces":[],"done":false}],"pomodoro":{"stage":"$1","finished":$2}}
JSON
}
write_break_state deepWork 0

GRANNY_CONFIG_FILE="$BREAK_DIR/config.json" GRANNY_STATE_DIR="$BREAK_DIR/state" \
  GRANNY_HOSTS_FILE="$BREAK_DIR/hosts" GRANNY_KILLALL="$SANDBOX/killall" \
  GRANNY_POMODORO_AUTOSTART=1 \
  "$AGENT" --serve >"$BREAK_DIR/serve.log" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 40); do
  if curl -s -o /dev/null -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$BREAK_PORT/health" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" != "1" ]; then
  cat "$BREAK_DIR/serve.log" >&2
  fail "break-window server did not come up"
fi

decide_break() { curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$BREAK_PORT/decide?url=$1"; }
status_break() { curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$BREAK_PORT/status"; }
FACEBOOK='https%3A%2F%2Fwww.facebook.com%2F'

# (a) a running deep-work stage lifts nothing
body="$(decide_break "$FACEBOOK")"
contains "$body" '"action":"block"' "break window: deep work still blocks"
contains "$(status_break)" '"blocksActive":true' "break window: enforced during deep work"

# (b) the stage auto-continues into its break: the same URL is allowed
lifted=0
for _ in $(seq 1 130); do
  body="$(decide_break "$FACEBOOK")"
  case "$body" in *'"reason":"pomodoro break"'*) lifted=1; break ;; esac
  sleep 1
done
[ "$lifted" = "1" ] || fail "the break never lifted the block within 130s (last: $body)"
CHECKS=$((CHECKS + 1))
contains "$body" '"action":"allow"' "break window: running break allows facebook"
contains "$body" '"source":"break"' "break window: source names the break"
body="$(decide_break 'https%3A%2F%2Fwww.youtube.com%2Fshorts%2Fabc')"
contains "$body" '"reason":"pomodoro break"' "break window: shorts are allowed too"
body="$(status_break)"
contains "$body" '"blocksActive":false' "break window: status shows the lift"
contains "$body" '"phase":"working"' "break window: the phase is untouched"

# (c) the block comes back by itself when the break expires
returned=0
for _ in $(seq 1 130); do
  body="$(decide_break "$FACEBOOK")"
  case "$body" in *'"action":"block"'*) returned=1; break ;; esac
  sleep 1
done
[ "$returned" = "1" ] || fail "the block never returned within 130s (last: $body)"
CHECKS=$((CHECKS + 1))
contains "$body" '"action":"block"' "break window: the block returns at expiry"
contains "$(status_break)" '"blocksActive":true' "break window: status enforces again"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# The relaunch shape: a fresh process reads the same state file - the stage
# persisted as a break, no live clock - and blocks; the holiday is never
# inherited. (This process points at the break state dir, not the sandbox's.)
write_break_state shortBreak 1
out="$(GRANNY_CONFIG_FILE="$BREAK_DIR/config.json" GRANNY_STATE_DIR="$BREAK_DIR/state" \
  GRANNY_HOSTS_FILE="$BREAK_DIR/hosts" GRANNY_KILLALL="$SANDBOX/killall" \
  "$AGENT" --decide https://www.facebook.com/)"
contains "$out" '"action" : "block"' "break window: stale break state blocks a fresh launch"

# --- The sandbox hosts seam: a run pointed at a sandbox hosts file writes
# that file and never the real one. It used to escalate through the privileged
# helper tool to the installed root helper, which writes /etc/hosts whatever
# the override says - that tool does not pass GRANNY_HOSTS_FILE through. The
# hash is the assertion: no suite may edit the machine's own hosts file.
HELPER="$REPO/GrannyAgent/.build/debug/granny-helper"
if [ ! -x "$HELPER" ]; then
  (cd "$REPO/GrannyAgent" && swift build --product granny-helper)
fi
hosts_before="$(shasum -a 256 /etc/hosts | awk '{print $1}')"
: >"$SANDBOX/hosts"
: >"$SANDBOX/sudo-sentinel.log"
cat >"$SANDBOX/sudo-sentinel" <<SH
#!/bin/sh
echo "\$@" >> "$SANDBOX/sudo-sentinel.log"
SH
chmod +x "$SANDBOX/sudo-sentinel"
GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
  GRANNY_HOSTS_FILE="$SANDBOX/hosts" GRANNY_KILLALL="$SANDBOX/killall" \
  GRANNY_SUDO="$SANDBOX/sudo-sentinel" \
  GRANNY_ALLOW_NONROOT=1 GRANNY_SKIP_DNS_FLUSH=1 \
  "$AGENT" --apply-blocks >"$SANDBOX/apply.log" 2>&1 \
  || fail "sandboxed apply failed: $(cat "$SANDBOX/apply.log")"
contains "$(cat "$SANDBOX/apply.log")" "apply: ok" "sandboxed apply succeeds"
contains "$(cat "$SANDBOX/hosts")" "facebook.com" "sandboxed apply writes the sandbox hosts"
[ ! -s "$SANDBOX/sudo-sentinel.log" ] \
  || fail "a sandboxed run escalated through sudo: $(cat "$SANDBOX/sudo-sentinel.log")"
CHECKS=$((CHECKS + 1))
[ "$(shasum -a 256 /etc/hosts | awk '{print $1}')" = "$hosts_before" ] \
  || fail "a sandboxed run wrote the real /etc/hosts"
CHECKS=$((CHECKS + 1))

# Without the non-root opt-in the local helper refuses, and the run must fail
# rather than fall back to the administrator prompt that writes the real file.
if GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
   GRANNY_HOSTS_FILE="$SANDBOX/hosts" GRANNY_SUDO="$SANDBOX/sudo-sentinel" \
   GRANNY_SKIP_DNS_FLUSH=1 \
   "$AGENT" --apply-blocks >"$SANDBOX/apply2.log" 2>&1; then
  fail "a sandboxed run without GRANNY_ALLOW_NONROOT reported success"
fi
contains "$(cat "$SANDBOX/apply2.log")" "apply: failed" "a refused sandboxed apply fails loudly"
[ ! -s "$SANDBOX/sudo-sentinel.log" ] \
  || fail "a refused sandboxed apply escalated through sudo"
CHECKS=$((CHECKS + 1))
[ "$(shasum -a 256 /etc/hosts | awk '{print $1}')" = "$hosts_before" ] \
  || fail "a refused sandboxed apply wrote the real /etc/hosts"
CHECKS=$((CHECKS + 1))

# The sentinel is not vacuous: with no override at all the run *does* go
# through the escalation tool, and with that tool replaced by the sentinel --
# which exits 0 without running the helper -- the real file is still
# untouched. So a sandboxed escalation would have been recorded rather than
# silently passing. Only where the installed helper exists: without it the
# escalation path falls through to an administrator prompt, which has no
# answer on a CI runner.
if [ -x /usr/local/libexec/granny/granny-helper ]; then
  : >"$SANDBOX/sudo-sentinel.log"
  GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
    GRANNY_SUDO="$SANDBOX/sudo-sentinel" GRANNY_ALLOW_NONROOT=1 GRANNY_SKIP_DNS_FLUSH=1 \
    "$AGENT" --apply-blocks >"$SANDBOX/apply3.log" 2>&1 \
    || fail "unsandboxed apply with a sentinel sudo failed: $(cat "$SANDBOX/apply3.log")"
  [ -s "$SANDBOX/sudo-sentinel.log" ] \
    || fail "the sudo sentinel was never called, so it cannot catch an escalation"
  CHECKS=$((CHECKS + 1))
  [ "$(shasum -a 256 /etc/hosts | awk '{print $1}')" = "$hosts_before" ] \
    || fail "the sentinel run wrote the real /etc/hosts"
  CHECKS=$((CHECKS + 1))
fi

echo "e2e-agent OK ($CHECKS checks)"
