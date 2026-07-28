#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for visible_surface in \
  "$ROOT/plugin/backend/api.defaults.json" \
  "$ROOT/plugin/backend/settings/options.lua" \
  "$ROOT/plugin/backend/locales" \
  "$ROOT/plugin/public/luatools.js"; do
  if grep -RniE "morrenus|mornus" "$visible_surface" >/dev/null; then
    echo "obsolete Morrenus name remains on a user-visible surface: $visible_surface" >&2
    exit 1
  fi
done

grep -qF '"name": "Sadie (Hubcap)"' "$ROOT/plugin/backend/api.defaults.json"
grep -qF 'key = "hubcapApiKey"' "$ROOT/plugin/backend/settings/options.lua"
grep -qF 'function manager.get_hubcap_api_key()' "$ROOT/plugin/backend/settings/manager.lua"
grep -qF 'function GetHubcapStats(' "$ROOT/plugin/backend/main.lua"
grep -qF 'lt("Needs key")' "$ROOT/plugin/public/luatools.js"
grep -qF 'data-api-locked' "$ROOT/plugin/public/luatools.js"
grep -qF 'fa-solid fa-lock' "$ROOT/plugin/public/luatools.js"
grep -qF 'item.getAttribute("data-api-locked") === "true"' "$ROOT/plugin/public/luatools.js"
grep -qF 'btn.setAttribute("aria-disabled", "true")' "$ROOT/plugin/public/luatools.js"

echo "ok - user-visible naming and missing-key state follow Sadie (Hubcap)"
