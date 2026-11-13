#!/usr/bin/env bash
# End-to-end tests for the kernel <-> engine socket contract (<state dir>/engine.sock).
# Driven by a plain Node stub using only `node:net`: if the contract needs a
# Swift-shaped client, it is the wrong contract.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AGENT="$REPO/GrannyAgent/.build/debug/granny-agent"
(cd "$REPO/GrannyAgent" && swift build --product granny-agent >/dev/null)

SANDBOX="$(mktemp -d)"
SERVER_PID=""
ENGINE_PID=""
MOCK_HTTP_PID=""
cleanup() {
  if [ -n "$ENGINE_PID" ]; then kill -9 "$ENGINE_PID" 2>/dev/null || true; wait "$ENGINE_PID" 2>/dev/null || true; fi
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  if [ -n "$MOCK_HTTP_PID" ]; then kill "$MOCK_HTTP_PID" 2>/dev/null || true; wait "$MOCK_HTTP_PID" 2>/dev/null || true; fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT
CHECKS=0

fail() { echo "e2e-engine FAIL: $1" >&2; exit 1; }
contains() { case "$1" in *"$2"*) CHECKS=$((CHECKS + 1)) ;; *) fail "$3 missing: $2 (got: $1)" ;; esac; }

PORT=$((46000 + RANDOM % 1000))
TOKEN="e2e-engine-token"
SOCK="$SANDBOX/state/engine.sock"
mkdir -p "$SANDBOX/state"

write_config() { # write_config <quietStart> <quietEnd> <nudgesMax>
  cat >"$SANDBOX/config.json" <<JSON
{"token":"$TOKEN","decidePort":$PORT,"wakeHour":0,"bedtimeHour":24,"quietStart":$1,"quietEnd":$2,"nudgesPerDayMax":$3}
JSON
}

# Start with quiet hours disabled (0 == 0) and budget of 1 nudge.
write_config 0 0 1

cat >"$SANDBOX/state/state.json" <<JSON
{"date":"$(date +%Y-%m-%d)","dayOff":false,"greeted":true,"tasks":[],"pomodoro":{"stage":"deepWork","finished":0}}
JSON

# 40-line Node helper: sends newline-delimited JSON requests over engine.sock
# and prints each reply line.
cat >"$SANDBOX/rpc.mjs" <<'JS'
import net from "node:net";
const [sock, ...lines] = process.argv.slice(2);
const client = net.createConnection(sock);
let buf = "";
let idx = 0;
const sendNext = () => {
  if (idx < lines.length) client.write(lines[idx++] + "\n");
  else client.end();
};
client.on("connect", sendNext);
client.on("data", (chunk) => {
  buf += chunk.toString("utf8");
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    console.log(line);
    const msg = JSON.parse(line);
    if (!msg.event || msg.event === "chat.done" || msg.event === "chat.error" || msg.event === "model.done") sendNext();
  }
});
JS

GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
  "$AGENT" --serve >"$SANDBOX/serve.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 40); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
[ -S "$SOCK" ] || { cat "$SANDBOX/serve.log" >&2; fail "engine.sock did not appear"; }
CHECKS=$((CHECKS + 1))

sock_mode="$(stat -f '%Lp' "$SOCK")"
[ "$sock_mode" = "600" ] || fail "expected engine.sock mode 600, got $sock_mode"
CHECKS=$((CHECKS + 1))

# 6. Status and state.read work with the engine absent.
status_out="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/status")"
contains "$status_out" '"phase":"awaitingTasks"' "status without engine"

read_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"r-0","method":"state.read","params":{}}')"
contains "$read_out" '"phase":"awaitingTasks"' "state.read without engine"

# 1. Handshake with a wrong protocol fails loudly and the app keeps coaching.
bad_hello="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":2,"id":"e-bad","method":"hello","params":{"role":"engine","impl":"bad/2.0","capabilities":[]}}')"
contains "$bad_hello" '"code":"refused"' "wrong protocol refused"
status_after_bad="$(curl -s -H "X-Granny-Token: $TOKEN" "http://127.0.0.1:$PORT/status")"
contains "$status_after_bad" '"phase":"awaitingTasks"' "app still coaching after bad handshake"

