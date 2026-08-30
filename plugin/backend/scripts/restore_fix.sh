#!/usr/bin/env bash
# Restore successful fix overlays in reverse application order.
set -u

unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

GAME_DIR="${1:-}"
BACKUP_ROOT="${2:-}"
[ -d "$GAME_DIR" ] || exit 1
[ -d "$BACKUP_ROOT" ] || exit 0

valid_rel() {
  local rel="$1"
  [ -n "$rel" ] || return 1
  case "$rel" in
    /*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

safe_parent() {
  local rel="$1" parent="${1%/*}" current="$GAME_DIR" segment
  [ "$parent" != "$rel" ] || return 0
  while [ -n "$parent" ]; do
    segment="${parent%%/*}"
    current="$current/$segment"
    [ ! -L "$current" ] || return 1
    [ ! -e "$current" ] || [ -d "$current" ] || return 1
    case "$parent" in */*) parent="${parent#*/}" ;; *) parent="" ;; esac
  done
  return 0
}

restore_transaction() {
  local transaction="$1" journal="$1/journal"
  [ -f "$journal" ] || return 1

  while IFS=$'\t' read -r action rel extra; do
    [ -z "${extra:-}" ] || return 1
    valid_rel "$rel" || return 1
    safe_parent "$rel" || return 1
    local target="$GAME_DIR/$rel"
    case "$action" in
      E)
        local backup="$transaction/files/$rel"
        [ -e "$backup" ] || [ -L "$backup" ] || return 1
        [ ! -d "$target" ] || [ -L "$target" ] || return 1
        mkdir -p "$(dirname "$target")" || return 1
        local temporary="${target}.tmp.luatools-restore.$$"
        rm -f "$temporary"
        cp -a -- "$backup" "$temporary" && mv -f -- "$temporary" "$target" \
          || { rm -f "$temporary"; return 1; }
        ;;
      N)
        [ ! -d "$target" ] || [ -L "$target" ] || return 1
        rm -f -- "$target" || return 1
        ;;
      D) ;;
      *) return 1 ;;
    esac
  done < "$journal"

  while IFS=$'\t' read -r action rel extra; do
    if [ "$action" = "D" ] && safe_parent "$rel"; then
      rmdir "$GAME_DIR/$rel" 2>/dev/null || true
    fi
  done < <(tac "$journal")

  rm -rf -- "$transaction"
}

while IFS= read -r transaction_name; do
  [ -n "$transaction_name" ] || continue
  restore_transaction "$BACKUP_ROOT/$transaction_name" || exit 1
done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name 'txn.*' -printf '%f\n' | sort -r)

rmdir "$BACKUP_ROOT" 2>/dev/null || true
exit 0
