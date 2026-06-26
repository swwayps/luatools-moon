#!/usr/bin/env bash
# Unit test for install.sh's old-port dummy-game cleanup:
#   - config_has_added_app   (AdditionalApps membership, block-scoped)
#   - reset_dummy_oldport_games (remove SizeOnDisk-0 + not-AddedApp games only)
#   - disable_playnotowned   (flip PlayNotOwnedGames -> no, preserve the rest)
#
# The discriminator is validated against the real Zorin VM state: a dummy
# (MECCHA, SizeOnDisk 0, not in AdditionalApps) must be removed, while a real
# install (Silksong, SizeOnDisk 8.2 GB, in AdditionalApps — note its
# InstalledDepots is ALSO empty, so size+membership are what distinguish them)
# must be preserved.
#
# Run: bash scripts/test-oldport-cleanup.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"; else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi; }

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

TESTDIR="$(mktemp -d)"
export HOME="$TESTDIR/home"
SA="$HOME/.steam/steam/steamapps"
STPLUG="$HOME/.steam/steam/config/stplug-in"
CFGDIR="$HOME/.config/SLSsteam"
mkdir -p "$SA/common" "$SA/downloading" "$STPLUG" "$CFGDIR"

# write_acf <appid> <sizeondisk> <installdir>
write_acf() {
	local id="$1" size="$2" dir="$3"
	cat > "$SA/appmanifest_${id}.acf" <<EOF
"AppState"
{
	"appid"		"$id"
	"name"		"Game $id"
	"StateFlags"		"4"
	"installdir"		"$dir"
	"SizeOnDisk"		"$size"
	"InstalledDepots"
	{
	}
}
EOF
}

# --- fixtures ---------------------------------------------------------------
# Dummy (MECCHA-like): SizeOnDisk 0, NOT in AdditionalApps, has stplug lua + empty common dir.
write_acf 4704690 0 "MECCHA CHAMELEON"
mkdir -p "$SA/common/MECCHA CHAMELEON"
printf 'addappid(4704690)\n' > "$STPLUG/4704690.lua"

# Working (Silksong-like): SizeOnDisk huge, IN AdditionalApps, real files.
write_acf 1030300 8225770198 "Hollow Knight Silksong"
mkdir -p "$SA/common/Hollow Knight Silksong"
printf 'game-bytes\n' > "$SA/common/Hollow Knight Silksong/game.dat"

# AddedApp mid-install: SizeOnDisk 0 but IN AdditionalApps -> must be kept.
write_acf 555 0 "Five Five Five"
mkdir -p "$SA/common/Five Five Five"

# Real game NOT in AdditionalApps but SizeOnDisk > 0 -> kept (size guard).
write_acf 999 4096 "Nine Nine Nine"
mkdir -p "$SA/common/Nine Nine Nine"
printf 'x\n' > "$SA/common/Nine Nine Nine/data"

# SizeOnDisk 0 + not in AdditionalApps but NO stplug lua -> kept (not ours).
write_acf 777 0 "Seven Seven Seven"
mkdir -p "$SA/common/Seven Seven Seven"

# config.yaml: PlayNotOwnedGames yes (old port), AdditionalApps has 1030300 + 555.
# 4704690 is placed under a DIFFERENT list key (FakeAppIds) to test scoping.
cat > "$CFGDIR/config.yaml" <<'EOF'
# slsteam config
PlayNotOwnedGames: yes
DisableCloud: no
LogLevel: 2
AdditionalApps:
  - 1030300   # Hollow Knight: Silksong
  - 555
FakeAppIds:
  - 4704690
EOF

# --- config_has_added_app scoping ------------------------------------------
CFG="$CFGDIR/config.yaml"
config_has_added_app "$CFG" 1030300; check "config_has_added_app: 1030300 (in AdditionalApps) -> yes" $?
config_has_added_app "$CFG" 555;     check "config_has_added_app: 555 (in AdditionalApps) -> yes" $?
if config_has_added_app "$CFG" 4704690; then r=1; else r=0; fi; check "config_has_added_app: 4704690 (only under FakeAppIds) -> no" $r
if config_has_added_app "$CFG" 999;     then r=1; else r=0; fi; check "config_has_added_app: 999 (absent) -> no" $r

# --- reset_dummy_oldport_games ---------------------------------------------
# Secondary trigger: a dummy is present, so has_oldport_dummy must see it.
has_oldport_dummy; check "has_oldport_dummy: detects the dummy (secondary trigger)" $?

reset_dummy_oldport_games >/dev/null 2>&1

[ ! -e "$SA/appmanifest_4704690.acf" ];        check "dummy 4704690: appmanifest removed" $?
[ ! -e "$SA/common/MECCHA CHAMELEON" ];        check "dummy 4704690: common dir removed" $?
[ ! -e "$STPLUG/4704690.lua" ];                check "dummy 4704690: stplug lua removed (gone from LuaTools list)" $?

[ -e "$SA/appmanifest_1030300.acf" ];          check "Silksong 1030300: appmanifest KEPT (SizeOnDisk>0 + AddedApp)" $?
[ -e "$SA/common/Hollow Knight Silksong/game.dat" ]; check "Silksong 1030300: real files KEPT" $?
[ -e "$SA/appmanifest_555.acf" ];              check "AddedApp 555: KEPT despite SizeOnDisk 0 (in AdditionalApps)" $?
[ -e "$SA/appmanifest_999.acf" ];              check "Game 999: KEPT (SizeOnDisk>0, not AddedApp)" $?
[ -e "$SA/appmanifest_777.acf" ];              check "Game 777: KEPT (SizeOnDisk 0 but no stplug lua -> not ours)" $?

# After removing the only real dummy, none remain.
if has_oldport_dummy; then r=1; else r=0; fi; check "has_oldport_dummy: none left after reset" $r

# --- disable_playnotowned --------------------------------------------------
disable_playnotowned >/dev/null 2>&1
grep -qE '^[[:space:]]*PlayNotOwnedGames:[[:space:]]*no([[:space:]]|#|$)' "$CFG"; check "PlayNotOwnedGames flipped to no" $?
grep -qE '^[[:space:]]*-[[:space:]]*1030300' "$CFG"; check "AdditionalApps 1030300 preserved" $?
grep -qE '^[[:space:]]*-[[:space:]]*555' "$CFG"; check "AdditionalApps 555 preserved" $?
grep -qE '^LogLevel: 2' "$CFG"; check "unrelated key (LogLevel) preserved" $?

# idempotent: a second run is a no-op and leaves it 'no'.
disable_playnotowned >/dev/null 2>&1
grep -qE '^[[:space:]]*PlayNotOwnedGames:[[:space:]]*no([[:space:]]|#|$)' "$CFG"; check "disable_playnotowned idempotent" $?

rm -rf "$TESTDIR"
echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