# Mutations before hello are refused.
unhandshaked="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"e-nohello","key":"k-nohello","method":"state.task.add","params":{"title":"Sneak in"}}')"
contains "$unhandshaked" '"reason":"hello handshake required first"' "mutation without hello refused"

# 2. state.task.add twice with the same key adds one task; second returns duplicate + original result.
CASK_VER="$(sed -n 's/^  version "\([^"]*\)".*/\1/p' "$REPO/packaging/homebrew/Casks/granny.rb")"
HELLO='{"v":1,"id":"e-1","method":"hello","params":{"role":"engine","impl":"pi-durable/0.1.0","capabilities":["state.read","state.task.add","state.task.tick","notify.speak"]}}'
ADD='{"v":1,"id":"e-2","key":"k-same","method":"state.task.add","params":{"title":"Apply 5 jobs"}}'
ADD_DUP='{"v":1,"id":"e-3","key":"k-same","method":"state.task.add","params":{"title":"Apply 5 jobs"}}'
READ='{"v":1,"id":"e-4","method":"state.read","params":{}}'

out="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO" "$ADD" "$ADD_DUP" "$READ")"
contains "$out" "\"impl\":\"granny/$CASK_VER\"" "handshake reply"
contains "$out" '"code":"duplicate"' "second add with same key is duplicate"

task_id="$(printf '%s\n' "$out" | node -e 'const fs=require("fs");for(const l of fs.readFileSync(0,"utf8").trim().split("\n")){const m=JSON.parse(l);if(m.id==="e-2"&&m.result){console.log(m.result.taskID);}}')"
[ -n "$task_id" ] || fail "missing taskID from first add"
CHECKS=$((CHECKS + 1))

# Persisted state.json holds exactly one task.
task_count="$(node -e 'const fs=require("fs");console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).tasks.length)' "$SANDBOX/state/state.json")"
[ "$task_count" = "1" ] || fail "expected 1 task in state.json, got $task_count"
CHECKS=$((CHECKS + 1))

# 3. state.task.tick for the last task with rounds == 0 is refused.
TICK="{\"v\":1,\"id\":\"e-5\",\"key\":\"k-tick\",\"method\":\"state.task.tick\",\"params\":{\"taskID\":\"$task_id\",\"done\":true}}"
tick_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO" "$TICK")"
contains "$tick_out" '"code":"refused"' "unpaid last tick refused"
contains "$tick_out" 'finish one deep-work round first' "unpaid last tick reason"

# 4. notify.speak inside budget is delivered; over budget is refused; in quiet hours is refused.
SPEAK1='{"v":1,"id":"e-6","key":"k-sp1","method":"notify.speak","params":{"text":"Time to start","reason":"slot"}}'
SPEAK2='{"v":1,"id":"e-7","key":"k-sp2","method":"notify.speak","params":{"text":"Second nudge","reason":"slot"}}'
speak_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO" "$SPEAK1" "$SPEAK2")"
contains "$speak_out" '"delivered":true' "first speak delivered"
contains "$speak_out" '"reason":"nudge budget spent"' "second speak over budget refused"

# Flip quiet hours to cover all day (0 -> 23 and 23 -> 0 via current hour) and raise budget.
hour="$(date +%H | sed 's/^0*//')"
hour="${hour:-0}"
next_hour=$(( (hour + 1) % 24 ))
write_config "$hour" "$next_hour" 5
SPEAK_QUIET='{"v":1,"id":"e-8","key":"k-sp3","method":"notify.speak","params":{"text":"Wake up","reason":"slot"}}'
quiet_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO" "$SPEAK_QUIET")"
contains "$quiet_out" '"reason":"after quiet hours"' "speak during quiet hours refused"

# 5. chat.prompt streams deltas and ends with chat.done; killing the engine mid-stream leaves the day untouched.
cat >"$SANDBOX/engine-stub.mjs" <<'JS'
import fs from "node:fs";
import net from "node:net";
const [sock, mode, abortLog] = process.argv.slice(2);
const conn = net.createConnection(sock, () => {
  conn.write(JSON.stringify({
    v: 1, id: "h-1", method: "hello",
    params: { role: "engine", impl: "stub-engine/0.1.0", capabilities: ["state.read"] }
  }) + "\n");
});
let buf = "";
conn.on("data", (chunk) => {
  buf += chunk.toString("utf8");
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.method === "chat.abort" && abortLog) {
      fs.appendFileSync(abortLog, String(msg.params?.id ?? "") + "\n");
      return;
    }
    if (msg.method === "chat.prompt") {
      conn.write(JSON.stringify({ v: 1, id: msg.id, event: "chat.delta", params: { text: "which step " } }) + "\n");
      if (mode === "crash") {
        process.exit(1);
      }
      if (mode === "slow") {
        return;
      }
      conn.write(JSON.stringify({ v: 1, id: msg.id, event: "chat.done", params: { text: "which step is stuck?" } }) + "\n");
    }
  }
});
JS

