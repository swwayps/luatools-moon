#!/usr/bin/env bash
# Regression: Ryuu moved the public fixes catalogue from HTML data-* rows to
# /files/fixes.json. The refresh worker must accept and preserve that schema.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/fixes.json" <<'JSON'
[
  {
    "appid": "1547000",
    "name": "Grand Theft Auto: San Andreas – The Definitive Edition",
    "fixes": [
      {
        "href": "https://generator.ryuu.lol/fixes/GTA%20SA%20DE.zip",
        "filename": "GTA SA DE.zip",
        "size": "17.6 MB",
        "badges": ["Tested"]
      }
    ]
  },
  {
    "appid": "1546990",
    "name": "Grand Theft Auto: Vice City – The Definitive Edition",
    "fixes": [
      {
        "href": "https://generator.ryuu.lol/fixes/GTA%20VICE%20DE.zip",
        "filename": "GTA VICE DE.zip",
        "size": "17.6 MB",
        "badges": ["Tested"]
      }
    ]
  }
]
JSON

bash "$ROOT/plugin/backend/scripts/ryuu_index.sh" "$TMP/out.json" "$TMP/fixes.json"
jq -e '. | type == "array" and length == 2' "$TMP/out.json" >/dev/null
jq -e 'any(.[]; .appid == "1547000") and any(.[]; .appid == "1546990")' "$TMP/out.json" >/dev/null

echo "ok - current Ryuu JSON catalogue preserves GTA entries"
