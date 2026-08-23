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
printf 'PlayNotOwnedGames: 1\nFakeEmail: probe.user@example.com\n' \
	> "$FAKE/.config/SLSsteam/config.yaml"
printf '[lumen] connected 76561198448416042 from 203.0.113.99\n' \
	> "$FAKE/.lumen.log"
printf '[2026-06-22 18:20:10] AppID 3525970 commit common/Horripilant\n' \
	> "$FAKE/.local/share/Steam/logs/content_log.txt"
printf '[CR] DoInit ok\n' > "$FAKE/.config/CloudRedirect/cr_debug.log"
# fake breakpad dump dir: 6 .dmp files (must be capped to the newest 4), one
# unsent *.dmp.upload (8-byte envelope stripped to a plain .dmp), and a
# <user>_stdout.txt staged as stdout.txt with the username scrubbed.
mkdir -p "$FAKE/dumps"
for n in 1 2 3 4 5 6; do
	printf 'MDMP-fake-%d\x00\x01\x02' "$n" > "$FAKE/dumps/crash_2025070${n}_120000_1000.dmp"
done
printf 'panic at /home/diaguser/steam diaguser 203.0.113.99\n' \
	> "$FAKE/dumps/diaguser_stdout.txt"
printf '0\x00\x00\x00\x00\x00\x00\x00MDMP-envelope-payload' \
	> "$FAKE/dumps/crash_20250707_130000_1000.dmp.upload"
# make mtimes strictly increasing so "newest 4" is deterministic (n=3..6 + upload)
for n in 1 2 3 4 5 6; do
	touch -d "2025-07-0$n 12:00:00" "$FAKE/dumps/crash_2025070${n}_120000_1000.dmp"
done
touch -d "2025-07-07 13:00:00" "$FAKE/dumps/diaguser_stdout.txt"
touch -d "2025-07-07 12:00:00" "$FAKE/dumps/crash_20250707_130000_1000.dmp.upload"
export DIAG_DUMP_DIRS="$FAKE/dumps"
# a big, noisy cef_log that must be tail-capped (not archived whole)
head -c 2000000 /dev/zero | tr '\0' 'x' > "$FAKE/.local/share/Steam/logs/cef_log.txt"
# .desktop launchers (show the LD_AUDIT wrapper Exec line). Several *steam*
# variants scattered across app/autostart dirs — all must be collected into the
# single steam-desktops.txt file with BEGIN/END separators.
mkdir -p "$FAKE/.local/share/applications" "$FAKE/usr-share-applications" \
         "$FAKE/.config/autostart" "$FAKE/flatpak-applications"
printf '[Desktop Entry]\nExec=/home/diaguser/.local/share/SLSsteam/path/steam %%U\n' \
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
# launch coverage fixtures: one managed shim, one untouched package launcher,
# mirrored backups for both paths, and a legacy flat backup. Backup contents
# include a canary secret to prove the report inventories paths only.
mkdir -p "$FAKE/system/bin" "$FAKE/system/games" \
         "$FAKE/.local/share/SLSsteam/system-launcher-backup/usr/bin" \
         "$FAKE/.local/share/SLSsteam/system-launcher-backup/usr/games"
printf '#!/bin/sh\n# slsteam-moon system launcher shim\n' > "$FAKE/system/bin/steam"
printf '#!/bin/sh\nexec /usr/lib/steam/steam\n' > "$FAKE/system/games/steam"
chmod 0755 "$FAKE/system/bin/steam" "$FAKE/system/games/steam"
# The shim's own mirrored capture, so the report can state whether that shim has
# a usable `steam`-named exec alias (Valve's launcher aborts under any other
# argv[0]; without the alias Steam dies before writing any log, which is exactly
# what this field makes visible).
SHIM_MIRROR="$FAKE/.local/share/SLSsteam/system-launcher-backup/${FAKE#/}/system/bin"
mkdir -p "$SHIM_MIRROR"
for backup in \
    "$FAKE/.local/share/SLSsteam/system-launcher-backup/usr/bin/steam.orig" \
    "$FAKE/.local/share/SLSsteam/system-launcher-backup/usr/games/steam.orig" \
    "$FAKE/.local/share/SLSsteam/system-launcher-backup/steam.orig" \
    "$SHIM_MIRROR/steam.orig"; do
    printf 'captured launcher; TOP_SECRET_BACKUP_CANARY\n' > "$backup"
    chmod 0755 "$backup"
