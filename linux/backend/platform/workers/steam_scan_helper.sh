#!/usr/bin/env bash
# steam_scan_helper.sh — Linux port of upstream
# backend/steam_scan_helper.ps1.
#
# Synchronous helper. The Lua frontend writes a request to one of
# `--action <name>` and polls `--output-path` for a JSON reply.
# Implements the three actions main.lua cares about:
#
#   GetInstalledLuaScripts
#     Enumerate <steam-path>/config/stplug-in/*.lua{,.disabled} and
#     return [{ "appid": N, "name": "...", "enabled": bool }].
#
#   GetGameInstallPath
#     Read <steam-path>/steamapps/appmanifest_<appid>.acf, look up
#     "installdir", and return { "appid": N, "installPath": "..." }.
#     The path is composed against the libraryfolders.vdf entry
#     hosting that appid (multiple library roots).
#
#   GetInstalledFixes
#     Stubbed for now — the fix-history directory layout has to be
#     finalised on Linux first (see fix_worker.sh). Returns an empty
#     list so the UI doesn't error.
#
# Output is a single JSON object written atomically via a temp file
# rename so the polling Lua side never reads a half-written file.

set -u

# ADAPT-LINUX: clear Steam-runtime env vars (see download_worker.sh).
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

ACTION=""
PLUGIN_ROOT=""
STEAM_PATH=""
APP_ID=""
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    --steam-path) STEAM_PATH="$2"; shift 2 ;;
    --app-id) APP_ID="$2"; shift 2 ;;
    --output-path) OUTPUT_PATH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

write_atomic() {
  # $1 = body; writes to a sibling .tmp and renames.
  local body="$1"
  local tmp="${OUTPUT_PATH}.tmp.$$"
  printf '%s' "$body" > "$tmp"
  mv -f "$tmp" "$OUTPUT_PATH"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

case "$ACTION" in
  GetInstalledLuaScripts)
    DIR="$STEAM_PATH/config/stplug-in"
    items=()
    if [[ -d "$DIR" ]]; then
      while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        name="$(basename "$path")"
        enabled="true"
        appid="${name%.lua}"
        if [[ "$name" == *.lua.disabled ]]; then
          enabled="false"
          appid="${name%.lua.disabled}"
        fi
        # Skip non-numeric (helper scripts).
        if [[ ! "$appid" =~ ^[0-9]+$ ]]; then continue; fi
        items+=("{\"appid\":${appid},\"name\":\"$(json_escape "$name")\",\"enabled\":${enabled}}")
      done < <(find "$DIR" -maxdepth 1 -type f \( -iname '*.lua' -o -iname '*.lua.disabled' \) 2>/dev/null)
    fi
    body="{\"success\":true,\"scripts\":[$(IFS=,; echo "${items[*]}")]}"
    write_atomic "$body"
    ;;

  GetGameInstallPath)
    if [[ -z "$APP_ID" || ! "$APP_ID" =~ ^[0-9]+$ ]]; then
      write_atomic '{"success":false,"error":"Invalid appid"}'
      exit 0
    fi
    install_path=""

    # Discover all library roots from libraryfolders.vdf (each "path"
    # entry). The default Steam install is itself a library root.
    libroots=("$STEAM_PATH/steamapps")
    LIBVDF="$STEAM_PATH/steamapps/libraryfolders.vdf"
    if [[ -f "$LIBVDF" ]]; then
      while IFS= read -r p; do
        [[ -n "$p" ]] && libroots+=("$p/steamapps")
      done < <(grep -oE '"path"[[:space:]]*"[^"]+"' "$LIBVDF" | sed -E 's/.*"path"[[:space:]]*"([^"]+)".*/\1/')
    fi

    for lib in "${libroots[@]}"; do
      acf="${lib}/appmanifest_${APP_ID}.acf"
      if [[ -f "$acf" ]]; then
        installdir=$(grep -oE '"installdir"[[:space:]]*"[^"]+"' "$acf" | head -n1 | sed -E 's/.*"installdir"[[:space:]]*"([^"]+)".*/\1/')
        if [[ -n "$installdir" ]]; then
          install_path="${lib}/common/${installdir}"
          break
        fi
      fi
    done

    if [[ -z "$install_path" ]]; then
      write_atomic "{\"success\":false,\"error\":\"App ${APP_ID} not installed\"}"
    else
      write_atomic "{\"success\":true,\"appid\":${APP_ID},\"installPath\":\"$(json_escape "$install_path")\"}"
    fi
    ;;

  GetInstalledFixes)
    # Stub: see fix_worker.sh — fix history layout TBD.
    write_atomic '{"success":true,"fixes":[]}'
    ;;

  *)
    write_atomic "{\"success\":false,\"error\":\"Unknown action: $(json_escape "$ACTION")\"}"
    ;;
esac
exit 0
