#!/usr/bin/env bash
# patch-frontend.sh <luatools.js>
#
# Adds a "Restart Steam" button to the "Game Added!" success modal.
#
# On Linux a freshly added game only shows up in the library after a
# Steam restart (slsteam-moon provisions it on the next launch via the
# PICS recv path — see SLSsteam-fork HANDOFF.md). The upstream modal
# only offers "Close", so users don't know they must restart. We add a
# FILLED (primary) "Restart Steam" button next to an UNFILLED "Close"
# so the restart reads as the intended next step, while Close stays
# available.
#
# The button reuses the plugin's existing RestartSteam server method
# (which, after our auto_update.lua patch, runs the wrapper-aware
# restart_steam.sh).
#
# Anchored: aborts loudly if the upstream modal markup moved.

set -euo pipefail

JS="${1:?usage: patch-frontend.sh <luatools.js>}"

# ProtonDB badge frontend (spliced into luatools.js below). Lives in the Linux
# overlay so the large JS block stays out of this script's shell/python heredocs.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTONDB_INC="$SCRIPT_DIR/../linux/frontend/protondb-indicator.js"

PYBIN="$(command -v python3 || true)"
if [[ -z "$PYBIN" ]]; then
  echo "[patch-frontend] python3 required" >&2
  exit 2
fi

"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

# Anchor: the "done" branch restyles the Hide button into a primary
# "Close". We replace that block so Close becomes secondary (unfilled)
# and a primary (filled) "Restart Steam" button is inserted before it.
anchor = (
'                // Update Hide button to styled Close\n'
'                const hideBtn = overlay.querySelector(".luatools-hide-btn");\n'
'                if (hideBtn) {\n'
'                  hideBtn.className = "luatools-btn primary luatools-hide-btn";\n'
'                  hideBtn.style.cssText =\n'
'                    "min-width:140px;display:flex;align-items:center;justify-content:center;text-align:center;";\n'
'                  hideBtn.innerHTML =\n'
'                    \'<i class="fa-solid fa-xmark" style="margin-right:6px;"></i><span>\' +\n'
'                    lt("Close") +\n'
'                    "</span>";\n'
'                }\n'
)

replacement = (
'                // Update Hide button to styled Close (UNFILLED, secondary).\n'
'                // slsteammoon: the FILLED button is "Restart Steam" so the\n'
'                // restart reads as the intended next step (a freshly added\n'
'                // game only appears after a Steam restart on Linux).\n'
'                const hideBtn = overlay.querySelector(".luatools-hide-btn");\n'
'                if (hideBtn) {\n'
'                  hideBtn.className = "luatools-btn luatools-hide-btn";\n'
'                  hideBtn.style.cssText =\n'
'                    "min-width:140px;display:flex;align-items:center;justify-content:center;text-align:center;";\n'
'                  hideBtn.innerHTML =\n'
'                    \'<i class="fa-solid fa-xmark" style="margin-right:6px;"></i><span>\' +\n'
'                    lt("Close") +\n'
'                    "</span>";\n'
'                  if (\n'
'                    hideBtn.parentElement &&\n'
'                    !overlay.querySelector(".luatools-restart-added-btn")\n'
'                  ) {\n'
'                    const restartBtn = document.createElement("a");\n'
'                    restartBtn.href = "#";\n'
'                    restartBtn.className =\n'
'                      "luatools-btn primary luatools-restart-added-btn";\n'
'                    restartBtn.style.cssText =\n'
'                      "min-width:140px;display:flex;align-items:center;justify-content:center;text-align:center;";\n'
'                    restartBtn.innerHTML =\n'
'                      \'<i class="fa-solid fa-rotate-right" style="margin-right:6px;"></i><span>\' +\n'
'                      lt("Restart Steam") +\n'
'                      "</span>";\n'
'                    restartBtn.addEventListener("click", function (e) {\n'
'                      e.preventDefault();\n'
'                      try {\n'
'                        restartBtn.style.pointerEvents = "none";\n'
'                        restartBtn.style.opacity = "0.6";\n'
'                        Millennium.callServerMethod("luatools", "RestartSteam", {\n'
'                          contentScriptQuery: "",\n'
'                        });\n'
'                      } catch (_) {}\n'
'                    });\n'
'                    // Order: Restart Steam (filled) -> Close (unfilled).\n'
'                    hideBtn.parentElement.insertBefore(restartBtn, hideBtn);\n'
'                  }\n'
'                }\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] ANCHOR FAILED: found %d matches (need 1).\n"
        "The 'Game Added' modal markup changed upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Restart Steam button injected into Game Added modal")
PY