node "$SANDBOX/engine-stub.mjs" "$SOCK" "ok" &
ENGINE_PID=$!
sleep 0.2

# A second engine hello while one is live is refused instead of stealing the slot.
second_hello="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO")"
contains "$second_hello" '"reason":"engine already connected"' "second hello refused while engine live"

stream_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-1","method":"chat.prompt","params":{"text":"stuck on booking","stream":true}}')"
contains "$stream_out" '"event":"chat.delta"' "chat.prompt streams delta"
contains "$stream_out" '"event":"chat.done"' "chat.prompt ends with chat.done"
kill "$ENGINE_PID" 2>/dev/null || true
wait "$ENGINE_PID" 2>/dev/null || true
ENGINE_PID=""

# Start stub in slow mode: chat.abort cancels the in-flight prompt.
node "$SANDBOX/engine-stub.mjs" "$SOCK" "slow" "$SANDBOX/abort.log" &
ENGINE_PID=$!
sleep 0.2

node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-slow","method":"chat.prompt","params":{"text":"long answer","stream":true}}' >"$SANDBOX/slow.out" &
SLOW_CLIENT_PID=$!
sleep 0.2

abort_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-abort","method":"chat.abort","params":{"id":"c-slow"}}')"
contains "$abort_out" '"aborted":true' "chat.abort ack"
wait "$SLOW_CLIENT_PID" 2>/dev/null || true
slow_stream="$(cat "$SANDBOX/slow.out")"
contains "$slow_stream" '"event":"chat.delta"' "slow prompt delivered delta before abort"
contains "$slow_stream" '"aborted":true' "slow prompt released on abort"
sleep 0.1
abort_logged="$(cat "$SANDBOX/abort.log" 2>/dev/null || true)"
contains "$abort_logged" "c-slow" "engine received forwarded chat.abort"

# Aborting an unknown run id answers aborted:false.
noop_abort="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-noop","method":"chat.abort","params":{"id":"c-missing"}}')"
contains "$noop_abort" '"aborted":false' "chat.abort on unknown id returns false"
kill "$ENGINE_PID" 2>/dev/null || true
wait "$ENGINE_PID" 2>/dev/null || true
ENGINE_PID=""

# Start stub in crash mode: exits mid-stream after first delta.
node "$SANDBOX/engine-stub.mjs" "$SOCK" "crash" &
ENGINE_PID=$!
sleep 0.2

crash_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-2","method":"chat.prompt","params":{"text":"stuck again","stream":true}}')"
contains "$crash_out" '"event":"chat.delta"' "crash run still delivered first delta"
contains "$crash_out" '"reason":"engine disconnected"' "crash mid-stream surfaces engine disconnected"
ENGINE_PID=""

