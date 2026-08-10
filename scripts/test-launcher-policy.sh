#!/usr/bin/env bash
# Test-first coverage for installer launcher policy, privilege preflight,
# shutdown resolution, shim detection, and completion reporting.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SLSPLUGIN_LIB_ONLY=1
unset SLSM_SUDO_PRIMED SLSM_SUDO_DENIED
# shellcheck source=/dev/null
. "$HERE/install.sh" >/dev/null 2>&1

fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s (want [%s] got [%s])\n' "$1" "$2" "$3"
    fail=1
  fi
}

ORIGINAL_PATH="$PATH"
MUTABLE_OS="$TMP/mutable-os-release"
IMMUTABLE_OS="$TMP/immutable-os-release"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$MUTABLE_OS"
printf 'ID=steamos\nID_LIKE=arch\n' > "$IMMUTABLE_OS"

# --- Step 4.1: privilege preflight contract -------------------------------
check "preask_launcher_sudo exists" "yes" \
  "$(declare -F preask_launcher_sudo >/dev/null 2>&1 && echo yes || echo no)"

MAIN_LINE="$(grep -n '^main()' "$HERE/install.sh" | cut -d: -f1)"
PREASK_CALL_LINE="$(awk -v s="$MAIN_LINE" 'NR>=s && /preask_launcher_sudo[[:space:]]*$/{print NR; exit}' "$HERE/install.sh")"
STOP_CALL_LINE="$(awk -v s="$MAIN_LINE" 'NR>=s && /stop_steam[[:space:]]*$/{print NR; exit}' "$HERE/install.sh")"
CLEANUP_CALL_LINE="$(awk -v s="$MAIN_LINE" 'NR>=s && /cleanup_previous_install[[:space:]]*$/{print NR; exit}' "$HERE/install.sh")"
check "preflight call precedes stop_steam and cleanup" "yes" \
  "$([ -n "$PREASK_CALL_LINE" ] && [ -n "$STOP_CALL_LINE" ] && \
      [ -n "$CLEANUP_CALL_LINE" ] && [ "$PREASK_CALL_LINE" -lt "$STOP_CALL_LINE" ] && \
      [ "$PREASK_CALL_LINE" -lt "$CLEANUP_CALL_LINE" ] && echo yes || echo no)"

PREASK_BODY="$(sed -n '/^preask_launcher_sudo()/,/^}/p' "$HERE/install.sh")"
check "launcher preflight never calls fail" "yes" \
  "$(printf '%s\n' "$PREASK_BODY" | grep -qE '(^|[^[:alnum:]_])fail([[:space:]]|\()' && echo no || echo yes)"

SUDO_PREFIX_BODY="$(sed -n '/^sudo_prefix()/,/^}/p' "$HERE/install.sh")"
check "sudo_prefix does not emit sudo_hint" "yes" \
  "$(printf '%s\n' "$SUDO_PREFIX_BODY" | grep -q 'sudo_hint' && echo no || echo yes)"

# Fake sudo records every call and declines both non-interactive and tty
# credential attempts. A launcher privilege decline must remain warning-only.
mkdir -p "$TMP/sudo-bin" "$TMP/no-sudo-bin"
cat > "$TMP/sudo-bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_CALLS"
case "${1:-}" in
  -n) exit 1 ;;
  -v) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$TMP/sudo-bin/sudo"
ln -s "$(command -v id)" "$TMP/no-sudo-bin/id"
ln -s "$(command -v tr)" "$TMP/no-sudo-bin/tr"
: > "$TMP/fake-tty"

export SUDO_CALLS="$TMP/immutable-sudo.calls"
OS_RELEASE_FILE="$IMMUTABLE_OS" PATH="$TMP/sudo-bin:$ORIGINAL_PATH" \
  SLSM_SUDO_TTY="$TMP/fake-tty" \
  preask_launcher_sudo >/dev/null 2>&1 || immutable_preask_rc=$?
immutable_preask_rc="${immutable_preask_rc:-0}"
check "immutable preflight is a no-op" "0" "$immutable_preask_rc"
check "immutable preflight never calls sudo" "no" \
  "$([ -s "$TMP/immutable-sudo.calls" ] && echo yes || echo no)"

export SUDO_CALLS="$TMP/no-sudo.calls"
OS_RELEASE_FILE="$MUTABLE_OS" PATH="$TMP/no-sudo-bin" \
  SLSM_SUDO_TTY="$TMP/fake-tty" \
  preask_launcher_sudo >/dev/null 2>&1 || no_sudo_preask_rc=$?
no_sudo_preask_rc="${no_sudo_preask_rc:-0}"
check "missing sudo does not abort preflight" "0" "$no_sudo_preask_rc"
check "missing sudo makes no calls" "no" \
  "$([ -s "$TMP/no-sudo.calls" ] && echo yes || echo no)"