# ---------------------------------------------------------------------------
# Route fast download through the smart source selector.
#
# Upstream's fast download picks available[0] (first by list order) and falls
# back serially. This fork replaces that with the backend smart race
# (StartAddViaLuaToolsSmart): parallel download of all available sources,
# pick the most complete of the fast ones. The backend handles fallback
# internally, so the JS onFailed callback becomes a no-op. The manual
# (fast-download-off) branch is left untouched.
#
# Anchored: aborts loudly if the upstream fast-download block moved.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'                    if (isFastDownload) {\n'
'                      // Fast download enabled, proceed automatically with the first available\n'
'                      const source = available[0];\n'
'                      backendLog(\n'
'                        "LuaTools: Auto-selecting source via fast download: " + source.name,\n'
'                      );\n'
'                      startDirectDownload(appid, available, 0);\n'
'                    } else {\n'
)

replacement = (
'                    if (isFastDownload) {\n'
'                      // slsteammoon: fast download runs the backend smart\n'
'                      // source selector (parallel race -> most complete of\n'
'                      // the fastest) instead of picking available[0] by order.\n'
'                      backendLog(\n'
'                        "LuaTools: fast download -> smart selection (" +\n'
'                          available.length + " available)",\n'
'                      );\n'
'                      runState.inProgress = true;\n'
'                      runState.appid = appid;\n'
'                      const smartOverlay = document.querySelector(".luatools-overlay");\n'
'                      if (smartOverlay) {\n'
'                        const st = smartOverlay.querySelector(".luatools-status");\n'
'                        if (st) st.textContent = lt("Initializing download...");\n'
'                        const pw = smartOverlay.querySelector(".luatools-progress-wrap");\n'
'                        if (pw) pw.style.display = "block";\n'
'                        const pi = smartOverlay.querySelector(".luatools-progress-info");\n'
'                        if (pi) pi.style.display = "block";\n'
'                        const cb = smartOverlay.querySelector(".luatools-cancel-btn");\n'
'                        if (cb) cb.style.display = "flex";\n'
'                      } else {\n'
'                        showTestPopup();\n'
'                      }\n'
'                      Millennium.callServerMethod("luatools", "StartAddViaLuaToolsSmart", {\n'
'                        appid,\n'
'                        contentScriptQuery: "",\n'
'                      });\n'
'                      startPolling(appid, function () {});\n'
'                    } else {\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] FAST-DOWNLOAD ANCHOR FAILED: found %d matches "
        "(need 1). The fast-download block moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] fast download routed through smart source selector")
PY

# ---------------------------------------------------------------------------
# ProtonDB compatibility badge.
#
# Adds a Steam-store-native badge (glowing tier medal + tier color) to the app
# page's button row, next to SteamDB/PCGamingWiki/the LuaTools button. Tier data
# comes from the Lua backend (GetProtonDBStatus), with a fast local DOM probe
# that short-circuits to "Native" for titles shipping a Linux build.
#
# Two anchored splices:
#   1. the badge function (linux/frontend/protondb-indicator.js) is inserted
#      into the IIFE scope, just before addLuaToolsButton (declarations hoist);
#   2. a call is added where the button row + resolved appid are in scope.
#
# Anchored: aborts loudly if either upstream anchor moved.
# ---------------------------------------------------------------------------
if [[ ! -f "$PROTONDB_INC" ]]; then
  echo "[patch-frontend] missing ProtonDB badge include at $PROTONDB_INC" >&2
  exit 2
fi

INC="$PROTONDB_INC" "$PYBIN" - "$JS" <<'PY'
import os, sys

path = sys.argv[1]
with open(os.environ["INC"], "r", encoding="utf-8") as f:
    fn = f.read()
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

# 1. Splice the badge function before addLuaToolsButton (same IIFE scope).
def_anchor = "  function addLuaToolsButton() {\n"
if s.count(def_anchor) != 1:
    sys.stderr.write(
        "[patch-frontend] PROTONDB DEF ANCHOR FAILED: found %d matches (need 1).\n"
        "addLuaToolsButton moved upstream; update scripts/patch-frontend.sh.\n"
        % s.count(def_anchor))
    sys.exit(3)
s = s.replace(def_anchor, fn.rstrip() + "\n\n" + def_anchor, 1)

# 2. Call the badge where the button row + a resolved appid are in scope.
call_anchor = (
'        if (!isNaN(appid)) {\n'
'          const pillBtn = steamdbContainer.querySelector(".luatools-button");\n'
)
if s.count(call_anchor) != 1:
    sys.stderr.write(
        "[patch-frontend] PROTONDB CALL ANCHOR FAILED: found %d matches (need 1).\n"
        "The status-pills block moved upstream; update scripts/patch-frontend.sh.\n"
        % s.count(call_anchor))
    sys.exit(3)
call_repl = (
'        if (!isNaN(appid)) {\n'
'          // slsteammoon: ProtonDB compatibility badge in the store button row.\n'
'          try { addLuaToolsProtonDBButton(appid, steamdbContainer); } catch (_) {}\n'
'          const pillBtn = steamdbContainer.querySelector(".luatools-button");\n'
)
s = s.replace(call_anchor, call_repl, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] ProtonDB compatibility badge injected")
PY