# Day state is untouched after mid-stream engine crash.
task_count_after="$(node -e 'const fs=require("fs");console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).tasks.length)' "$SANDBOX/state/state.json")"
[ "$task_count_after" = "1" ] || fail "day state changed after engine crash: $task_count_after tasks"
CHECKS=$((CHECKS + 1))

# 7. GRANNY_ENGINE_PATH child supervision, day.woke push latch, and automatic restart after kill -9.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
rm -f "$SOCK"

cat >"$SANDBOX/state/state.json" <<JSON
{"date":"$(date +%Y-%m-%d)","dayOff":false,"greeted":false,"tasks":[],"carried":[{"id":"f-1","title":"Eat the frog","carriedOver":true,"done":false}],"pomodoro":{"stage":"deepWork","finished":0}}
JSON

cat >"$SANDBOX/spawned-engine" <<'SH'
#!/usr/bin/env node
import fs from "node:fs";
import net from "node:net";
const sock = process.env.GRANNY_ENGINE_SOCKET;
const pidFile = process.env.GRANNY_TEST_ENGINE_PID;
const eventsFile = process.env.GRANNY_TEST_ENGINE_EVENTS;
if (pidFile) fs.writeFileSync(pidFile, String(process.pid));
const conn = net.createConnection(sock, () => {
  conn.write(JSON.stringify({
    v: 1, id: "h-spawn", method: "hello",
    params: { role: "engine", impl: "pi-durable/0.1.0", capabilities: ["state.read"] }
  }) + "\n");
});
let buf = "";
conn.on("data", (chunk) => {
  buf += chunk.toString("utf8");
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.event && eventsFile) {
      fs.appendFileSync(eventsFile, line + "\n");
    }
    if (msg.method === "chat.prompt") {
      conn.write(JSON.stringify({ v: 1, id: msg.id, event: "chat.delta", params: { text: "spawned " } }) + "\n");
      conn.write(JSON.stringify({ v: 1, id: msg.id, event: "chat.done", params: { text: "spawned ok" } }) + "\n");
    }
  }
});
SH
chmod +x "$SANDBOX/spawned-engine"

GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
  GRANNY_ENGINE_PATH="$SANDBOX/spawned-engine" \
  GRANNY_TEST_ENGINE_PID="$SANDBOX/engine.pid" \
  GRANNY_TEST_ENGINE_EVENTS="$SANDBOX/events.jsonl" \
  "$AGENT" --serve >"$SANDBOX/serve2.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 40); do
  [ -f "$SANDBOX/engine.pid" ] && break
  sleep 0.1
done
[ -f "$SANDBOX/engine.pid" ] || fail "spawned engine did not write pid"
sleep 0.2

spawn_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-3","method":"chat.prompt","params":{"text":"hello","stream":true}}')"
contains "$spawn_out" '"text":"spawned ok"' "spawned engine answers chat.prompt"

# day.woke is pushed to the ready engine with carried frog count.
events_log="$(cat "$SANDBOX/events.jsonl" 2>/dev/null || true)"
contains "$events_log" '"event":"day.woke"' "day.woke pushed on handshake"
contains "$events_log" '"frogs":1' "day.woke carries frog count"

# A non-child process cannot claim the engine slot when GRANNY_ENGINE_PATH owns it.
impostor_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO")"
contains "$impostor_out" '"reason":"engine slot is owned by the spawned child"' "non-child hello refused"

first_pid="$(cat "$SANDBOX/engine.pid")"
rm -f "$SANDBOX/engine.pid"
kill -9 "$first_pid" 2>/dev/null || true

for _ in $(seq 1 40); do
  [ -f "$SANDBOX/engine.pid" ] && break
  sleep 0.1
done
[ -f "$SANDBOX/engine.pid" ] || fail "engine was not respawned after kill -9"
sleep 0.2

respawn_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-4","method":"chat.prompt","params":{"text":"hello again","stream":true}}')"
contains "$respawn_out" '"text":"spawned ok"' "respawned engine answers chat.prompt"

