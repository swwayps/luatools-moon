#!/usr/bin/env bash
# Regression test for install.sh plugin updates preserving and migrating API state.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEST="$TMP/luatools"
BACKUP="$TMP/backup"
mkdir -p "$DEST/backend/data" "$BACKUP"
printf '%s\n' '{"language":"pt-BR"}' > "$DEST/backend/data/settings.json"
printf '%s\n' '{"api_list":[{"name":"Custom","url":"https://custom.invalid/<appid>"}]}' \
    > "$DEST/backend/api.json"

preserve_plugin_data "$DEST" "$BACKUP"

cmp -s "$DEST/backend/data/settings.json" "$BACKUP/settings.json" || {
    echo "FAIL existing backend/data was not preserved"
    exit 1
}
cmp -s "$DEST/backend/api.json" "$BACKUP/api.json" || {
    echo "FAIL legacy backend/api.json was not migrated"
    exit 1
}

printf '%s\n' '{"api_list":[{"name":"Persistent"}]}' > "$DEST/backend/data/api.json"
rm -rf "$BACKUP"
mkdir -p "$BACKUP"
preserve_plugin_data "$DEST" "$BACKUP"

cmp -s "$DEST/backend/data/api.json" "$BACKUP/api.json" || {
    echo "FAIL persistent data/api.json was overwritten by the legacy file"
    exit 1
}

RESTORED="$TMP/restored"
restore_plugin_data "$RESTORED" "$BACKUP" || {
    echo "FAIL preserved plugin data could not be restored"
    exit 1
}
cmp -s "$BACKUP/api.json" "$RESTORED/backend/data/api.json" || {
    echo "FAIL restored API catalog differs from the preserved copy"
    exit 1
}

rm -rf "$BACKUP"
mkdir -p "$BACKUP"
cp() { return 1; }
if preserve_plugin_data "$DEST" "$BACKUP"; then
    echo "FAIL preservation errors must stop the update before the old plugin is deleted"
    exit 1
fi
if restore_plugin_data "$RESTORED" "$BACKUP"; then
    echo "FAIL restoration errors must be reported without deleting the backup"
    exit 1
fi
unset -f cp

DEST_TREE="$TMP/active-plugin"
STAGED_TREE="$TMP/staged-plugin"
PREVIOUS_TREE="$TMP/previous-plugin"
mkdir -p "$DEST_TREE" "$STAGED_TREE"
printf 'old\n' > "$DEST_TREE/version"
printf 'new\n' > "$STAGED_TREE/version"
activate_plugin_tree "$DEST_TREE" "$STAGED_TREE" "$PREVIOUS_TREE" || {
    echo "FAIL staged plugin could not be activated"
    exit 1
}
grep -qx 'new' "$DEST_TREE/version" || {
    echo "FAIL staged plugin did not replace the old tree"
    exit 1
}

rm -rf "$DEST_TREE" "$STAGED_TREE" "$PREVIOUS_TREE"
mkdir -p "$DEST_TREE" "$STAGED_TREE"
printf 'old\n' > "$DEST_TREE/version"
printf 'new\n' > "$STAGED_TREE/version"
mv() {
    if [ "$1" = "$STAGED_TREE" ] && [ "$2" = "$DEST_TREE" ]; then return 1; fi
    command mv "$@"
}
if activate_plugin_tree "$DEST_TREE" "$STAGED_TREE" "$PREVIOUS_TREE"; then
    echo "FAIL activation failure must be reported"
    exit 1
fi
unset -f mv
grep -qx 'old' "$DEST_TREE/version" || {
    echo "FAIL old plugin was not rolled back after activation failure"
    exit 1
}

echo "ok - plugin data and legacy API catalog survive updates"
