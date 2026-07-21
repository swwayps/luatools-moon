#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_FILE="$ROOT/plugin/backend/api.defaults.json"

python3 - "$API_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    entries = json.load(source)["api_list"]

expected = [
    ("hubcap", "Sadie (Hubcap)", "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>"),
    ("ryuu", "Ryuu", "http://167.235.229.108/<appid>"),
    ("sushi", "Sushi", "https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/<appid>.zip"),
]
actual = [(entry.get("builtin_id"), entry["name"], entry["url"]) for entry in entries]
if actual != expected:
    raise SystemExit(f"default APIs differ: expected {expected}, got {actual}")
if any("twentytwocloud.com" in entry["url"].lower() for entry in entries):
    raise SystemExit("removed TwentyTwo Cloud endpoint returned to the defaults")
if any("skyflarefox" in entry["url"].lower() for entry in entries):
    raise SystemExit("SkyAPI is live but must not be a default source")
if any(entry.get("success_code") != 200 or entry.get("unavailable_code") != 404
       or entry.get("enabled") is not True for entry in entries):
    raise SystemExit("default API status codes or enabled flags changed")
PY

echo "ok - default APIs contain only currently supported sources"
