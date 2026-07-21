#!/usr/bin/env bash
# Integration test for downloader.sh's fix-DLL manifest (.slssteam_fix_dlls).
#
# The manifest is what lets fix_overlays force native (=n,b) on exactly the DLLs
# a fix/crack archive shipped -- so a crack loader with an arbitrary name
# (voices38, an emulator's steam_api64, ...) is overridden while the game's own
# DLLs are left alone. This drives the real downloader.sh end to end over a
# file:// URL, with the bundled 7zz substituted by the system 7z.
#
# Run from the repo root:  bash scripts/test-downloader-manifest.sh
set -u

fails=0
check() { if eval "$2"; then echo "ok $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

SEVENZ_SYS="$(command -v 7zz || command -v 7z || command -v 7za || true)"
if [ -z "$SEVENZ_SYS" ]; then echo "SKIP: no system 7z/7zz available"; exit 0; fi
if ! command -v curl >/dev/null 2>&1; then echo "SKIP: no curl"; exit 0; fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Lay out a fake plugin tree so downloader.sh resolves $SCRIPT_DIR/../bin/7zz.
mkdir -p "$TMP/backend/scripts" "$TMP/backend/bin"
cp "$REPO/plugin/backend/scripts/downloader.sh" "$TMP/backend/scripts/downloader.sh"
ln -s "$SEVENZ_SYS" "$TMP/backend/bin/7zz"
DL="$TMP/backend/scripts/downloader.sh"

mkfile() { mkdir -p "$(dirname "$1")"; printf 'x' > "$1"; }

# ---------------------------------------------------------------------------
# T1: a direct crack archive (DLLs at top level + a nested subdir). Manifest
# must list the crack DLLs and NOT the game's own DLL sitting in the game dir.
# ---------------------------------------------------------------------------
SRC="$TMP/t1src"
mkfile "$SRC/steam_api64.dll"
mkfile "$SRC/voices38.dll"
mkfile "$SRC/Engine/Binaries/Win64/winmm.dll"
mkfile "$SRC/readme.txt"
( cd "$SRC" && "$SEVENZ_SYS" a -tzip "$TMP/t1.zip" . >/dev/null 2>&1 )

GAME1="$TMP/game1"
mkfile "$GAME1/d3d11.dll"   # the game's own DLL -- must be ignored
EXTRACT_NESTED=1 MAX_TIME=0 bash "$DL" \
  "file://$TMP/t1.zip" "$TMP/t1dl.zip" "$GAME1" "$TMP/t1state.json" >/dev/null 2>&1

MAN1="$GAME1/.slssteam_fix_dlls"
check "T1 manifest exists" "[ -f '$MAN1' ]"
check "T1 lists steam_api64" "grep -qix 'steam_api64.dll' '$MAN1'"
check "T1 lists voices38" "grep -qix 'voices38.dll' '$MAN1'"
check "T1 lists winmm (nested subdir)" "grep -qix 'winmm.dll' '$MAN1'"
check "T1 excludes game d3d11" "! grep -qix 'd3d11.dll' '$MAN1'"
check "T1 excludes non-dll" "! grep -qi 'readme' '$MAN1'"

# ---------------------------------------------------------------------------
# T2: a fix shipped as an archive-inside-an-archive (outer .zip -> inner .7z).
# The nested pass must capture the inner archive's DLLs into the manifest
# BEFORE the residual archives are deleted.
# ---------------------------------------------------------------------------
ISRC="$TMP/t2inner"
mkfile "$ISRC/OnlineFix64.dll"
mkfile "$ISRC/winhttp.dll"
( cd "$ISRC" && "$SEVENZ_SYS" a -t7z "$TMP/inner.7z" . >/dev/null 2>&1 )
OSRC="$TMP/t2outer"; mkdir -p "$OSRC"; cp "$TMP/inner.7z" "$OSRC/"
( cd "$OSRC" && "$SEVENZ_SYS" a -tzip "$TMP/t2.zip" . >/dev/null 2>&1 )

GAME2="$TMP/game2"; mkdir -p "$GAME2"
EXTRACT_NESTED=1 MAX_TIME=0 bash "$DL" \
  "file://$TMP/t2.zip" "$TMP/t2dl.zip" "$GAME2" "$TMP/t2state.json" >/dev/null 2>&1

MAN2="$GAME2/.slssteam_fix_dlls"
check "T2 manifest exists" "[ -f '$MAN2' ]"
check "T2 lists nested OnlineFix64" "grep -qix 'OnlineFix64.dll' '$MAN2'"
check "T2 lists nested winhttp" "grep -qix 'winhttp.dll' '$MAN2'"
check "T2 inner archive removed" "[ -z \"\$(find '$GAME2' -iname '*.7z')\" ]"

# ---------------------------------------------------------------------------
# T3: a crack that ships its OWN launcher (FC25-style). The launcher manifest
# (.slssteam_fix_launchers) must list the launcher-pattern exes WITH their
# relative paths, and must NOT list the game's own pre-existing launcher.exe
# (we list the archive, not the game dir) nor plain game exes.
# ---------------------------------------------------------------------------
LSRC="$TMP/t3src"
mkfile "$LSRC/Launcher.exe"
mkfile "$LSRC/tools/FC25_Launcher.exe"
mkfile "$LSRC/bin/Launcher_x64.exe"
mkfile "$LSRC/FIFA23.exe"        # plain game exe -- must be ignored
mkfile "$LSRC/relauncher.exe"    # substring only -- must be ignored
( cd "$LSRC" && "$SEVENZ_SYS" a -tzip "$TMP/t3.zip" . >/dev/null 2>&1 )

GAME3="$TMP/game3"
mkfile "$GAME3/launcher.exe"     # the game's OWN launcher -- must be ignored
EXTRACT_NESTED=1 MAX_TIME=0 bash "$DL" \
  "file://$TMP/t3.zip" "$TMP/t3dl.zip" "$GAME3" "$TMP/t3state.json" >/dev/null 2>&1

LMAN3="$GAME3/.slssteam_fix_launchers"
check "T3 launcher manifest exists" "[ -f '$LMAN3' ]"
check "T3 lists top-level Launcher.exe" "grep -qix 'Launcher.exe' '$LMAN3'"
check "T3 lists nested _launcher with path" "grep -qix 'tools/FC25_Launcher.exe' '$LMAN3'"
check "T3 lists nested launcher_ with path" "grep -qix 'bin/Launcher_x64.exe' '$LMAN3'"
check "T3 excludes plain game exe" "! grep -qi 'FIFA23.exe' '$LMAN3'"
check "T3 excludes substring relauncher" "! grep -qix 'relauncher.exe' '$LMAN3'"

# ---------------------------------------------------------------------------
# T4: a crack with NO launcher must NOT produce a launcher manifest (so the
# redirect feature stays inert for the common DLL-only crack).
# ---------------------------------------------------------------------------
NSRC="$TMP/t4src"
mkfile "$NSRC/steam_api64.dll"
mkfile "$NSRC/game.exe"
( cd "$NSRC" && "$SEVENZ_SYS" a -tzip "$TMP/t4.zip" . >/dev/null 2>&1 )
GAME4="$TMP/game4"; mkdir -p "$GAME4"
EXTRACT_NESTED=1 MAX_TIME=0 bash "$DL" \
  "file://$TMP/t4.zip" "$TMP/t4dl.zip" "$GAME4" "$TMP/t4state.json" >/dev/null 2>&1
check "T4 no launcher manifest" "[ ! -f '$GAME4/.slssteam_fix_launchers' ]"

if [ "$fails" -eq 0 ]; then echo; echo "ALL TESTS OK"; else echo; echo "$fails FAILED"; exit 1; fi
