#!/usr/bin/env bash
# E2E on real Safari via safaridriver (built into macOS; no Chrome needed).
#
# One-time enable (either):
#   safaridriver --enable          # asks for your login password
#   Safari > Settings > Advanced > "Show features for web developers",
#   then Develop menu > Allow Remote Automation
#
# Checks, in order:
#   - control: example.com loads (Safari automation works at all)
#   - enforcement: facebook.com must NOT load (hosts block + relay ingress)
#   - info: youtube.com/shorts reachability (blocked only once the Safari
#     extension is enabled; not a failure of this suite)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PORT="${GRANNY_SAFARIDRIVER_PORT:-4445}"
SANDBOX="$(mktemp -d)"
DRIVER_PID=""

cleanup() {
  if [ -n "$DRIVER_PID" ]; then kill "$DRIVER_PID" 2>/dev/null || true; fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

fail() { echo "e2e-safari-webdriver FAIL: $1" >&2; exit 1; }

safaridriver -p "$PORT" >"$SANDBOX/driver.log" 2>&1 &
DRIVER_PID=$!

ready=0
for _ in $(seq 1 40); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/status" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" = "1" ] || fail "safaridriver did not start (log: $(cat "$SANDBOX/driver.log"))"

cat >"$SANDBOX/driver_client.py" <<'PY'
import json
import sys
import urllib.error
import urllib.request

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"


def call(method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        return json.loads(error.read())


response = call("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}})
session = (response.get("value") or {}).get("sessionId")
if not session:
    print("CHECK enable=needed")
    print("driver said:", json.dumps(response)[:300])
    sys.exit(2)

call("POST", f"/session/{session}/timeouts", {"pageLoad": 15000, "script": 10000})


def navigate(url):
    return call("POST", f"/session/{session}/url", {"url": url}, timeout=40)


def title():
    return call("GET", f"/session/{session}/title").get("value", "") or ""


def body_text():
    result = call("POST", f"/session/{session}/execute/sync",
                  {"script": "return document.body ? document.body.innerText.slice(0,300) : ''", "args": []})
    return result.get("value", "") or ""


def connection_error(text):
    lowered = text.lower()
    markers = ["can't connect", "cannot connect", "can't open the page",
               "not connect to the server", "không thể kết nối", "không mở được"]
    return any(marker in lowered for marker in markers)


navigate("https://example.com")
example_title = title()
print("CHECK example=" + ("ok" if "example" in example_title.lower() else "fail"))


def probe(url, label):
    navigate(url)
    blob = title() + " " + body_text()
    if connection_error(blob):
        print(f"CHECK {label}=blocked")
        return "blocked"
    if "facebook" in blob.lower() or "youtube" in blob.lower():
        print(f"CHECK {label}=loaded")
        return "loaded"
    print(f"CHECK {label}=unknown")
    return "unknown"


def clear_offline_caches():
    call("POST", f"/session/{session}/execute/async", {
        "script": """
            const done = arguments[arguments.length - 1];
            (async () => {
                const keys = await caches.keys();
                await Promise.all(keys.map((key) => caches.delete(key)));
                const regs = await navigator.serviceWorker.getRegistrations();
                await Promise.all(regs.map((reg) => reg.unregister()));
                done('cleared ' + keys.length);
            })().catch((error) => done('error: ' + error));
        """,
        "args": [],
    })


facebook_state = probe("https://www.facebook.com", "facebook")
if facebook_state == "loaded":
    # A page that loads with the network blocked is being served from
    # Safari's offline caches. Bust them and reload: if it now fails, the
    # cache was the culprit (clear Website Data for facebook/instagram).
    clear_offline_caches()
    probe("https://www.facebook.com", "facebook_after_clearing")

probe("https://www.youtube.com/shorts/test", "shorts")

call("DELETE", f"/session/{session}")
PY

output="$(python3 "$SANDBOX/driver_client.py" "$PORT")" || true

echo "$output"

case "$output" in
  *"CHECK enable=needed"*)
    echo "enable Safari automation first (one time, asks your password):" >&2
    echo "    safaridriver --enable" >&2
    echo "  or: Safari > Settings > Advanced > Show features for web developers," >&2
    echo "      then Develop menu > Allow Remote Automation" >&2
    exit 2
    ;;
esac

case "$output" in
  *"CHECK example=fail"*) fail "Safari automation could not load example.com" ;;
esac

case "$output" in
  *"CHECK facebook=loaded"*)
    case "$output" in
      *"CHECK facebook_after_clearing=blocked"*)
        fail "facebook is served from Safari's offline cache - clear it: Safari > Settings > Privacy > Manage Website Data > remove facebook.com and instagram.com"
        ;;
      *)
        fail "facebook loads with the network blocked - a real bypass, investigate"
        ;;
    esac
    ;;
  *"CHECK facebook=blocked"*)
    echo "facebook: blocked by the network layer ✓"
    ;;
  *)
    fail "facebook state unclear"
    ;;
esac

case "$output" in
  *"CHECK shorts=reachable"*)
    echo "note: youtube shorts reachable - the Safari extension (rules tier) is not enabled yet"
    ;;
esac

echo "e2e-safari-webdriver OK"
