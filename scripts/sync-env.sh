#!/usr/bin/env bash
# Syncs API keys from .env into ~/.config/granny/config.json.
# .env is the developer convenience file; config.json (mode 600) is what the
# app reads and what the Settings window edits. Prints masked values only.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "no .env in $(pwd)" >&2; exit 1; }

python3 - <<'PY'
import json, os, pathlib

def parse_env(path):
    env = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env

env = parse_env(".env")
cfg_path = pathlib.Path.home() / ".config/granny/config.json"
if cfg_path.exists():
    cfg = json.loads(cfg_path.read_text())
else:
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg = {"token": __import__("uuid").uuid4().hex, "decidePort": 47899}

changed = []

openrouter = env.get("OPENROUTER_API_KEY", "")
if openrouter:
    cfg["openRouterKey"] = openrouter
    changed.append("openRouterKey ..." + openrouter[-4:])

base = env.get("LANGFUSE_BASE_URL", "").strip()
public = env.get("LANGFUSE_PUBLIC_KEY", "")
secret = env.get("LANGFUSE_SECRET_KEY", "")
if public and secret:
    cfg["langfuse"] = {
        "baseURL": base or "https://cloud.langfuse.com",
        "publicKey": public,
        "secretKey": secret,
    }
    changed.append("langfuse " + cfg["langfuse"]["baseURL"] + " pk ..." + public[-4:])

laya_url = env.get("LAYA_URL", "")
laya_key = env.get("LAYA_API_KEY", "")
if laya_url and laya_key:
    cfg["layaURL"] = laya_url
    cfg["layaKey"] = laya_key
    changed.append("laya " + laya_url)

jev_url = env.get("JEV_URL", "")
jev_key = env.get("JEV_KEY", "")
if jev_url and jev_key:
    cfg["jevURL"] = jev_url
    cfg["jevKey"] = jev_key
    changed.append("jev " + jev_url)

cfg_path.write_text(json.dumps(cfg, indent=2, sort_keys=True) + "\n")
os.chmod(cfg_path, 0o600)
print("synced:", ", ".join(changed) if changed else "nothing (empty .env values)")
PY