# day.woke latch prevents a second day.woke on the same day after respawn.
woke_count="$(grep -c '"event":"day.woke"' "$SANDBOX/events.jsonl")"
[ "$woke_count" = "1" ] || fail "expected exactly 1 day.woke push, got $woke_count"
CHECKS=$((CHECKS + 1))

# 8. Slice 3 capabilities: device.context, slot.move, round.start, trace.emit, and model.stream.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
rm -f "$SOCK"

cat >"$SANDBOX/mock-http.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [portFile, traceLog] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c.toString("utf8"); });
  req.on("end", () => {
    if (req.url === "/api/public/otel/v1/traces") {
      fs.appendFileSync(traceLog, body + "\n");
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("{}");
      return;
    }
    if (req.url === "/chat/completions") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
      res.write(": OPENROUTER PROCESSING\n\n");
      res.write('data: {"choices":[{"delta":{"content":"First "}}]}\n\n');
      setTimeout(() => {
        res.write('data: {"choices":[{"delta":{"content":"step.","tool_calls":[{"index":0,"id":"call_e2e","type":"function","function":{"name":"round_start","arguments":"{}"}}]}}],"usage":{"prompt_tokens":18,"completion_tokens":4}}\n\n');
        res.write("data: [DONE]\n\n");
        res.end();
      }, 25);
      return;
    }
    res.writeHead(404);
    res.end();
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
JS

node "$SANDBOX/mock-http.mjs" "$SANDBOX/mock.port" "$SANDBOX/traces.log" &
MOCK_HTTP_PID=$!
for _ in $(seq 1 30); do
  [ -f "$SANDBOX/mock.port" ] && break
  sleep 0.1
done
[ -f "$SANDBOX/mock.port" ] || fail "mock HTTP server failed to bind"
kill -0 "$MOCK_HTTP_PID" 2>/dev/null || fail "mock HTTP server died after startup"
MOCK_PORT="$(cat "$SANDBOX/mock.port")"
CHECKS=$((CHECKS + 1))

cat >"$SANDBOX/device.json" <<'JSON'
{"frontmostApp":{"name":"Xcode","bundleID":"com.apple.dt.Xcode"},"openTabs":[{"browser":"Safari","url":"https://swift.org","title":"Swift"}],"calendarEvents":[{"title":"1:1","startAt":"2026-11-10T10:00:00Z","endAt":"2026-11-10T10:30:00Z","allDay":false}]}
JSON

cat >"$SANDBOX/state/state.json" <<JSON
{"date":"$(date +%Y-%m-%d)","dayOff":false,"greeted":true,"tasks":[{"id":"t-s3","title":"Ship Slice 3","done":false}],"pomodoro":{"stage":"deepWork","finished":0}}
JSON

# First start without an OpenRouter key: model.stream answers unavailable, device.context answers snapshot.
write_config 0 0 3
GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
  GRANNY_OPENROUTER_URL="http://127.0.0.1:$MOCK_PORT/chat/completions" \
  GRANNY_DEVICE_CONTEXT="$SANDBOX/device.json" \
  "$AGENT" --serve >"$SANDBOX/serve3.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 40); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
[ -S "$SOCK" ] || { cat "$SANDBOX/serve3.log" >&2; fail "engine.sock did not appear in Slice 3 run"; }

DEV_REQ='{"v":1,"id":"dc-1","method":"device.context","params":{}}'
MS_NOKEY='{"v":1,"id":"ms-0","method":"model.stream","params":{"messages":[{"role":"user","content":"hi"}]}}'
s3_pre="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO" "$DEV_REQ" "$MS_NOKEY")"
contains "$s3_pre" '"bundleID":"com.apple.dt.Xcode"' "device.context returns frontmostApp"
contains "$s3_pre" '"url":"https://swift.org"' "device.context returns openTabs"
contains "$s3_pre" '"title":"1:1"' "device.context returns calendarEvents"
contains "$s3_pre" '"code":"unavailable"' "model.stream without key is unavailable"

