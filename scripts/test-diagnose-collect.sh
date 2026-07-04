#!/usr/bin/env bash
# Integration test for diagnose.sh's collect(): builds a real .tar.gz bundle
# from a synthetic HOME and asserts the bundle is COMPLETE, SCRUBBED and free of
# secrets.
#
# Checks:
#   - bundle is a valid gzip tar with the expected per-component entries;
#   - credential files (CloudRedirect OAuth tokens, Lumen session token) are
#     NEVER included;
#   - person-identifying data inside the archived logs is scrubbed;
#   - appids / game names are kept (non-PII);
#   - full logs are archived complete, EXCEPT cef_log which is tail-capped.
#
# Run: bash scripts/test-diagnose-collect.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGNOSE_SH="$SCRIPT_DIR/../diagnose.sh"

export DIAGNOSE_LIB_ONLY=1
# shellcheck disable=SC1090
source "$DIAGNOSE_SH" >/dev/null 2>&1 || true

failures=0
check() { if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi; }

FAKE="$(mktemp -d)"
WORK="$(mktemp -d)"
TAR="$WORK/bundle.tar.gz"
EXTRACT="$WORK/x"
cleanup() { rm -rf "$FAKE" "$WORK"; }
trap cleanup EXIT

# ── plant a synthetic HOME ──────────────────────────────────────────────────
mkdir -p "$FAKE/.config/SLSsteam" "$FAKE/.config/CloudRedirect" \
         "$FAKE/.local/share/Steam/logs" "$FAKE/.local/share/Lumen" "$FAKE/.steam"
ln -s "$FAKE/.local/share/Steam" "$FAKE/.steam/steam"

printf '[Info] Added 2830030 to AdditionalApps\n[Info] userdata/488150314 cmp1-atl3.steamserver.net\n' \
	> "$FAKE/.SLSsteam.log"
printf 'PlayNotOwnedGames: 1\nFakeEmail: secret.guy@gmail.com\n' \
	> "$FAKE/.config/SLSsteam/config.yaml"
printf '[lumen] connected 76561198448416042 from 81.171.22.39\n' \
	> "$FAKE/.lumen.log"
printf '[2026-06-22 18:20:10] AppID 3525970 commit common/Horripilant\n' \
	> "$FAKE/.local/share/Steam/logs/content_log.txt"
printf '[CR] DoInit ok\n' > "$FAKE/.config/CloudRedirect/cr_debug.log"
# a big, noisy cef_log that must be tail-capped (not archived whole)
head -c 2000000 /dev/zero | tr '\0' 'x' > "$FAKE/.local/share/Steam/logs/cef_log.txt"
# .desktop launchers (show the LD_AUDIT wrapper Exec line). Several *steam*
# variants scattered across app/autostart dirs — all must be collected into the
# single steam-desktops.txt file with BEGIN/END separators.
mkdir -p "$FAKE/.local/share/applications" "$FAKE/usr-share-applications" \
         "$FAKE/.config/autostart" "$FAKE/flatpak-applications"
printf '[Desktop Entry]\nExec=/home/peeblyweeb/.local/share/SLSsteam/path/steam %%U\n' \
	> "$FAKE/.local/share/applications/steam.desktop"
printf '[Desktop Entry]\nExec=/usr/bin/steam %%U\n' \
	> "$FAKE/usr-share-applications/steam.desktop"
printf '[Desktop Entry]\nExec=steam steam://rungameid/730\nName=Steam CS2\n' \
	> "$FAKE/.local/share/applications/steam-cs2.desktop"
printf '[Desktop Entry]\nExec=steam -silent %%U\nX-SLSteamMoon-Patched=true\n' \
	> "$FAKE/.config/autostart/steam.desktop"
printf '[Desktop Entry]\nExec=flatpak run com.valvesoftware.Steam\nName=Steam (Flatpak)\n' \
	> "$FAKE/flatpak-applications/com.valvesoftware.Steam.desktop"
export DIAG_DESKTOP_DIRS="$FAKE/.local/share/applications:$FAKE/usr-share-applications:$FAKE/.config/autostart:$FAKE/flatpak-applications"
# secrets that must NEVER be collected
printf 'ya29.SUPER_SECRET_OAUTH\n' > "$FAKE/.config/CloudRedirect/tokens_gdrive.json"
printf '{"token":"LUMEN_RPC_SECRET"}\n' > "$FAKE/.local/share/Lumen/session.json"

