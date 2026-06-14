#!/usr/bin/env bash
# Unit test for install.sh's DisableCloud config logic.
#
# Why this exists
# ---------------
# SLSsteam's `DisableCloud` controls whether Steam Cloud is suppressed for the
# added games. With the CloudRedirect hook present, cloud RPCs must flow
# (DisableCloud: no) so CloudRedirect can intercept them. Without the hook,
# Steam's cloud backend rejects the (ownership-unbacked) sync for those games
# and surfaces a "Steam Cloud Error", so cloud must be disabled
# (DisableCloud: yes).
#
# The installer makes the config match the real state of the hook on disk. The
# config is created lazily by slsteam-moon on Steam's first launch (after this
# installer) and slsteam-moon raises a "missing key(s)" popup on every load if
# any key is absent — so the installer pre-seeds the FULL template
# (seed_slsteam_config) and only ever FLIPS the DisableCloud key
# (set_disable_cloud), never writes a partial config. This pins that logic.
#
# Run: bash scripts/test-set-disable-cloud.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

failures=0
check() { # $1 desc  $2 result(0/1)
	if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
	else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

TESTHOME="$(mktemp -d)"
export HOME="$TESTHOME"
export SLSPLUGIN_LIB_ONLY=1

# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

CFG="$HOME/.config/SLSsteam/config.yaml"
cfg_val() { grep -E "^DisableCloud:" "$CFG" 2>/dev/null | sed -E 's/^DisableCloud:[[:space:]]*([a-z]+).*/\1/'; }
reset_cfg() { rm -rf "$HOME/.config"; }

# A stand-in for slsteam-moon's full res/config.yaml template (multiple keys,
# including DisableCloud and a couple others we assert survive a flip).
TEMPLATE="$TESTHOME/template.yaml"
cat > "$TEMPLATE" <<'YAML'
AutoFilterList: yes
AdditionalApps:
DlcData:
Notifications: yes
DisableCloud: no
LogLevel: 2
YAML

# --- seed_slsteam_config ----------------------------------------------------

# 1) Absent config + valid template -> full template copied verbatim.
reset_cfg
seed_slsteam_config "$TEMPLATE" >/dev/null 2>&1
{ [ -f "$CFG" ] && grep -q "^DlcData:" "$CFG" && grep -q "^Notifications: yes" "$CFG" && [ "$(cfg_val)" = "no" ]; }
check "seed: absent config -> copies full template (all keys)" $?

# 2) Existing config -> never clobbered.
reset_cfg; mkdir -p "$(dirname "$CFG")"; printf 'DisableCloud: yes\nMINE: keepme\n' > "$CFG"
seed_slsteam_config "$TEMPLATE" >/dev/null 2>&1
grep -q "^MINE: keepme" "$CFG"; check "seed: existing config left untouched" $?

# 3) Missing template source -> no-op, no config created.
reset_cfg
seed_slsteam_config "$TESTHOME/does-not-exist.yaml" >/dev/null 2>&1
[ ! -f "$CFG" ]; check "seed: missing template -> no config created" $?

# --- set_disable_cloud (flip-only on an existing config) --------------------

# 4) Existing 'no' + set yes -> flips to yes, other keys preserved.
reset_cfg; seed_slsteam_config "$TEMPLATE" >/dev/null 2>&1
set_disable_cloud yes >/dev/null 2>&1
{ [ "$(cfg_val)" = "yes" ] && grep -q "^DlcData:" "$CFG"; }
check "set yes: flips no->yes, keeps other keys" $?

# 5) Existing 'yes' + set no -> flips to no.
reset_cfg; mkdir -p "$(dirname "$CFG")"; printf 'DisableCloud: yes\n' > "$CFG"
set_disable_cloud no >/dev/null 2>&1
[ "$(cfg_val)" = "no" ]; check "set no: flips yes->no" $?

# 6) Existing config WITHOUT the key -> key appended.
reset_cfg; mkdir -p "$(dirname "$CFG")"; printf 'Notifications: yes\n' > "$CFG"
set_disable_cloud yes >/dev/null 2>&1
{ [ "$(cfg_val)" = "yes" ] && grep -q "^Notifications: yes" "$CFG"; }
check "set yes: appends missing key, keeps others" $?

# 7) Idempotent: already correct -> no-op, returns 0.
reset_cfg; mkdir -p "$(dirname "$CFG")"; printf 'DisableCloud: yes\n' > "$CFG"
set_disable_cloud yes; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cfg_val)" = "yes" ]; }
check "set yes: already correct -> no-op, rc 0" $?

# 8) Absent config -> no-op (must NOT write a partial config), returns 0.
reset_cfg
set_disable_cloud yes; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -f "$CFG" ]; }
check "set: absent config -> no partial file written, rc 0" $?

# --- sync_cloud_config_with_hook (decides yes/no by hook presence) ----------

# 9) Hook present on disk -> DisableCloud: no.
reset_cfg; seed_slsteam_config "$TEMPLATE" >/dev/null 2>&1
mkdir -p "$(dirname "$CR_SO_PATH")"; : > "$CR_SO_PATH"
sync_cloud_config_with_hook >/dev/null 2>&1
[ "$(cfg_val)" = "no" ]; check "sync: hook on disk -> DisableCloud: no" $?

# 10) Hook absent -> DisableCloud: yes.
reset_cfg; seed_slsteam_config "$TEMPLATE" >/dev/null 2>&1
rm -f "$CR_SO_PATH"
sync_cloud_config_with_hook >/dev/null 2>&1
[ "$(cfg_val)" = "yes" ]; check "sync: hook absent -> DisableCloud: yes" $?

rm -rf "$TESTHOME"
echo ""
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures CHECK(S) FAILED"; exit 1