# Configure OpenRouter key, timetable slot, and local Langfuse collector.
cat >"$SANDBOX/config.json" <<JSON
{"token":"$TOKEN","decidePort":$PORT,"openRouterKey":"sk-e2e","wakeHour":0,"bedtimeHour":24,"quietStart":0,"quietEnd":0,"nudgesPerDayMax":3,"schedule":[{"id":"morning","time":"09:00","label":"Deep work","tag":"deepWork"}],"langfuse":{"baseURL":"http://127.0.0.1:$MOCK_PORT","publicKey":"pk","secretKey":"sk"}}
JSON

SLOT_BAD='{"v":1,"id":"sm-bad","key":"k-sm-bad","method":"slot.move","params":{"taskID":"t-s3","slotID":"nope"}}'
SLOT_OK='{"v":1,"id":"sm-ok","key":"k-sm-ok","method":"slot.move","params":{"taskID":"t-s3","slotID":"morning"}}'
ROUND_1='{"v":1,"id":"rs-1","key":"k-rs-1","method":"round.start","params":{}}'
ROUND_DUP='{"v":1,"id":"rs-dup","key":"k-rs-1","method":"round.start","params":{}}'
ROUND_2='{"v":1,"id":"rs-2","key":"k-rs-2","method":"round.start","params":{}}'
TRACE_1='{"v":1,"id":"tr-1","method":"trace.emit","params":{"span":{"name":"e2e.span","traceName":"granny.e2e","input":{"step":"1"},"output":{"ok":"true"}}}}'
MODEL_1='{"v":1,"id":"ms-1","method":"model.stream","params":{"messages":[{"role":"user","content":"start round"}],"tools":[{"name":"round_start","description":"Start tomato"}]}}'

s3_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" "$HELLO" "$SLOT_BAD" "$SLOT_OK" "$ROUND_1" "$ROUND_DUP" "$ROUND_2" "$TRACE_1" "$MODEL_1")"
contains "$s3_out" '"reason":"unknown slot nope"' "slot.move refuses unknown slot"
contains "$s3_out" '"proposals":[{"slotID":"morning","taskID":"t-s3"}]' "slot.move updates task slot"
contains "$s3_out" '"stage":"deepWork"' "round.start starts deepWork"
contains "$s3_out" '"code":"duplicate"' "round.start duplicate key returns original result"
contains "$s3_out" '"reason":"round already running"' "round.start refuses second running round"
contains "$s3_out" '"id":"tr-1","result":{}' "trace.emit replies ok"
contains "$s3_out" '"event":"model.delta"' "model.stream emits model.delta"
contains "$s3_out" '"event":"model.done"' "model.stream emits model.done"
contains "$s3_out" '"text":"First step."' "model.done carries assembled text"
contains "$s3_out" '"name":"round_start"' "model.done carries assembled toolCalls"
contains "$s3_out" '"usage":{"in":18,"out":4}' "model.done carries token usage"

sleep 0.2
traces_captured="$(cat "$SANDBOX/traces.log" 2>/dev/null || true)"
contains "$traces_captured" "e2e.span" "trace.emit delivered OTLP span"
contains "$traces_captured" "model.stream" "model.stream delivered generation OTLP span"

# 9. Slice 4: Real Pi Durable sidecar (`engine/bin/granny-engine`) unit + live kernel E2E.
bash "$REPO/scripts/build-engine.sh" >/dev/null
(cd "$REPO/engine" && npm test >/dev/null)
CHECKS=$((CHECKS + 1))

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
kill "$MOCK_HTTP_PID" 2>/dev/null || true
wait "$MOCK_HTTP_PID" 2>/dev/null || true
MOCK_HTTP_PID=""
rm -f "$SOCK" "$SANDBOX/mock.port"

