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

grep -q '! -name backup -exec rm -rf' "$HERE/install.sh" \
  && printf 'ok   - reinstall cleanup preserves SLSsteam/backup\n' \
  || { printf 'FAIL - reinstall cleanup does not preserve SLSsteam/backup\n'; fail=1; }

preask_body="$(sed -n '/^preask_prompts()/,/^}/p' "$HERE/install.sh")"
if printf '%s\n' "$preask_body" | grep -q 'preask_sudo'; then
  printf 'FAIL - immutable prompt flow still calls preask_sudo\n'; fail=1
else
  printf 'ok   - immutable prompt flow never calls preask_sudo\n'
fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
