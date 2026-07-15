#!/usr/bin/env bash
# Unit tests for per-component Stable/Beta artifact selection in install.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() {
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

{ [ "$SLS_BETA_PATH" = "dist/slsteam-moon-linux.zip" ] &&
  [ "$PLUGIN_BETA_PATH" = "dist/luatools-linux.zip" ] &&
  [ "$LUMEN_BETA_PATH" = "dist/lumen-linux.zip" ]; }
check "each component has a future-compatible beta artifact path" $?

MOCK_API_FAIL=0
MOCK_API_JSON='{"sha":"0123456789abcdef","size":4321,"download_url":"https://raw.example/lumen.zip"}'
API_URL_FILE="$(mktemp)"
trap 'rm -f "$API_URL_FILE"' EXIT
api_get() {
	printf '%s' "$1" >"$API_URL_FILE"
	[ "$MOCK_API_FAIL" = 1 ] && return 1
	printf '%s' "$MOCK_API_JSON"
}

info="$(beta_asset_info "swwayps/lumen" "dist/lumen-linux.zip")"; rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$(printf '%s' "$info" | jq -r '.tag')" = beta ] &&
  [ "$(printf '%s' "$info" | jq -r '.channel')" = beta ] &&
  [ "$(printf '%s' "$info" | jq -r '.id')" = 0123456789abcdef ] &&
  [ "$(printf '%s' "$info" | jq -r '.download_url')" = https://raw.example/lumen.zip ]; }
check "beta metadata becomes an installable fingerprint" $?
[ "$(cat "$API_URL_FILE")" = "https://api.github.com/repos/swwayps/lumen/contents/dist/lumen-linux.zip?ref=beta" ]
check "beta metadata uses the branch contents endpoint" $?

MOCK_API_JSON='{"message":"Not Found"}'
if beta_asset_info "swwayps/lumen" "dist/lumen-linux.zip" >/dev/null; then r=1; else r=0; fi
check "missing beta artifact is unavailable" "$r"

# Mock stable resolution so selection can be tested without network access.
latest_release_asset_url() { printf 'https://stable.example/component.zip'; }
any_release_asset_url() { printf 'https://stable.example/component-any.zip'; }
release_asset_info() { printf '{"tag":"v9","id":99,"size":9000}'; }
log_warn() { :; }

MOCK_API_JSON='{"sha":"beta-sha","size":123,"download_url":"https://beta.example/component.zip"}'
resolve_component_asset beta repo dist/component.zip '^component\\.zip$' latest; rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$RESOLVED_ASSET_URL" = https://beta.example/component.zip ] &&
  [ "$(printf '%s' "$RESOLVED_ASSET_INFO" | jq -r '.channel')" = beta ]; }
check "available beta is selected without resolving Stable" $?

MOCK_API_JSON='{"message":"Not Found"}'
resolve_component_asset beta repo dist/component.zip '^component\\.zip$' latest; rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$RESOLVED_ASSET_URL" = https://stable.example/component.zip ] &&
  [ "$(printf '%s' "$RESOLVED_ASSET_INFO" | jq -r '.channel')" = stable ]; }
check "missing beta falls back to Stable for that component" $?

MOCK_API_FAIL=0
MOCK_API_JSON='{"sha":"ignored-beta","size":123,"download_url":"https://beta.example/ignored.zip"}'
resolve_component_asset stable repo dist/component.zip '^component\\.zip$' any; rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$RESOLVED_ASSET_URL" = https://stable.example/component-any.zip ] &&
  [ "$(printf '%s' "$RESOLVED_ASSET_INFO" | jq -r '.channel')" = stable ]; }
check "Stable selection skips beta and supports any-release resolution" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