done
ln -sfn steam.orig "$SHIM_MIRROR/steam"
export DIAG_LAUNCHER_DIRS="$FAKE/system/bin:$FAKE/system/games"
export DIAG_LAUNCHER_BACKUP_ROOT="$FAKE/.local/share/SLSsteam/system-launcher-backup"
export SLSM_COVERAGE_POLICY=launcher
# The wrapper itself, plus Steam's own bootstrap script: together they let the
# report state which launcher each entry point would actually exec.
mkdir -p "$FAKE/.local/share/SLSsteam/path"
printf '#!/bin/sh\n# slsteam-moon wrapper\n' > "$FAKE/.local/share/SLSsteam/path/steam"
printf '#!/bin/bash\n# steam.sh\n' > "$FAKE/.local/share/Steam/steam.sh"
chmod 0755 "$FAKE/.local/share/SLSsteam/path/steam" "$FAKE/.local/share/Steam/steam.sh"
export DIAG_WRAPPER="$FAKE/.local/share/SLSsteam/path/steam"

# crash-loop guard state: latched safe mode, a stale session, and a guard log
# carrying PII that must be scrubbed. guardian.log is oversized so the cap is
# exercised.
GUARD="$FAKE/.local/state/slsteam-moon"
mkdir -p "$GUARD"
printf 'safe mode active -> launching Steam without injection for /home/diaguser\n' \
	> "$GUARD/guard.log"
head -c 400000 /dev/zero | tr '\0' 'g' > "$GUARD/guardian.log"
: > "$GUARD/safe_mode"
: > "$GUARD/safe_mode_fingerprint"
printf '3' > "$GUARD/boot_fail_count"
printf 'BOOT-ID-RECORDED' > "$GUARD/session_id"
printf 'BOOT-ID-CURRENT' > "$FAKE/boot_id"
printf '4096:1750000000' > "$GUARD/last_client"
printf '4096:1740000000' > "$GUARD/good_client"
printf '1' > "$GUARD/last_launch_display"
: > "$GUARD/last_launch"
export DIAG_GUARD_DIR="$GUARD"
export DIAG_BOOT_ID_FILE="$FAKE/boot_id"
export DIAG_GUARDIAN_CAP=65536

# Steam-client core dumps: a stub coredumpctl (so the check does not depend on
# the host having systemd-coredump) plus a filename-only dump directory. Bodies
# must never be archived.
mkdir -p "$FAKE/bin" "$FAKE/coredump"
cat > "$FAKE/bin/coredumpctl" <<'STUB'
#!/bin/sh
printf 'TIME PID UID GID SIG COREFILE EXE\n'
printf 'Sun 2026-08-23 13:59:22 -03 217272 1000 1000 SIGABRT present /home/diaguser/.local/share/Steam/ubuntu12_32/steam\n'
printf 'Sun 2026-08-23 11:00:00 -03 4242 1000 1000 SIGSEGV present /usr/bin/some-other-app\n'
STUB
chmod 0755 "$FAKE/bin/coredumpctl"
printf 'CORE_BODY_CANARY_DO_NOT_ARCHIVE' > "$FAKE/coredump/core.steam.1000.abc.217272.zst"
export DIAG_COREDUMPCTL="$FAKE/bin/coredumpctl"
export DIAG_COREDUMP_DIR="$FAKE/coredump"

# Abnormal client exits: the steam.sh job-status line is localized (pt-BR here),
# so the collector must match the literal command text instead of the signal
# word, and must not pick up steam.sh's own debugger-echo line.
{
	printf '[2026-08-23 13:59:22] steam.sh[216862]: requirements are satisfied\n'
	printf '/home/diaguser/.local/share/Steam/steam.sh, linha 966: 217272 Abortado                   (imagem do núcleo gravada) "$STEAMROOT/$STEAMEXEPATH" "$@"\n'
	printf 'echo $STEAM_DEBUGGER -x /tmp/args --args "$STEAMROOT/$STEAMEXEPATH" "$@"\n'
} >> "$FAKE/.local/share/Steam/logs/console-linux.txt"
# secrets that must NEVER be collected
printf 'ya29.SUPER_SECRET_OAUTH\n' > "$FAKE/.config/CloudRedirect/tokens_gdrive.json"
printf '{"token":"LUMEN_RPC_SECRET"}\n' > "$FAKE/.local/share/Lumen/session.json"

