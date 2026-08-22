#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/plugin/backend/main.lua"
BOOT="$ROOT/../lumen/lua/boot.lua"

fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    fail=$((fail + 1))
  fi
}

for endpoint in \
  GetLuaToolsAuthStatus LoginLuaToolsWithCode StartLuaToolsDiscordLogin \
  PollLuaToolsDiscordLogin CancelLuaToolsDiscordLogin LogoutLuaTools GetLuaToolsFixesCatalogue \
  GetLuaToolsFixesForGame AdoptLuaToolsSessionValue StartLuaToolsFix \
  CompleteLuaToolsFixApply StartAddViaLuaToolsSource GetLuaToolsAddRecommendation \
  StartLuaToolsRecommendedAdd; do
  check "RPC exports $endpoint" grep -qF "function $endpoint(" "$MAIN"
  check "Lumen allowlists $endpoint" grep -qF "\"$endpoint\"" "$BOOT"
done

check "backend loads the dedicated lua.tools auth service" \
  grep -qF 'require("lua_tools_auth")' "$MAIN"
check "backend loads the official lua.tools fixes service" \
  grep -qF 'require("lua_tools_fixes")' "$MAIN"
check "backend loads the shared lua.tools fix receipt service" \
  grep -qF 'require("lua_tools_fix_state")' "$MAIN"
check "backend loads the local lua.tools fix index" \
  grep -qF 'require("lua_tools_fix_index")' "$MAIN"
check "backend loads the recommended Add and auto-fix services" \
  grep -qF 'require("lua_tools_recommended_add")' "$MAIN" \
  && grep -qF 'require("lua_tools_auto_fix")' "$MAIN"
check "CheckForFixes exposes the persisted fallback receipt" \
  grep -qF 'fallbackOnlineApplied = applied_sources.fallbackOnline' "$MAIN"
check "CheckForFixes derives Spacewar from FakeAppIds" \
  grep -qF 'sls.get_fake_appid(appid) == 480' "$MAIN"
check "fallback downloads begin a durable receipt transaction" \
  grep -qF 'lua_tools_fix_state.begin_fallback_online(appid)' "$MAIN"
check "Ryuu catalogue is no longer used by CheckForFixes" \
  bash -c '! sed -n '\''600,740p'\'' "$1" | grep -qF '\''require("crackfix")'\''' _ "$MAIN"

exit "$fail"