# ── build the bundle ────────────────────────────────────────────────────────
export HOME="$FAKE"
DIAG_CEF_CAP=65536
collect "$TAR" 0 2>/dev/null

# valid gzip tar?
tar -tzf "$TAR" >/dev/null 2>&1; check "produces a valid gzip tar" $?

entries="$(tar -tzf "$TAR" 2>/dev/null)"
echo "$entries" | grep -q 'slsteam\.log'              ; check "contains slsteam.log" $?
echo "$entries" | grep -q 'slsteam-config\.yaml'      ; check "contains slsteam config" $?
echo "$entries" | grep -q 'lumen\.log'                ; check "contains lumen.log" $?
echo "$entries" | grep -q 'steam-logs/content_log\.txt'; check "contains steam content_log" $?
echo "$entries" | grep -q 'cloudredirect-cr_debug\.log'; check "contains cloudredirect log" $?
echo "$entries" | grep -q 'steam-desktops\.txt'; check "contains steam-desktops.txt" $?

# secrets must be absent from the listing
if echo "$entries" | grep -qiE 'token|session\.json'; then check "no credential files in bundle" 1
else check "no credential files in bundle" 0; fi

# ── extract and inspect content ─────────────────────────────────────────────
mkdir -p "$EXTRACT"; tar -xzf "$TAR" -C "$EXTRACT" 2>/dev/null
blob="$(cat "$EXTRACT"/* "$EXTRACT"/steam-logs/* 2>/dev/null)"

# NB: use a here-string, not `printf | grep -q`. Sourcing diagnose.sh turns on
# `pipefail`; with -q grep short-circuits on an early match and SIGPIPEs the
# writer, which pipefail would surface as a spurious failure.
no_leak() { if grep -qF "$2" <<<"$blob"; then check "$1" 1; else check "$1" 0; fi; }
keeps()   { if grep -qF "$2" <<<"$blob"; then check "$1" 0; else check "$1" 1; fi; }

no_leak "no account id leak"   '488150314'
no_leak "no SteamID64 leak"    '76561198448416042'
no_leak "no email leak"        'secret.guy@gmail.com'
no_leak "no IPv4 leak"         '81.171.22.39'
no_leak "no CM region leak"    'atl3.steamserver'
no_leak "no OAuth token leak"  'SUPER_SECRET_OAUTH'
no_leak "no RPC token leak"    'LUMEN_RPC_SECRET'
no_leak "no .desktop home leak" 'peeblyweeb'
keeps   "keeps .desktop exec"  'SLSsteam/path/steam'
keeps   "keeps appid"          '2830030'
keeps   "keeps game name"      'Horripilant'

# every *steam*.desktop across the search roots is collected into the one file,
# each wrapped in BEGIN/END separators (patched autostart + unpatched alike).
desk="$(cat "$EXTRACT/steam-desktops.txt" 2>/dev/null)"
in_desk() { if grep -qF "$2" <<<"$desk"; then check "$1" 0; else check "$1" 1; fi; }
in_desk "desktops: has BEGIN separator" '===== BEGIN '
in_desk "desktops: has END separator"   '===== END '
in_desk "desktops: user launcher"       'SLSsteam/path/steam'
in_desk "desktops: system launcher"     '/usr/bin/steam'
in_desk "desktops: extra steam-cs2"     'Steam CS2'
in_desk "desktops: autostart launcher"  'X-SLSteamMoon-Patched=true'
in_desk "desktops: flatpak launcher"    'com.valvesoftware.Steam'
# separator path headers are scrubbed too (no raw home/username)
if grep -qF '/home/USER/' <<<"$desk"; then check "desktops: separator path scrubbed" 0
else check "desktops: separator path scrubbed" 1; fi

# cef_log archived but tail-capped (< its original 2 MB; bounded by DIAG_CEF_CAP)
cef_sz="$(wc -c < "$EXTRACT/steam-logs/cef_log.txt" 2>/dev/null || echo 999999999)"
[ "$cef_sz" -le 70000 ]; check "cef_log tail-capped (got ${cef_sz}B)" $?

echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
