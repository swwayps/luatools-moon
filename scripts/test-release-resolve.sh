#!/usr/bin/env bash
# Unit test for install.sh's release-asset resolvers.
#
# Why this exists
# ---------------
# When Codeberg is slow/down, the API fetch fails and the resolver returns an
# empty URL — historically indistinguishable from "the release simply has no
# matching asset". The installer then told the user "could not find the release
# asset", which is misleading (the real problem is connectivity). The resolvers
# now signal a fetch/network failure with a distinct exit code (2) so callers
# can show the right message. This pins that contract.
#
# Run: bash scripts/test-release-resolve.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"; else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi; }

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

# Mock the network layer: api_get echoes $MOCK_JSON on success, or fails
# (simulating Codeberg unreachable) when $MOCK_FAIL=1.
MOCK_FAIL=0
MOCK_JSON=""
api_get() { [ "${MOCK_FAIL:-0}" = 1 ] && return 1; printf '%s' "$MOCK_JSON"; }

LATEST_JSON_MATCH='{"assets":[{"name":"luatools-linux.zip","browser_download_url":"https://cb/luatools-linux.zip"}]}'
LATEST_JSON_NOMATCH='{"assets":[{"name":"other.zip","browser_download_url":"https://cb/other.zip"}]}'
ANY_JSON_MATCH='[{"assets":[{"name":"slsteam-moon-linux-2.6-lumen.zip","browser_download_url":"https://cb/slsteam-moon-linux-2.6-lumen.zip"}]}]'
ANY_JSON_NOMATCH='[{"assets":[{"name":"slsteam-moon-linux-2.6.zip","browser_download_url":"https://cb/slsteam-moon-linux-2.6.zip"}]}]'

# --- latest_release_asset_url -----------------------------------------------

MOCK_FAIL=1
url="$(latest_release_asset_url repo '^luatools-linux\.zip$')"; rc=$?
{ [ "$rc" -eq 2 ] && [ -z "$url" ]; }; check "latest: fetch failure -> rc 2, empty url" $?

MOCK_FAIL=0; MOCK_JSON="$LATEST_JSON_MATCH"
url="$(latest_release_asset_url repo '^luatools-linux\.zip$')"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$url" = "https://cb/luatools-linux.zip" ]; }; check "latest: ok + match -> rc 0, url" $?

MOCK_FAIL=0; MOCK_JSON="$LATEST_JSON_NOMATCH"
url="$(latest_release_asset_url repo '^luatools-linux\.zip$')"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$url" ]; }; check "latest: ok + no match -> rc 0, empty url" $?

# --- any_release_asset_url --------------------------------------------------

MOCK_FAIL=1
url="$(any_release_asset_url repo '^slsteam-moon-linux-.*-lumen\.zip$')"; rc=$?
{ [ "$rc" -eq 2 ] && [ -z "$url" ]; }; check "any: fetch failure -> rc 2, empty url" $?

MOCK_FAIL=0; MOCK_JSON="$ANY_JSON_MATCH"
url="$(any_release_asset_url repo '^slsteam-moon-linux-.*-lumen\.zip$')"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$url" = "https://cb/slsteam-moon-linux-2.6-lumen.zip" ]; }; check "any: ok + match -> rc 0, url" $?

MOCK_FAIL=0; MOCK_JSON="$ANY_JSON_NOMATCH"
url="$(any_release_asset_url repo '^slsteam-moon-linux-.*-lumen\.zip$')"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$url" ]; }; check "any: ok + no match -> rc 0, empty url" $?

# --- stable GitHub -> jsDelivr mirror resolution ---------------------------

GH_LUMEN_MATCH='{"tag_name":"v2.9","assets":[{"id":29,"name":"lumen-linux.zip","created_at":"2026-09-02T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","size":290,"browser_download_url":"https://github.example/lumen-linux.zip"}]}'
GH_LUMEN_TEMP='{"tag_name":"v2.9","assets":[{"id":29,"name":"lumen-linux-uploading.zip.tmp","created_at":"2026-09-02T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","size":290,"browser_download_url":"https://github.example/temp.zip"}]}'
MIRROR_JSON='{"schema":1,"components":{"lumen":{"tag":"v2.8","id":28,"asset_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-01T00:00:00Z","size":280,"name":"lumen-linux.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://cdn.jsdelivr.net/gh/swwayps/jsdelivr@0123456789012345678901234567890123456789/releases/lumen/v2.8/hash/lumen-linux.zip"}}}'

