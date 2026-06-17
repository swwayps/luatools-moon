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

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
