#!/usr/bin/env bash
# End-to-end tests for granny-agent: CLI (status/decide) and the HTTP server.
# Sandboxed via GRANNY_CONFIG_FILE and GRANNY_STATE_DIR; the real config,
# state, and /etc/hosts are never touched.
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
# wakeHour 0 / bedtimeHour 23: the phase assertions must not depend on the
# wall clock of the CI runner (a 05:55 UTC run used to sit in the night
# phase and fail "status missing: phase: working").
cat >"$SANDBOX/config.json" <<JSON
{"token":"$TOKEN","decidePort":$PORT,"wakeHour":0,"bedtimeHour":23}
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
    GRANNY_HOSTS_FILE="$SANDBOX/hosts" "$AGENT" "$@"
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

echo "e2e-agent OK ($CHECKS checks)"