export SUDO_CALLS="$TMP/no-tty.calls"
OS_RELEASE_FILE="$MUTABLE_OS" PATH="$TMP/sudo-bin:$ORIGINAL_PATH" \
  SLSM_SUDO_TTY="$TMP/missing-tty" \
  preask_launcher_sudo >/dev/null 2>&1 || no_tty_preask_rc=$?
no_tty_preask_rc="${no_tty_preask_rc:-0}"
check "missing tty does not abort preflight" "0" "$no_tty_preask_rc"
check "missing tty makes no sudo calls" "no" \
  "$([ -s "$TMP/no-tty.calls" ] && echo yes || echo no)"

: > "$TMP/decline.calls"
export SUDO_CALLS="$TMP/decline.calls"
SLSM_SUDO_DENIED=0
OS_RELEASE_FILE="$MUTABLE_OS" PATH="$TMP/sudo-bin:$ORIGINAL_PATH" \
  SLSM_SUDO_TTY="$TMP/fake-tty" \
  preask_launcher_sudo >/dev/null 2>&1 || decline_preask_rc=$?
decline_preask_rc="${decline_preask_rc:-0}"
check "declining launcher privilege does not abort" "0" "$decline_preask_rc"
check "declining launcher privilege attempts validation" "yes" \
  "$(grep -q -- '-v' "$TMP/decline.calls" && echo yes || echo no)"
check "launcher privilege denial reaches child setup" "1:0" \
  "$(bash -c 'printf "%s:%s" "${SLSM_SUDO_DENIED:-0}" "${SLSM_SUDO_PRIMED:-0}"')"

SETUP_CAPTURE="$TMP/setup-child.capture"
SETUP_STUB="$TMP/setup-child.sh"
export SETUP_CAPTURE
cat > "$SETUP_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s:%s\n' "${SLSM_SUDO_DENIED:-unset}" "${SLSM_SUDO_PRIMED:-unset}" > "$SETUP_CAPTURE"
EOF
chmod 0755 "$SETUP_STUB"
resolve_component_asset() {
  RESOLVED_ASSET_URL='fixture://slsteam'
  RESOLVED_ASSET_INFO='{}'
  return 0
}
curl() { return 0; }
extract_zip() {
  mkdir -p "$2/fixture-root"
  cp "$SETUP_STUB" "$2/fixture-root/setup.sh"
}
seed_slsteam_config() { :; }
SLS_REPO=fixture SLS_BETA_PATH=fixture SLS_ASSET_GLOB=fixture \
  OPT_SLS_CHANNEL=stable install_slsteam_moon >/dev/null 2>&1 || true
check "actual setup handoff exports launcher privilege state" "1:0" \
  "$(cat "$SETUP_CAPTURE" 2>/dev/null || true)"

# --- Step 4.3: safe shutdown resolution -----------------------------------
SHUT_BIN="$TMP/shutdown-bin"
SHUT_SYSTEM="$TMP/shutdown-system"
mkdir -p "$SHUT_BIN" "$SHUT_SYSTEM"
SHUT_STATE="$TMP/steam-running"
SHUT_GRACEFUL="$TMP/graceful-shutdown"
SHUT_SHIM_CALLED="$TMP/shim-called"
SHUT_KILLS="$TMP/kills"
export SHUT_STATE SHUT_GRACEFUL SHUT_SHIM_CALLED SHUT_KILLS
for shutdown_tool in bash head grep sed readlink tr; do
  ln -s "$(command -v "$shutdown_tool")" "$SHUT_BIN/$shutdown_tool"
done

cat > "$SHUT_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
[ -e "$SHUT_STATE" ] && exit 0
exit 1
EOF
cat > "$SHUT_BIN/pkill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHUT_KILLS"
rm -f "$SHUT_STATE"
exit 0
EOF
cat > "$SHUT_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SHUT_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -k ]; then
  shift 3
else
  shift
fi
exec "$@"
EOF
chmod 0755 "$SHUT_BIN/pgrep" "$SHUT_BIN/pkill" "$SHUT_BIN/sleep" "$SHUT_BIN/timeout"

# Mirror the production layout: the captured original is `<mirror>/steam.orig`
# with a `steam` alias beside it. Valve's launcher aborts under any other
# argv[0], so `-shutdown` must be issued through that alias, never through the
# `.orig` path (see slsteam-moon/scripts/test-launcher-basename.sh).
SHUT_BACKUP_DIR="$TMP/shutdown-backup/usr/bin"
SHUT_BACKUP="$SHUT_BACKUP_DIR/steam.orig"
mkdir -p "$SHUT_BACKUP_DIR"
cat > "$SHUT_BACKUP" <<'EOF'
#!/usr/bin/env bash
case "${0##*/}" in
  steam|steambeta|bin_steam.sh) ;;
  *) printf "Unknown Steam package '%s'\n" "${0##*/}" >&2; exit 1 ;;
