#!/usr/bin/env bash
# Unit test for diagnose.sh's scrub() privacy filter.
#
# Why this exists
# ---------------
# diagnose.sh uploads collected logs to a PUBLIC paste. Before upload it must
# strip person-identifying data while KEEPING the technically useful, non-PII
# fields (appids, depot ids, manifest gids, build ids, hashes, timestamps) so
# the logs stay diagnosable. This pins scrub() against real log lines taken
# from actual SLSsteam / content_log / reconcile traces:
#   - MUST mask: home/username, Steam account id (userdata/<id>), SteamID64,
#     email, IPv4, Steam CM region (geolocation).
#   - MUST keep: appid, depot id, manifest gid, build id, steamclient hash,
#     shader-cache hash, timestamps.
#
# scrub() reads stdin, writes scrubbed stdout. The running user's name/home are
# taken from SCRUB_USER / SCRUB_HOME so the test can inject a fixed fixture
# identity ("peeblyweeb") regardless of who runs the test.
#
# Run: bash scripts/test-diagnose-scrub.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGNOSE_SH="$SCRIPT_DIR/../diagnose.sh"

export DIAGNOSE_LIB_ONLY=1
export SCRUB_USER="peeblyweeb"
export SCRUB_HOME="/home/peeblyweeb"

# shellcheck disable=SC1090
source "$DIAGNOSE_SH" >/dev/null 2>&1 || true

failures=0
check() { # $1 desc  $2 result(0/1)
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

# scrubbed "<input>" -> echoes the scrubbed output (empty if scrub undefined).
scrubbed() { printf '%s' "$1" | scrub 2>/dev/null; }

# masks: assert the scrubbed output CONTAINS $2 and does NOT contain $3.
masks() { # $1 desc  $2 input  $3 must-contain  $4 must-NOT-contain
	local out; out="$(scrubbed "$2")"
	if printf '%s' "$out" | grep -qF "$3" && ! printf '%s' "$out" | grep -qF "$4"; then
		check "$1" 0
	else
		check "$1 (got: $out)" 1
	fi
}

# keeps: assert the scrubbed output still CONTAINS $2 verbatim.
keeps() { # $1 desc  $2 input  $3 must-still-contain
	local out; out="$(scrubbed "$2")"
	if printf '%s' "$out" | grep -qF "$3"; then check "$1" 0
	else check "$1 (got: $out)" 1; fi
}

echo "── MUST mask (person-identifying) ──"

masks "home path -> /home/USER" \
	'[Debug] Added /home/peeblyweeb/.config/SLSsteam/config.yaml to FileWatcher 6' \
	'/home/USER/.config/SLSsteam' '/home/peeblyweeb'

masks "other user's home -> /home/USER" \
	'log-file=/home/arthur/.local/share/Steam/logs/cef_log.txt' \
	'/home/USER/.local/share/Steam' '/home/arthur'

masks "bare username token -> USER" \
	'persona for peeblyweeb loaded' \
	'USER' 'peeblyweeb'

masks "Steam account id (userdata/<id>) -> ACCOUNTID" \
	'removing shader hit cache: /home/peeblyweeb/.steam/steam/userdata/488150314/config/x' \
	'userdata/ACCOUNTID' '488150314'

masks "CloudRedirect storage/<id> -> ACCOUNTID" \
	'storage path: /home/peeblyweeb/.config/CloudRedirect/storage/488150314/2057760' \
	'storage/ACCOUNTID' '/storage/488150314'

masks "accountId key value -> ACCOUNTID" \
	'[Backend] m_accountId = 488150314' \
	'ACCOUNTID' '488150314'

masks "SteamID64 -> STEAMID" \
	'logged on as 76561198448416042 ok' \
	'STEAMID' '76561198448416042'

masks "email -> EMAIL" \
	'FakeEmail: someguy.123@gmail.com' \
	'EMAIL' 'someguy.123@gmail.com'

masks "IPv4 -> IP" \
	'connected to 81.171.22.39:27017' \
	'IP' '81.171.22.39'

masks "Steam CM region -> REGION (geolocation)" \
	'CM connect cmp1-atl3.steamserver.net selected' \
	'cmp1-REGION.steamserver.net' 'atl3'

masks "Steam CM region (sea1) -> REGION" \
	'CM connect cmp1-sea1.steamserver.net selected' \
	'cmp1-REGION.steamserver.net' 'sea1'

masks "account_name value -> NAME" \
	'force_account_name: bobsmith' \
	'NAME' 'bobsmith'

echo "── MUST keep (non-PII, diagnostic value) ──"

keeps "timestamp preserved" \
	'[2026-06-22 18:20:10] AppID 3525970 state changed' \
	'2026-06-22 18:20:10'

keeps "appid preserved" \
	'[Info] Added 2830030 to AdditionalApps' \
	'2830030'

keeps "appid in content_log preserved" \
	'[2026-06-22 18:20:10] AppID 3525970 finished update' \
	'3525970'

keeps "depot id preserved" \
	'Downloading 340 chunks for depot 3525973' \
	'3525973'

keeps "manifest gid (19 digits) preserved" \
	'depot 3525973 (5180242516049328806)' \
	'5180242516049328806'

keeps "build id preserved" \
	'finished update, 2 mounted depots (BuildID 23809768)' \
	'23809768'

keeps "steamclient hash (64 hex) preserved" \
	'steamclient.so hash is 27edb4221f6f9a20ac56bf4e0c01e323d6f6f7cf1f874b1c99b64bc65e772b35' \
	'27edb4221f6f9a20ac56bf4e0c01e323d6f6f7cf1f874b1c99b64bc65e772b35'

keeps "shader-cache hash (32 hex) preserved" \
	'shaderhitcache/9f8c366133ab1128/0b65b643da47be025a4fd8543de3c06d/2830030_pbuf' \
	'0b65b643da47be025a4fd8543de3c06d'

keeps "memory address preserved" \
	'[Info] ReconcilePin: hooked EvaluateConfigChanges at 0xcfc7825a' \
	'0xcfc7825a'

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
