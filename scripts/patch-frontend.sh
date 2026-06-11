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
# Remove the Millennium disclaimer modal trigger.
#
# This fork (lumen-beta) runs on Lumen, not Millennium — the modal warning
# users that "LuaTools is not affiliated with Millennium" / "you'll be banned
# from the Millennium Discord" no longer applies, so suppress it. We neutralize
# the TRIGGER (leaving showMillenniumDisclaimerModal defined but uncalled) so
# the anchor stays small and the modal never appears.
#
# Anchored: aborts loudly if the upstream trigger block moved.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'          // Show disclaimer after translations are loaded so it displays in the correct language\n'
'          try {\n'
'            if (window.location.hostname === "store.steampowered.com") {\n'
'              if (\n'
'                localStorage.getItem(\n'
'                  "luatools millennium disclaimer accepted",\n'
'                ) !== "1"\n'
'              ) {\n'
'                showMillenniumDisclaimerModal();\n'
'              }\n'
'            }\n'
'          } catch (_) {}\n'
)

replacement = (
'          // slsteammoon: Millennium disclaimer removed — this fork runs on\n'
'          // Lumen, not Millennium, so the affiliation/ban warning no longer\n'
'          // applies and the modal is not shown.\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] DISCLAIMER ANCHOR FAILED: found %d matches (need 1).\n"
        "The disclaimer trigger moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Millennium disclaimer modal trigger removed")
PY