esac
printf 'graceful\n' > "$SHUT_GRACEFUL"
rm -f "$SHUT_STATE"
EOF
chmod 0755 "$SHUT_BACKUP"
ln -sfn steam.orig "$SHUT_BACKUP_DIR/steam"
cat > "$SHUT_SYSTEM/steam" <<EOF
#!/usr/bin/env bash
# slsteam-moon system launcher shim
SLSM_ORIG="$SHUT_BACKUP"
printf 'shim\n' > "$SHUT_SHIM_CALLED"
EOF
chmod 0755 "$SHUT_SYSTEM/steam"
touch "$SHUT_STATE"
PATH="$SHUT_BIN:$SHUT_SYSTEM" \
  stop_steam >/dev/null 2>&1
check "shutdown uses captured original behind shim" "yes" \
  "$([ -f "$SHUT_GRACEFUL" ] && echo yes || echo no)"
check "shutdown does not execute system shim" "no" \
  "$([ -f "$SHUT_SHIM_CALLED" ] && echo yes || echo no)"

# A symlink or alternate spelling of the injected wrapper must be rejected just
# like the canonical path, and a shim must not be allowed to name that wrapper
# as its captured original.
WRAP_HOME="$TMP/wrapper-home"
WRAP_DIR="$WRAP_HOME/.local/share/SLSsteam/path"
SHUT_ALIAS="$TMP/shutdown-alias"
mkdir -p "$WRAP_DIR" "$SHUT_ALIAS"
cat > "$WRAP_DIR/steam" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$WRAP_DIR/steam"
ln -s "$WRAP_DIR/steam" "$SHUT_ALIAS/steam"
check "wrapper symlink alias is not a shutdown launcher" "" \
  "$(HOME="$WRAP_HOME" PATH="$SHUT_BIN:$SHUT_ALIAS" \
      resolve_shutdown_launcher 2>/dev/null || true)"
SHUT_WRAPPER_SHIM="$TMP/shutdown-wrapper-original-shim"
cat > "$SHUT_WRAPPER_SHIM" <<EOF
#!/usr/bin/env bash
# slsteam-moon system launcher shim
SLSM_ORIG="$WRAP_DIR/steam"
EOF
chmod 0755 "$SHUT_WRAPPER_SHIM"
check "shim captured wrapper is not a safe native launcher" "no" \
  "$(HOME="$WRAP_HOME" is_safe_native_launcher "$SHUT_WRAPPER_SHIM" && echo yes || echo no)"

SHUT_SYSTEM_UNSAFE="$TMP/shutdown-unsafe-system"
mkdir -p "$SHUT_SYSTEM_UNSAFE"
cat > "$SHUT_SYSTEM_UNSAFE/steam" <<EOF
#!/usr/bin/env bash
# slsteam-moon system launcher shim
SLSM_ORIG="$TMP/missing-original"
printf 'unsafe-shim\n' > "$SHUT_SHIM_CALLED"
EOF
chmod 0755 "$SHUT_SYSTEM_UNSAFE/steam"
touch "$SHUT_STATE"
rm -f "$SHUT_GRACEFUL" "$SHUT_SHIM_CALLED" "$SHUT_KILLS"
PATH="$SHUT_BIN:$SHUT_SYSTEM_UNSAFE" \
  stop_steam >/dev/null 2>&1
check "unsafe shim skips graceful shutdown" "no" \
  "$([ -f "$SHUT_GRACEFUL" ] && echo yes || echo no)"
check "unsafe shim is not executed" "no" \
  "$([ -f "$SHUT_SHIM_CALLED" ] && echo yes || echo no)"
check "unsafe shutdown escalates through process control" "yes" \
  "$([ -s "$SHUT_KILLS" ] && echo yes || echo no)"

# --- Shim-aware native Steam detection ------------------------------------
DETECT_BIN="$TMP/detect-bin"
mkdir -p "$DETECT_BIN"
cat > "$DETECT_BIN/flatpak" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$DETECT_BIN/snap" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "$DETECT_BIN/flatpak" "$DETECT_BIN/snap"
DETECT_OS="$TMP/detect-os"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$DETECT_OS"
DETECT_SHIM="$TMP/detect-shim"
DETECT_VALID="$TMP/detect-valid-original"
cat > "$DETECT_SHIM" <<EOF
#!/usr/bin/env bash
# slsteam-moon system launcher shim
SLSM_ORIG="$TMP/missing-detect-original"
EOF
cat > "$DETECT_VALID" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$DETECT_SHIM" "$DETECT_VALID"
STEAM_FIXED_CANDIDATES="$DETECT_SHIM" STEAM_SEARCH_PATH="" \
  OS_RELEASE_FILE="$DETECT_OS" PATH="$DETECT_BIN:$ORIGINAL_PATH" \
  check_type_without_backup="$(detect_steam_type)"
