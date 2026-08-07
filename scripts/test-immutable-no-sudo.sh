#!/usr/bin/env bash
# Immutable systems must never invoke or pre-warm sudo. Root-owned legacy
# cleanup is deliberately skipped there; all normal installation work is
# user-scoped.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$SUDO_CALLS"
exit 0
EOF
chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH" SUDO_CALLS="$TMP/sudo.calls" SLSPLUGIN_LIB_ONLY=1
# shellcheck source=/dev/null
. "$HERE/install.sh" >/dev/null 2>&1

OS_RELEASE_FILE="$TMP/os-release"
printf 'ID=steamos\nID_LIKE=arch\n' > "$OS_RELEASE_FILE"
export OS_RELEASE_FILE

fail=0
check_empty() {
  if [ ! -s "$SUDO_CALLS" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s: %s\n' "$1" "$(cat "$SUDO_CALLS")"; fail=1; fi
  : > "$SUDO_CALLS"
}

preask_sudo
check_empty "preask_sudo is a no-op on immutable"

out="$(sudo_prefix)"
[ -z "$out" ] && printf 'ok   - sudo_prefix is empty on immutable\n' || {
  printf 'FAIL - sudo_prefix on immutable returned [%s]\n' "$out"; fail=1;
}
check_empty "sudo_prefix does not invoke sudo on immutable"

ensure_sudo
check_empty "ensure_sudo is a no-op on immutable"

CLEANUP_HOME="$TMP/cleanup-home"
CLEANUP_OS="$TMP/cleanup-os-release"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$CLEANUP_OS"
mkdir -p "$CLEANUP_HOME/.local/share/SLSsteam/backup" \
         "$CLEANUP_HOME/.local/share/SLSsteam/system-launcher-backup" \
         "$CLEANUP_HOME/.local/share/SLSsteam/disposable"
printf 'legacy-backup\n' > "$CLEANUP_HOME/.local/share/SLSsteam/backup/marker"
printf 'launcher-backup\n' > "$CLEANUP_HOME/.local/share/SLSsteam/system-launcher-backup/marker"
printf 'remove-me\n' > "$CLEANUP_HOME/.local/share/SLSsteam/disposable/marker"
HOME="$CLEANUP_HOME" OS_RELEASE_FILE="$CLEANUP_OS" \
  cleanup_previous_install >/dev/null 2>&1
if [ -f "$CLEANUP_HOME/.local/share/SLSsteam/backup/marker" ] \
   && [ -f "$CLEANUP_HOME/.local/share/SLSsteam/system-launcher-backup/marker" ] \
   && [ ! -e "$CLEANUP_HOME/.local/share/SLSsteam/disposable" ]; then
  printf 'ok   - reinstall cleanup preserves SLSsteam backups\n'
else
  printf 'FAIL - reinstall cleanup does not preserve SLSsteam backups\n'; fail=1
fi

preask_body="$(sed -n '/^preask_prompts()/,/^}/p' "$HERE/install.sh")"
if printf '%s\n' "$preask_body" | grep -q 'preask_sudo'; then
  printf 'FAIL - immutable prompt flow still calls preask_sudo\n'; fail=1
else
  printf 'ok   - immutable prompt flow never calls preask_sudo\n'
fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