cat >"$SANDBOX/mock-durable-llm.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [portFile] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c.toString("utf8"); });
  req.on("end", () => {
    if (req.url !== "/chat/completions") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("{}");
      return;
    }
    const parsed = JSON.parse(body || "{}");
    const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
    const last = messages[messages.length - 1] || {};
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });

    if (last.role === "user" && String(last.content || "").includes("Hẹn nhắc")) {
      const argsStr = JSON.stringify({ kind: "crash.survive", fireAtMs: Date.now() + 2500, note: "Survive kill -9" });
      res.write("data: " + JSON.stringify({
        choices: [{ delta: { tool_calls: [{ index: 0, id: "call_s4_sched", type: "function", function: { name: "intent_schedule", arguments: argsStr } }] } }],
        usage: { prompt_tokens: 20, completion_tokens: 8 },
      }) + "\n\n");
      res.write("data: [DONE]\n\n");
      res.end();
      return;
    }
    if (last.role === "user" && String(last.content || "").includes("Read chapter 3")) {
      res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_s4_add","type":"function","function":{"name":"state_task_add","arguments":"{\\"title\\":\\"Read chapter 3\\"}"}}]}}],"usage":{"prompt_tokens":22,"completion_tokens":7}}\n\n');
      res.write("data: [DONE]\n\n");
      res.end();
      return;
    }
    if (last.role === "user" && String(last.content || "").includes("Scheduled intent fired")) {
      res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_s4_speak","type":"function","function":{"name":"notify_speak","arguments":"{\\"text\\":\\"Ngoại nhắc sau khi hồi sinh!\\",\\"reason\\":\\"followup\\"}"}}]}}],"usage":{"prompt_tokens":24,"completion_tokens":9}}\n\n');
      res.write("data: [DONE]\n\n");
      res.end();
      return;
    }
    res.write('data: {"choices":[{"delta":{"content":"Đã ghi "}}]}\n\n');
    res.write('data: {"choices":[{"delta":{"content":"vào sổ rồi cháu!"}}],"usage":{"prompt_tokens":35,"completion_tokens":8}}\n\n');
    res.write("data: [DONE]\n\n");
    res.end();
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
JS

node "$SANDBOX/mock-durable-llm.mjs" "$SANDBOX/mock.port" &
MOCK_HTTP_PID=$!
for _ in $(seq 1 30); do
  [ -f "$SANDBOX/mock.port" ] && break
  sleep 0.1
done
[ -f "$SANDBOX/mock.port" ] || fail "durable mock LLM server failed to bind"
kill -0 "$MOCK_HTTP_PID" 2>/dev/null || fail "durable mock LLM server died"
MOCK_PORT="$(cat "$SANDBOX/mock.port")"

cat >"$SANDBOX/config.json" <<JSON
{"token":"$TOKEN","decidePort":$PORT,"openRouterKey":"sk-e2e-durable","wakeHour":0,"bedtimeHour":24,"quietStart":0,"quietEnd":0,"nudgesPerDayMax":3}
JSON

cat >"$SANDBOX/state/state.json" <<JSON
{"date":"$(date +%Y-%m-%d)","dayOff":false,"greeted":true,"tasks":[],"pomodoro":{"stage":"deepWork","finished":0}}
JSON

# Exercise the bundled Resources/engine/{granny-engine,granny-engine.mjs} layout via GRANNY_ENGINE_RESOURCES_DIR.
mkdir -p "$SANDBOX/Resources/engine"
cp "$REPO/engine/bin/granny-engine" "$REPO/engine/build/granny-engine.mjs" "$SANDBOX/Resources/engine/"
chmod +x "$SANDBOX/Resources/engine/granny-engine"

rm -f "$SANDBOX/durable.pid"
GRANNY_CONFIG_FILE="$SANDBOX/config.json" GRANNY_STATE_DIR="$SANDBOX/state" \
  GRANNY_ENGINE_RESOURCES_DIR="$SANDBOX/Resources" \
  GRANNY_OPENROUTER_URL="http://127.0.0.1:$MOCK_PORT/chat/completions" \
  GRANNY_DEVICE_CONTEXT="$SANDBOX/device.json" \
  GRANNY_TEST_ENGINE_PID="$SANDBOX/durable.pid" \
  "$AGENT" --serve >"$SANDBOX/serve4.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 60); do
  [ -f "$SANDBOX/durable.pid" ] && break
  sleep 0.1