check "lone shim without valid original is not native Steam" "none" "$check_type_without_backup"

DETECT_DIR_ORIGINAL="$TMP/detect-executable-dir"
mkdir -p "$DETECT_DIR_ORIGINAL"
chmod 0755 "$DETECT_DIR_ORIGINAL"
cat > "$DETECT_SHIM" <<EOF
#!/usr/bin/env bash
# slsteam-moon system launcher shim
SLSM_ORIG="$DETECT_DIR_ORIGINAL"
EOF
chmod 0755 "$DETECT_SHIM"
STEAM_FIXED_CANDIDATES="$DETECT_SHIM" STEAM_SEARCH_PATH="" \
  OS_RELEASE_FILE="$DETECT_OS" PATH="$DETECT_BIN:$ORIGINAL_PATH" \
  check_type_with_directory_backup="$(detect_steam_type)"
check "executable directory is not a native launcher backup" "none" "$check_type_with_directory_backup"

cat > "$DETECT_SHIM" <<EOF
#!/usr/bin/env bash
# slsteam-moon system launcher shim
SLSM_ORIG="$DETECT_VALID"
EOF
chmod 0755 "$DETECT_SHIM"
STEAM_FIXED_CANDIDATES="$DETECT_SHIM" STEAM_SEARCH_PATH="" \
  OS_RELEASE_FILE="$DETECT_OS" PATH="$DETECT_BIN:$ORIGINAL_PATH" \
  check_type_with_backup="$(detect_steam_type)"
check "shim with valid captured original remains native" "native" "$check_type_with_backup"

# --- Effective policy and completion report --------------------------------
STATE_HOME="$TMP/state"
mkdir -p "$STATE_HOME/slsteam-moon"
XDG_STATE_HOME="$STATE_HOME"
SLSM_COVERAGE_POLICY=""
printf 'launcher\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
check "installed policy reads launcher" "launcher" "$(installed_coverage_policy 2>/dev/null || true)"
REL_STATE_HOME="$TMP/relative-state-home"
mkdir -p "$REL_STATE_HOME/.local/state/slsteam-moon"
printf 'launcher\n' > "$REL_STATE_HOME/.local/state/slsteam-moon/coverage.policy"
check "relative XDG state falls back to HOME state" "launcher" \
  "$(HOME="$REL_STATE_HOME" XDG_STATE_HOME=relative SLSM_COVERAGE_POLICY= \
      installed_coverage_policy 2>/dev/null || true)"
printf 'invalid\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
check "invalid policy falls back to desktop" "desktop" "$(installed_coverage_policy 2>/dev/null || true)"
printf 'launcher\nunexpected-content\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
check "multi-line policy falls back to desktop" "desktop" "$(installed_coverage_policy 2>/dev/null || true)"
printf 'launcher\n\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
check "trailing blank policy falls back to desktop" "desktop" "$(installed_coverage_policy 2>/dev/null || true)"
rm -f "$STATE_HOME/slsteam-moon/coverage.policy"
check "missing policy falls back to desktop" "desktop" "$(installed_coverage_policy 2>/dev/null || true)"
STATUS_HOME="$TMP/status-home"
mkdir -p "$STATUS_HOME/.local/share/SLSsteam" "$STATE_HOME/slsteam-moon"
printf 'launcher\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
printf 'desktop\n' > "$STATUS_HOME/.local/share/SLSsteam/coverage-policy.effective"
check "desktop fallback marker overrides stale launcher policy" "desktop" \
  "$(HOME="$STATUS_HOME" XDG_STATE_HOME="$STATE_HOME" SLSM_COVERAGE_POLICY= \
      installed_coverage_policy 2>/dev/null || true)"
rm -f "$STATUS_HOME/.local/share/SLSsteam/coverage-policy.effective"
printf 'launcher\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
OPT_NOPLUGIN=1
CR_SO_PATH="$TMP/no-cloudredirect"
LANG_IS_PT=0
BOLD="" NC="" GREEN="" MOON="" NIGHT=""
completion_launcher="$(print_complete)"
check "completion reports launcher policy" "yes" \
  "$(printf '%s\n' "$completion_launcher" | grep -qi 'coverage.*launcher' && echo yes || echo no)"
printf 'desktop\n' > "$STATE_HOME/slsteam-moon/coverage.policy"
completion_desktop="$(print_complete)"
check "completion reports desktop policy" "yes" \
  "$(printf '%s\n' "$completion_desktop" | grep -qi 'coverage.*desktop' && echo yes || echo no)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
