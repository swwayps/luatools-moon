#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND="$ROOT/plugin/public/luatools.js"

guard_line="$(grep -nF 'if (window.__LuaToolsInjected) return;' "$FRONTEND" | cut -d: -f1 || true)"
marker_line="$(grep -nF 'window.__LuaToolsInjected = true;' "$FRONTEND" | cut -d: -f1 || true)"
first_setup_line="$(grep -nF 'const gamepadCSS = document.createElement("style");' "$FRONTEND" | cut -d: -f1)"

[[ -n "$guard_line" && -n "$marker_line" ]] || {
  echo "frontend must guard against repeated injection" >&2
  exit 1
}

(( guard_line < first_setup_line && marker_line < first_setup_line )) || {
  echo "reinjection guard must run before frontend setup" >&2
  exit 1
}

echo "ok - frontend ignores repeated injection"