# Policy state must follow the installer precedence exactly: the legacy
# desktop-fallback marker wins over a launcher state, and state files are
# accepted only when their bytes are exactly one canonical value plus newline.
export HOME="$FAKE"
POLICY_STATE="$FAKE/.local/state/slsteam-moon/coverage.policy"
mkdir -p "$(dirname "$POLICY_STATE")"
printf 'launcher\n' > "$POLICY_STATE"
printf 'desktop\n' > "$FAKE/.local/share/SLSsteam/coverage-policy.effective"
check "policy marker forces desktop fallback" "$([ "$(SLSM_COVERAGE_POLICY= DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
check "valid launcher override beats desktop marker" "$([ "$(SLSM_COVERAGE_POLICY=launcher DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = launcher ] && echo 0 || echo 1)"
check "valid desktop override remains desktop" "$([ "$(SLSM_COVERAGE_POLICY=desktop DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
check "invalid override defaults to desktop" "$([ "$(SLSM_COVERAGE_POLICY=invalid DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
rm -f "$FAKE/.local/share/SLSsteam/coverage-policy.effective"
printf 'launcher\n\n' > "$POLICY_STATE"
check "policy trailing blank defaults to desktop" "$([ "$(SLSM_COVERAGE_POLICY= DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
printf 'launcher\n' > "$POLICY_STATE"
check "invalid override beats stale launcher state" "$([ "$(SLSM_COVERAGE_POLICY=invalid DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
rm -f "$POLICY_STATE"
check "missing policy defaults to desktop" "$([ "$(SLSM_COVERAGE_POLICY= DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
printf 'desktop\n' > "$POLICY_STATE"
check "policy exact desktop state is accepted" "$([ "$(SLSM_COVERAGE_POLICY= DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = desktop ] && echo 0 || echo 1)"
printf 'launcher\n' > "$POLICY_STATE"
check "policy exact launcher state is accepted" "$([ "$(SLSM_COVERAGE_POLICY= DIAG_POLICY_FILE="$POLICY_STATE" _diag_effective_policy)" = launcher ] && echo 0 || echo 1)"

# ── build the bundle ────────────────────────────────────────────────────────
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
echo "$entries" | grep -q 'launch-coverage\.txt'; check "contains launch-coverage.txt" $?
echo "$entries" | grep -q 'slsteam-guard\.txt'; check "contains slsteam-guard.txt" $?
echo "$entries" | grep -q 'slsteam-guard\.log'; check "contains slsteam-guard.log" $?
echo "$entries" | grep -q 'slsteam-desktop-guardian\.log'; check "contains desktop guardian log" $?
echo "$entries" | grep -q 'steam-coredumps\.txt'; check "contains steam-coredumps.txt" $?
echo "$entries" | grep -q 'steam-client-crashes\.txt'; check "contains steam-client-crashes.txt" $?
echo "$entries" | grep -q 'steam-dumps/dumps/crash_20250706_120000_1000\.dmp'; check "contains newest crash dump" $?
echo "$entries" | grep -q 'steam-dumps/dumps/crash_20250705_120000_1000\.dmp'; check "contains 4th-newest dump (slot 4 of 4)" $?
if echo "$entries" | grep -q 'steam-dumps/dumps/crash_2025070[1-4]_120000_1000\.dmp'; then check "dump cap: 5th+ newest excluded" 1
else check "dump cap: 5th+ newest excluded" 0; fi
echo "$entries" | grep -q 'steam-dumps/dumps/stdout\.txt';    check "contains renamed dump stdout.txt" $?
# envelope-stripped .dmp.upload lands as its plain .dmp name; the original
# .upload name must not appear.
echo "$entries" | grep -q 'steam-dumps/dumps/crash_20250707_130000_1000\.dmp$'; check "envelope-stripped .dmp.upload -> .dmp" $?
if echo "$entries" | grep -q '\.dmp\.upload'; then check "no raw .dmp.upload in bundle" 1
else check "no raw .dmp.upload in bundle" 0; fi
# oldest two .dmp files must be excluded (cap = 4, but upload+stdout consume
# slots first since they're newer — assert the cap actually dropped files).
if echo "$entries" | grep -q 'crash_20250701_120000_1000\.dmp'; then check "dump count cap drops oldest" 1
else check "dump count cap drops oldest" 0; fi
# the username-bearing filename must not survive
if echo "$entries" | grep -q 'diaguser_stdout'; then check "no username in dump stdout filename" 1
else check "no username in dump stdout filename" 0; fi

# secrets must be absent from the listing
if echo "$entries" | grep -qiE 'token|session\.json'; then check "no credential files in bundle" 1
else check "no credential files in bundle" 0; fi

# ── extract and inspect content ─────────────────────────────────────────────
mkdir -p "$EXTRACT"; tar -xzf "$TAR" -C "$EXTRACT" 2>/dev/null
blob="$(cat "$EXTRACT"/* "$EXTRACT"/steam-logs/* "$EXTRACT"/steam-dumps/dumps/*_stdout.txt 2>/dev/null)"
coverage="$(cat "$EXTRACT/launch-coverage.txt" 2>/dev/null)"
in_coverage() { if grep -qF "$2" <<<"$coverage"; then check "$1" 0; else check "$1" 1; fi; }
# The report is inventory-only: it must classify live launchers and enumerate
# backup paths without reading backup contents.
in_coverage "coverage: effective policy" 'effective policy: launcher'
in_coverage "coverage: shim classification" 'status=shim'
in_coverage "coverage: vanilla classification" 'status=vanilla'
in_coverage "coverage: shim exec alias state" 'shim exec: '
in_coverage "coverage: shim exec alias is ready" 'status=ready'
in_coverage "coverage: mirrored backup paths" 'backup: mirrored '
in_coverage "coverage: legacy backup paths" 'backup: legacy '
# Which launcher each entry point actually reaches, and whether they disagree.
# In this fixture the wrapper's direct resolution skips the shim and lands on the
# vanilla package launcher, while the shim hands over its captured original — so
# the two targets differ and the divergence must be reported as such.
in_coverage "coverage: wrapper present" 'wrapper: '
in_coverage "coverage: direct launch target" 'launch target (desktop entry -> wrapper): '
in_coverage "coverage: direct target skips the shim" 'via=system-launcher'
in_coverage "coverage: shim launch target" 'via=shim-backup'
in_coverage "coverage: divergence reported" 'launch target divergence: yes'

# The reported failure shape: the shim is the ONLY system launcher (Arch/CachyOS
# has no /usr/games/steam), so a wrapper entered directly finds nothing but its
# own shim and falls through to Steam's steam.sh. Run with a sanitized PATH so a
# stray `steam` on the host cannot change the outcome.
SANEBIN="$FAKE/sanebin"; mkdir -p "$SANEBIN"
for u in readlink head grep; do
	p="$(command -v "$u" 2>/dev/null)" && ln -sf "$p" "$SANEBIN/$u"
done
shim_only="$(PATH="$SANEBIN" DIAG_LAUNCHER_DIRS="$FAKE/system/bin" \
	_diag_wrapper_direct_target "$DIAG_WRAPPER")"
check "shim-only host falls through to steam.sh" \
	"$([ "$(printf '%s' "$shim_only" | cut -f2)" = steam-sh-fallback ] && echo 0 || echo 1)"
check "shim-only fallback names steam.sh" \
	"$([ "$(printf '%s' "$shim_only" | cut -f1)" = "$FAKE/.local/share/Steam/steam.sh" ] && echo 0 || echo 1)"

# Regression: both fields must be non-empty. A leading tab is IFS whitespace, so
# `read` would drop the empty path field and shift via into it, mislabelling an
# unavailable target as a real launcher path.
no_shim="$(DIAG_LAUNCHER_DIRS="$FAKE/system/games" _diag_wrapper_shim_target "$DIAG_LAUNCHER_BACKUP_ROOT")"
check "no-shim target keeps both fields" \
	"$([ "$(printf '%s' "$no_shim" | cut -f1)" = none ] \
	   && [ "$(printf '%s' "$no_shim" | cut -f2)" = unavailable ] && echo 0 || echo 1)"
IFS=$'\t' read -r nsp nsv <<<"$no_shim"
check "no-shim target survives tab read" \
	"$([ "$nsp" = none ] && [ "$nsv" = unavailable ] && echo 0 || echo 1)"

# ── crash-loop guard state ──────────────────────────────────────────────────
guard="$(cat "$EXTRACT/slsteam-guard.txt" 2>/dev/null)"
in_guard() { if grep -qF "$2" <<<"$guard"; then check "$1" 0; else check "$1" 1; fi; }
in_guard "guard: safe mode latched"     'safe_mode: latched'
in_guard "guard: fingerprint present"   'safe_mode_fingerprint: present'
in_guard "guard: fail count"            'boot_fail_count: 3'
in_guard "guard: stale session"         'guard_session: stale'
in_guard "guard: last client id"        'last_client: 4096:1750000000'
in_guard "guard: good client id"        'good_client: 4096:1740000000'
in_guard "guard: display flag"          'last_launch_display: 1'
in_guard "guard: last launch age"       'seconds ago'
# The boot id is a per-boot machine identifier; only the current/stale verdict
# may leave the machine.
if grep -qF 'BOOT-ID' <<<"$guard"; then check "guard: boot id not archived" 1
else check "guard: boot id not archived" 0; fi
gd_sz="$(wc -c < "$EXTRACT/slsteam-desktop-guardian.log" 2>/dev/null || echo 999999999)"
[ "$gd_sz" -le 70000 ]; check "guardian log tail-capped (got ${gd_sz}B)" $?

# ── core dumps: inventory only ──────────────────────────────────────────────
cores="$(cat "$EXTRACT/steam-coredumps.txt" 2>/dev/null)"
in_cores() { if grep -qF "$2" <<<"$cores"; then check "$1" 0; else check "$1" 1; fi; }
out_cores() { if grep -qF "$2" <<<"$cores"; then check "$1" 1; else check "$1" 0; fi; }
in_cores  "cores: steam client entry"       'ubuntu12_32/steam'
in_cores  "cores: pid retained for triage"  '217272'
out_cores "cores: unrelated exe filtered"   'some-other-app'
in_cores  "cores: dump dir filename listed" 'core.steam.1000.abc.217272.zst'

# ── abnormal client exits ───────────────────────────────────────────────────
crash="$(cat "$EXTRACT/steam-client-crashes.txt" 2>/dev/null)"
in_crash()  { if grep -qF "$2" <<<"$crash"; then check "$1" 0; else check "$1" 1; fi; }
out_crash() { if grep -qF "$2" <<<"$crash"; then check "$1" 1; else check "$1" 0; fi; }
in_crash  "crashes: localized abort line kept" 'Abortado'
in_crash  "crashes: source file header"        '===== '
out_crash "crashes: debugger echo excluded"    'STEAM_DEBUGGER'
grep -q 'client_abnormal_exits: [1-9]' "$EXTRACT/summary.txt" 2>/dev/null
check "summary counts abnormal client exits" $?
# NB: the .dmp minidumps are binary and archived AS-IS by design — they are
# deliberately excluded from the scrub-leak sweep above (byte-shifting sed
# edits would corrupt them; see the header note in diagnose.sh).

# NB: use a here-string, not `printf | grep -q`. Sourcing diagnose.sh turns on
# `pipefail`; with -q grep short-circuits on an early match and SIGPIPEs the
# writer, which pipefail would surface as a spurious failure.
no_leak() { if grep -qF "$2" <<<"$blob"; then check "$1" 1; else check "$1" 0; fi; }
keeps()   { if grep -qF "$2" <<<"$blob"; then check "$1" 0; else check "$1" 1; fi; }

no_leak "no account id leak"   '488150314'
no_leak "no SteamID64 leak"    '76561198448416042'
no_leak "no email leak"        'probe.user@example.com'
no_leak "no IPv4 leak"         '203.0.113.99'
no_leak "no CM region leak"    'atl3.steamserver'
no_leak "no OAuth token leak"  'SUPER_SECRET_OAUTH'
no_leak "no RPC token leak"    'LUMEN_RPC_SECRET'
no_leak "no .desktop home leak" 'diaguser'
no_leak "no launcher backup contents" 'TOP_SECRET_BACKUP_CANARY'
no_leak "no coredump body contents" 'CORE_BODY_CANARY_DO_NOT_ARCHIVE'
# dump stdout specifically: username, home and IP scrubbed, content kept
dumpout="$(cat "$EXTRACT/steam-dumps/dumps/stdout.txt" 2>/dev/null)"
in_dumpout()  { if grep -qF "$2" <<<"$dumpout"; then check "$1" 0; else check "$1" 1; fi; }
out_dumpout() { if grep -qF "$2" <<<"$dumpout"; then check "$1" 1; else check "$1" 0; fi; }
in_dumpout  "dump stdout keeps message"  'panic at'
in_dumpout  "dump stdout home scrubbed"  '/home/USER/steam'
out_dumpout "dump stdout no raw username in body" 'weeb/steam diaguser'
out_dumpout "dump stdout no raw IP"      '203.0.113.99'
# envelope strip actually removed the 8-byte header
grep -qF 'MDMP-envelope-payload' "$EXTRACT/steam-dumps/dumps/crash_20250707_130000_1000.dmp" 2>/dev/null; check "stripped dump keeps payload" $?
if head -c 4 "$EXTRACT/steam-dumps/dumps/crash_20250707_130000_1000.dmp" 2>/dev/null | grep -q '^MDMP'; then check "stripped dump starts at payload" 0
else check "stripped dump starts at payload" 1; fi
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