MOCK_GITHUB_FAIL=0
MOCK_GITHUB_JSON="$GH_LUMEN_MATCH"
MOCK_MIRROR_FAIL=0
api_get() {
	case "$1" in
		*cdn.jsdelivr.net*)
			[ "$MOCK_MIRROR_FAIL" = 1 ] && return 1
			printf '%s' "$MIRROR_JSON"
			;;
		*)
			[ "$MOCK_GITHUB_FAIL" = 1 ] && return 1
			printf '%s' "$MOCK_GITHUB_JSON"
			;;
	esac
}

MOCK_GITHUB_FAIL=1
rc=0
resolve_component_asset stable swwayps/lumen dist/lumen-linux.zip \
	'^lumen-linux\.zip$' latest lumen || rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$RESOLVED_ASSET_URL" = "$(printf '%s' "$MIRROR_JSON" | jq -r '.components.lumen.url')" ] &&
  [ "$(printf '%s' "$RESOLVED_ASSET_INFO" | jq -r '.tag')" = v2.8 ]; }
check "stable: GitHub API failure -> mirror becomes primary" $?

MOCK_GITHUB_FAIL=0
MOCK_GITHUB_JSON="$GH_LUMEN_TEMP"
rc=0
resolve_component_asset stable swwayps/lumen dist/lumen-linux.zip \
	'^lumen-linux\.zip$' latest lumen || rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$RESOLVED_ASSET_URL" = "$(printf '%s' "$MIRROR_JSON" | jq -r '.components.lumen.url')" ]; }
check "stable: temporary release name is ignored -> last good mirror" $?

MOCK_GITHUB_JSON="$GH_LUMEN_MATCH"
rc=0
resolve_component_asset stable swwayps/lumen dist/lumen-linux.zip \
	'^lumen-linux\.zip$' latest lumen || rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$RESOLVED_ASSET_URL" = "https://github.example/lumen-linux.zip" ] &&
  [ "${RESOLVED_FALLBACK_URL:-}" = "$(printf '%s' "$MIRROR_JSON" | jq -r '.components.lumen.url')" ]; }
check "stable: GitHub primary keeps jsDelivr as download fallback" $?

# --- transfer failover -----------------------------------------------------

RESOLVED_ASSET_URL="https://github.example/lumen-linux.zip"
RESOLVED_ASSET_INFO='{"tag":"v2.9","id":29,"source":"github"}'
RESOLVED_FALLBACK_URL="https://cdn.jsdelivr.net/fallback/lumen-linux.zip"
RESOLVED_FALLBACK_INFO='{"tag":"v2.8","id":28,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"jsdelivr"}'
DOWNLOAD_ATTEMPTS=""
FALLBACK_EXPECTED=""
PRIMARY_RESULT=1
download_and_verify() {
	DOWNLOAD_ATTEMPTS="${DOWNLOAD_ATTEMPTS:+$DOWNLOAD_ATTEMPTS }$1"
	if [ "$1" = "$RESOLVED_ASSET_URL" ]; then return "$PRIMARY_RESULT"; fi
	FALLBACK_EXPECTED="${4:-}"
	return 0
}

rc=0
download_resolved_asset /tmp/unused.zip Lumen || rc=$?
{ [ "$rc" -eq 0 ] &&
  [ "$DOWNLOAD_ATTEMPTS" = "$RESOLVED_ASSET_URL $RESOLVED_FALLBACK_URL" ] &&
  [ "$FALLBACK_EXPECTED" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] &&
  [ "$(printf '%s' "$DOWNLOADED_ASSET_INFO" | jq -r '.source')" = jsdelivr ]; }
check "download: transport failure retries the resolved jsDelivr asset" $?

DOWNLOAD_ATTEMPTS=""
PRIMARY_RESULT=2
rc=0
download_resolved_asset /tmp/unused.zip Lumen || rc=$?
{ [ "$rc" -eq 2 ] && [ "$DOWNLOAD_ATTEMPTS" = "$RESOLVED_ASSET_URL" ]; }
check "download: integrity failure never falls through to another source" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
