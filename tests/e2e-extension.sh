#!/usr/bin/env bash
# End-to-end checks for the browser extension: JS syntax, manifests,
# wiring greps, and the Chrome packaging pipeline.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
CHECKS=0

fail() { echo "e2e-extension FAIL: $1" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" 2>/dev/null || fail "$1 missing: $2"; CHECKS=$((CHECKS + 1)); }

command -v node >/dev/null 2>&1 || fail "node is required for JS syntax checks"

for js in extension/shared/background.js extension/shared/intercept.js extension/shared/options.js; do
  node --check "$js" || fail "JS syntax error in $js"
  CHECKS=$((CHECKS + 1))
done

for manifest in extension/chrome/manifest.json extension/safari/manifest.json; do
  python3 -m json.tool "$manifest" >/dev/null || fail "invalid JSON: $manifest"
  CHECKS=$((CHECKS + 1))
  has "$manifest" '"content_scripts"'
  has "$manifest" '"theme.js"'
  has "$manifest" '"http://127.0.0.1/*"'
  has "$manifest" '"service_worker"'
done

has extension/shared/background.js 'X-Granny-Token'
has extension/shared/background.js 'HARD_BLOCKED'
has extension/shared/background.js 'force'

# The fallback hard list must stay in step with the Swift defaults, or the
# two ends block different sites when the daemon is down.
python3 - <<'PY' || fail "HARD_BLOCKED drifted from Config.defaultBlockedDomains"
import re, sys, pathlib
js = pathlib.Path("extension/shared/background.js").read_text()
match = re.search(r"HARD_BLOCKED = \[([^\]]*)\]", js)
assert match, "HARD_BLOCKED literal not found"
domains = re.findall(r"'([^']+)'", match.group(1))
swift = pathlib.Path("GrannyAgent/Sources/GrannyCore/Config.swift").read_text()
defaults = re.search(r"defaultBlockedDomains = \[(.*?)\]", swift, re.S).group(1)
swift_domains = set(re.findall(r'"([^"]+)"', defaults))
missing = [d for d in domains if d not in swift_domains]
if missing:
    print(f"HARD_BLOCKED entries not in Config.defaultBlockedDomains: {missing}", file=sys.stderr)
    sys.exit(1)
PY
CHECKS=$((CHECKS + 1))

# Port and version literals must agree across the Swift app, the extension
# and the packaging scripts: a drift here is silent until a release.
python3 - <<'PY' || fail "decide port literals drifted"
import re, sys, pathlib
swift = pathlib.Path("GrannyAgent/Sources/GrannyCore/Config.swift").read_text()
port = re.search(r"defaultDecidePort = (\d+)", swift).group(1)
files = [
    "extension/shared/background.js",
    "extension/shared/options.js",
    "extension/shared/options.html",
    "scripts/install-extension.sh",
    "scripts/sync-env.sh",
]
bad = []
for name in files:
    text = pathlib.Path(name).read_text()
    for literal in re.findall(r"\b\d{5}\b", text):
        if literal != port:
            bad.append(f"{name}: {literal} != {port}")
if bad:
    print("decide port drift: " + "; ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
CHECKS=$((CHECKS + 1))

python3 - <<'PY' || fail "version literals drifted"
import re, sys, pathlib
def version_of(path, pattern):
    match = re.search(pattern, pathlib.Path(path).read_text())
    return match.group(1) if match else None
versions = {
    "scripts/build-app.sh": version_of("scripts/build-app.sh", r'VERSION="\$\{GRANNY_VERSION:-([^}]+)\}"'),
    "scripts/build-release.sh": version_of("scripts/build-release.sh", r'VERSION="\$\{GRANNY_VERSION:-([^}]+)\}"'),
    "packaging/homebrew/Casks/granny.rb": version_of("packaging/homebrew/Casks/granny.rb", r'version "([^"]+)"'),
    "extension/chrome/manifest.json": version_of("extension/chrome/manifest.json", r'"version": "([^"]+)"'),
    "extension/safari/manifest.json": version_of("extension/safari/manifest.json", r'"version": "([^"]+)"'),
}
distinct = set(v for v in versions.values() if v)
if len(distinct) != 1:
    print("version drift: " + ", ".join(f"{k}={v}" for k, v in versions.items()), file=sys.stderr)
    sys.exit(1)
PY
CHECKS=$((CHECKS + 1))
has extension/shared/background.js '/hello'
has extension/shared/background.js 'pair('
has extension/shared/intercept.js 'granny-check'
has extension/shared/intercept.js 'granny-close-tab'
has extension/shared/intercept.js 'watchLocation'
has extension/shared/intercept.js 'granny-allow:'
has extension/shared/intercept.js 'need-context'
has extension/shared/background.js 'granny-close-tab'
has extension/shared/intercept.js 'waitForTitle'
has extension/shared/intercept.js 'channel'
has extension/shared/intercept.js 'purgeOfflineData'
has extension/shared/intercept.js 'caches.delete'
has extension/shared/intercept.js 'unregister'
has extension/shared/intercept.js 'granny-mute:'
has extension/shared/intercept.js 'isMuted'
has extension/shared/intercept.js 'muteDomain'
has extension/shared/intercept.js 'storage.local'
has extension/shared/theme.js 'GRANNY_THEME'
has extension/shared/intercept.js 'GRANNY_THEME'
has extension/shared/options.html 'options.js'

bash scripts/package-chrome.sh >/dev/null
[ -f dist/granny-chrome.zip ] || fail "chrome zip not produced"
CHECKS=$((CHECKS + 1))
listing="$(unzip -l dist/granny-chrome.zip)"
case "$listing" in
  *granny-chrome/manifest.json*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "zip missing manifest" ;;
esac
case "$listing" in
  *granny-chrome/intercept.js*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "zip missing intercept.js" ;;
esac
case "$listing" in
  *granny-chrome/theme.js*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "zip missing theme.js" ;;
esac
case "$listing" in
  *granny-chrome/icons/icon-128.png*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "zip missing the extension icon" ;;
esac

installer_output="$(GRANNY_DRY_RUN=1 bash scripts/install-extension.sh)"
case "$installer_output" in
  *"browsers found:"*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "install-extension dry-run did not detect browsers" ;;
esac
case "$installer_output" in
  *"token:"*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "install-extension dry-run did not print options" ;;
esac

install_all_output="$(bash scripts/install.sh --dry-run)"
case "$install_all_output" in
  *"== 1/4 build the app"*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "install.sh dry-run missing build step" ;;
esac
case "$install_all_output" in
  *"consent toggles remain"*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "install.sh dry-run missing consent note" ;;
esac

echo "e2e-extension OK ($CHECKS checks)"