done
[ -f "$SANDBOX/durable.pid" ] || { cat "$SANDBOX/serve4.log" "$SANDBOX/state/engine.log" 2>/dev/null >&2; fail "Pi Durable granny-engine did not start"; }
CHECKS=$((CHECKS + 1))

[ -f "$SANDBOX/state/engine/durable.sqlite" ] || fail "durable.sqlite was not created"
CHECKS=$((CHECKS + 1))

durable_chat="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-durable-1","method":"chat.prompt","params":{"text":"Thêm việc Read chapter 3","stream":true}}')"
contains "$durable_chat" '"event":"chat.delta"' "Pi Durable streams chat.delta"
contains "$durable_chat" '"text":"Đã ghi vào sổ rồi cháu!"' "Pi Durable completes tool loop + chat.done"

state_titles="$(node -e 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(s.tasks.map(t=>t.title).join(","))' "$SANDBOX/state/state.json")"
contains "$state_titles" "Read chapter 3" "Pi Durable tool call persisted task via EngineKernel"

# Schedule a sleeping intent via tool call, then kill -9 BEFORE it fires, and verify recovery!
cat >"$SANDBOX/schedule-via-prompt.mjs" <<'JS'
import fs from "node:fs";
const stateFile = process.argv[2];
console.log(JSON.parse(fs.readFileSync(stateFile, "utf8")).nudgesSent || 0);
JS
nudges_before="$(node "$SANDBOX/schedule-via-prompt.mjs" "$SANDBOX/state/state.json")"
[ "$nudges_before" = "0" ] || fail "expected 0 nudgesSent before crash test"

sched_out="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-durable-sched","method":"chat.prompt","params":{"text":"Hẹn nhắc cháu","stream":true}}')"
contains "$sched_out" '"event":"chat.done"' "Scheduled sleeping intent before kill -9"

# Kill -9 the Pi Durable process BEFORE the +2500ms intent fires, and verify respawn + intent recovery!
nudges_pre_kill="$(node "$SANDBOX/schedule-via-prompt.mjs" "$SANDBOX/state/state.json")"
[ "$nudges_pre_kill" = "0" ] || fail "intent fired before kill -9; widen fireAtMs in mock-durable-llm.mjs"
CHECKS=$((CHECKS + 1))
durable_first_pid="$(cat "$SANDBOX/durable.pid")"
rm -f "$SANDBOX/durable.pid"
kill -9 "$durable_first_pid" 2>/dev/null || true

for _ in $(seq 1 60); do
  [ -f "$SANDBOX/durable.pid" ] && break
  sleep 0.1
done
[ -f "$SANDBOX/durable.pid" ] || fail "Pi Durable granny-engine was not respawned after kill -9"
CHECKS=$((CHECKS + 1))

durable_after_crash="$(node "$SANDBOX/rpc.mjs" "$SOCK" \
  '{"v":1,"id":"c-durable-2","method":"chat.prompt","params":{"text":"Cảm ơn Ngoại","stream":true}}')"
contains "$durable_after_crash" '"text":"Đã ghi vào sổ rồi cháu!"' "Respawned Pi Durable answers chat.prompt"

# Wait for the sleeping intent from before kill -9 to fire on the respawned engine and call notify.speak!
nudges_after="0"
for _ in $(seq 1 60); do
  nudges_after="$(node "$SANDBOX/schedule-via-prompt.mjs" "$SANDBOX/state/state.json")"
  [ "$nudges_after" = "1" ] && break
  sleep 0.1
done
[ "$nudges_after" = "1" ] || { cat "$SANDBOX/serve4.log" "$SANDBOX/state/engine.log" 2>/dev/null >&2; fail "expected sleeping intent to survive kill -9 and increment nudgesSent to 1, got $nudges_after"; }
CHECKS=$((CHECKS + 1))

echo "e2e-engine OK ($CHECKS checks)"
