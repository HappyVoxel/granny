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


def new_session():
    global session
    response = call("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}})
    session = (response.get("value") or {}).get("sessionId")
    if not session:
        print("CHECK enable=needed")
        print("driver said:", json.dumps(response)[:300])
        sys.exit(2)
    call("POST", f"/session/{session}/timeouts", {"pageLoad": 15000, "script": 10000})


session = None
new_session()


def navigate(url):
    return call("POST", f"/session/{session}/url", {"url": url}, timeout=40)


def ensure_window():
    """granny's own janitor closes blocked tabs out from under the driver;
    give the session a fresh window before probing again."""
    handles = call("GET", f"/session/{session}/window/handles").get("value")
    if handles:
        return
    result = call("POST", f"/session/{session}/window/new", {"type": "tab"})
    value = result.get("value")
    if isinstance(value, dict) and value.get("handle"):
        return
    new_session()


def snapshot():
    result = call("POST", f"/session/{session}/execute/sync", {
        "script": "return JSON.stringify({title: document.title || '', text: document.body ? document.body.innerText.slice(0, 300) : ''})",
        "args": [],
    })
    value = result.get("value")
    if not isinstance(value, str):
        return None
    try:
        return json.loads(value)
    except ValueError:
        return None


def connection_error(text):
    lowered = text.lower()
    markers = ["can't connect", "cannot connect", "can't open the page",
               "not connect to the server", "không thể kết nối", "không mở được"]
    return any(marker in lowered for marker in markers)


def probe(url, label, marker):
    """blocked / loaded / closed / unknown. 'closed' means the granny janitor
    closed the tab before it could be read - enforcement, not a bypass."""
    for _ in range(3):
        ensure_window()
        navigate(url)
        snap = snapshot()
        if snap is None:
            if not call("GET", f"/session/{session}/window/handles").get("value"):
                print(f"CHECK {label}=closed")
                return "closed"
            continue
        blob = (snap.get("title", "") + " " + snap.get("text", ""))
        if connection_error(blob):
            print(f"CHECK {label}=blocked")
            return "blocked"
        if marker in blob.lower():
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


ensure_window()
navigate("https://example.com")
example_snap = snapshot() or {}
print("CHECK example=" + ("ok" if "example" in example_snap.get("title", "").lower() else "fail"))


facebook_state = probe("https://www.facebook.com", "facebook", "facebook")
if facebook_state == "loaded":
    # A page that loads with the network blocked is being served from
    # Safari's offline caches. Bust them and reload: if it now fails, the
    # cache was the culprit (clear Website Data for facebook/instagram).
    clear_offline_caches()
    probe("https://www.facebook.com", "facebook_after_clearing", "facebook")

# A DoH endpoint carries AAAA records and the janitor never touches it:
# the cleanest network-layer probe (an IPv4-only hosts block fails here).
probe("https://dns.google", "doh", "google")

probe("https://www.youtube.com/shorts/test", "shorts", "youtube")

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
  *"CHECK doh=loaded"*)
    fail "a DoH endpoint loads - the network layer is bypassed (IPv6? Private Relay?)"
    ;;
  *"CHECK doh=blocked"*)
    echo "DoH endpoints: blocked by the network layer ✓"
    ;;
  *)
    fail "DoH endpoint state unclear"
    ;;
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
  *"CHECK facebook=closed"*)
    echo "facebook: closed by the granny janitor before it could load ✓"
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
