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

# ---------------------------------------------------------------------------
# SpaceFix: repurpose the "All-In-One Fixes" button.
#
# On Windows the AIO fix downloads the Unsteam emulator (winmm.dll proxy +
# unsteam.dll, unsteam.ini with fake_app_id=480) into the game folder. Under
# Proton those Windows DLLs are ignored (Wine loads its builtins), so the fix
# does nothing. The native Linux equivalent is slsteam-moon's FakeAppIds map:
# mapping the game to 480 makes it report as Spacewar on the real client layer
# (matchmaking/presence/tickets). So the AIO button now calls ApplySpaceFix
# (which writes FakeAppIds { appid: 480 }) instead of downloading/extracting,
# keeps the visible title "All-In-One Fixes", and gets a short description.
#
# Anchored on the aioSection createFixButton block; aborts if it moved.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = r'''    const aioSection = createFixButton(
      lt("All-In-One Fixes"),
      lt("Online Fix (Unsteam)"),
      "fa-globe",
      null, // default blue button
      function (e) {
        e.preventDefault();
        if (isGameInstalled) {
          const downloadUrl =
            "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/Win64.zip";
          applyFix(
            data.appid,
            downloadUrl,
            lt("Online Fix (Unsteam)"),
            data.gameName,
            overlay,
          );
        }
      },
    );'''

replacement = r'''    const aioSection = createFixButton(
      lt("All-In-One Fixes"),
      lt("Fixes online play in some games by simulating Spacewar"),
      "fa-globe",
      null, // default blue button
      function (e) {
        e.preventDefault();
        if (!isGameInstalled) return;
        // slsteammoon: enable slsteam-moon's native FakeAppIds (-> Spacewar
        // 480) instead of dropping the Windows Unsteam DLLs Proton ignores.
        try {
          overlay.remove();
        } catch (_) {}
        try {
          Millennium.callServerMethod("luatools", "ApplySpaceFix", {
            appid: data.appid,
            contentScriptQuery: "",
          })
            .then(function (res) {
              const payload = typeof res === "string" ? JSON.parse(res) : res;
              if (payload && payload.success) {
                ShowLuaToolsAlert(
                  "LuaTools",
                  lt("SpaceFix enabled — (re)launch the game to apply it."),
                );
              } else {
                const emsg =
                  payload && payload.error
                    ? String(payload.error)
                    : lt("Error applying fix");
                ShowLuaToolsAlert("LuaTools", emsg);
              }
            })
            .catch(function (err) {
              backendLog("LuaTools: ApplySpaceFix error: " + err);
              ShowLuaToolsAlert("LuaTools", lt("Error applying fix"));
            });
        } catch (err) {
          backendLog("LuaTools: ApplySpaceFix call error: " + err);
        }
      },
    );'''

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] SPACEFIX AIO ANCHOR FAILED: found %d matches "
        "(need 1). The aioSection block moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] AIO button repurposed to SpaceFix (FakeAppIds)")
PY

# ---------------------------------------------------------------------------
# Manage Game / Un-Fix: drop the steam://validate navigation (Linux line).
#
# UnFixGame on Linux only removes the FakeAppIds mapping (SpaceFix off); no
# game files are touched, so a full Steam verify is pointless and could
# re-trigger staging for an added (unowned) game. Neutralize only the
# showUnfixProgress site (the Manage Game flow); the settings InstalledFixes
# flow is unrelated and left as-is.
#
# Anchored on the "done"-branch validate block (unique via "Stop polling").
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'                // Trigger Steam verification after a short delay\n'
'                setTimeout(function () {\n'
'                  try {\n'
'                    const verifyUrl = "steam://validate/" + appid;\n'
'                    window.location.href = verifyUrl;\n'
'                    backendLog("LuaTools: Running verify for appid " + appid);\n'
'                  } catch (_) {}\n'
'                }, 1000);\n'
'\n'
'                return; // Stop polling\n'
)

replacement = (
'                // slsteammoon: no steam://validate on Linux — Un-Fix only\n'
'                // toggles slsteam-moon\'s FakeAppIds (SpaceFix off); no game\n'
'                // files change, so a full verify is unnecessary and could\n'
'                // re-trigger staging for an added game.\n'
'\n'
'                return; // Stop polling\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] UNFIX VALIDATE ANCHOR FAILED: found %d matches "
        "(need 1). The showUnfixProgress done-branch moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Un-Fix steam://validate navigation removed (Linux)")
PY

# ---------------------------------------------------------------------------
# Manage Game / Un-Fix: confirm copy. The upstream text promises to "remove
# fix files and verify game files", which no longer matches the Linux
# behavior (Un-Fix just turns SpaceFix off — no files removed, no verify).
# Rewrite it to be coherent. Anchored on the confirm string literal.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'              "Are you sure you want to un-fix? This will remove fix files and verify game files.",\n'
)
replacement = (
'              "Are you sure you want to un-fix? This turns off the SpaceFix for this game.",\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] UNFIX CONFIRM ANCHOR FAILED: found %d matches "
        "(need 1). The un-fix confirm string moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Un-Fix confirm copy updated for SpaceFix")
PY

# ---------------------------------------------------------------------------
# Manage Game / Un-Fix: done-branch message. After dropping the
# steam://validate step (above), the upstream "done" message still read
# "Removed {count} files. Running Steam verification..." — a step that no
# longer runs, so the modal looked hung (and "0 files" is misleading, since
# Un-Fix removes the FakeAppIds mapping, not files). Replace it with a clear
# completion message. The Hide button (overlay.remove()) still dismisses it.
#
# Anchored on the showUnfixProgress done-branch message block.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'                const filesRemoved = state.filesRemoved || 0;\n'
'                if (msgEl)\n'
'                  msgEl.textContent = lt(\n'
'                    "Removed {count} files. Running Steam verification...",\n'
'                  ).replace("{count}", filesRemoved);\n'
)
replacement = (
'                if (msgEl)\n'
'                  msgEl.textContent = lt(\n'
'                    "SpaceFix removed. Relaunch the game to apply.",\n'
'                  );\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] UNFIX DONE-MSG ANCHOR FAILED: found %d matches "
        "(need 1). The showUnfixProgress done-branch moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Un-Fix done-branch message updated for SpaceFix")
PY

# ---------------------------------------------------------------------------
# Online Fix button -> perondepot mirror.
#
# Upstream gates "Online Fix" on the luatools fixes index (rate-limited to
# HTTP 429), so it almost always shows "No online-fix". Source it from the
# perondepot online-fix mirror instead: enable it whenever the game is
# installed, resolve the .rar by the store-page game name (ResolveOnlineFix),
# then run the normal download/extract/apply flow. The on-"done" WINEDLLOVERRIDES
# wiring (separate patch below) makes Proton load the fix DLLs.
#
# Anchored on the onlineSection createFixButton block.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = r'''    const onlineStatus = data.onlineFix.status;
    const onlineSection = createFixButton(
      lt("Online Fix"),
      onlineStatus === 200 ? lt("Apply") : lt("No online-fix"),
      onlineStatus === 200 ? "fa-check" : "fa-circle-xmark",
      onlineStatus === 200 ? true : false,
      function (e) {
        e.preventDefault();
        if (onlineStatus === 200 && isGameInstalled) {
          const onlineUrl =
            data.onlineFix.url ||
            "https://files.luatools.work/OnlineFix1/" + data.appid + ".zip";
          applyFix(
            data.appid,
            onlineUrl,
            lt("Online Fix"),
            data.gameName,
            overlay,
          );
        }
      },
    );
    columnsContainer.appendChild(onlineSection);

    if (!isGameInstalled) {
      onlineSection.style.opacity = "0.5";
      onlineSection.style.cursor = "not-allowed";
    }'''

replacement = r'''    // slsteammoon: source Online Fix from the perondepot mirror (the luatools
    // index is rate-limited). Always available when installed; resolved by
    // game name on click.
    const onlineSection = createFixButton(
      lt("Online Fix"),
      lt("Multiplayer fix via the online-fix mirror"),
      "fa-globe",
      null,
      function (e) {
        e.preventDefault();
        if (!isGameInstalled) return;
        if (!window.__LuaToolsGameInstallPath) {
          ShowLuaToolsAlert("LuaTools", lt("Game install path not found"));
          return;
        }
        try {
          overlay.remove();
        } catch (_) {}
        // slsteammoon: lightweight loading indicator while we resolve the fix
        // (fetching + matching the mirror index takes a moment).
        var __ofLoad = document.createElement("div");
        __ofLoad.className = "luatools-overlay";
        __ofLoad.style.cssText =
          "position:fixed;inset:0;background:rgba(0,0,0,0.8);backdrop-filter:blur(12px);z-index:99999;display:flex;align-items:center;justify-content:center;";
        var __ofColors = getThemeColors();
        __ofLoad.innerHTML =
          '<div style="background:' + __ofColors.modalBg + ';color:' + __ofColors.text +
          ';border:1px solid ' + __ofColors.border +
          ';border-radius:16px;padding:24px 30px;font-size:15px;display:flex;align-items:center;gap:12px;">' +
          '<i class="fa-solid fa-spinner fa-spin"></i><span>' +
          lt("Looking for an online fix…") + "</span></div>";
        document.body.appendChild(__ofLoad);
        var __ofClose = function () { try { __ofLoad.remove(); } catch (_) {} };
        Millennium.callServerMethod("luatools", "ResolveOnlineFix", {
          appid: data.appid,
          gameName: data.gameName || "",
          contentScriptQuery: "",
        })
          .then(function (res) {
            __ofClose();
            const payload = typeof res === "string" ? JSON.parse(res) : res;
            if (payload && payload.success && payload.found && payload.url) {
              applyFix(data.appid, payload.url, lt("Online Fix"), data.gameName, null);
            } else if (payload && payload.success && !payload.found) {
              ShowLuaToolsAlert(
                "LuaTools",
                lt("No online fix found for this game."),
              );
            } else {
              const e2 =
                payload && payload.error
                  ? String(payload.error)
                  : lt("Error starting Online Fix");
              ShowLuaToolsAlert("LuaTools", e2);
            }
          })
          .catch(function (err) {
            __ofClose();
            backendLog("LuaTools: ResolveOnlineFix error: " + err);
            ShowLuaToolsAlert("LuaTools", lt("Error starting Online Fix"));
          });
      },
    );
    columnsContainer.appendChild(onlineSection);

    if (!isGameInstalled) {
      onlineSection.style.opacity = "0.5";
      onlineSection.style.cursor = "not-allowed";
    }'''

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] ONLINE-FIX ANCHOR FAILED: found %d matches (need 1). "
        "The onlineSection block moved upstream; update patch-frontend.sh.\n" % n)
    sys.exit(3)
s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Online Fix button routed to perondepot mirror")
PY

# ---------------------------------------------------------------------------
# WINEDLLOVERRIDES on fix apply. After any online/generic fix finishes, read
# the app's live launch options + compat tool from Steam, ask the backend
# (GetFixLaunchOptions) to merge in a WINEDLLOVERRIDES for the fix's DLLs, and
# set it live so Proton loads the native fix DLLs (it ignores them otherwise).
# Proton-gated + idempotent (logic in fix_overlays.lua).
#
# Two anchored splices: the helper before pollFixProgress, and a call on the
# pollFixProgress "done" branch.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

# 1. Call applyLuaToolsFixOverrides on the apply-fix "done" branch.
call_anchor = (
'              } else if (state.status === "done") {\n'
'                if (msgEl)\n'
'                  msgEl.textContent = lt("{fix} applied successfully!").replace(\n'
'                    "{fix}",\n'
'                    fixType,\n'
'                  );\n'
'                replaceFixButtonsWithClose(overlayEl);\n'
)
call_repl = (
'              } else if (state.status === "done") {\n'
'                if (msgEl)\n'
'                  msgEl.textContent = lt("{fix} applied successfully!").replace(\n'
'                    "{fix}",\n'
'                    fixType,\n'
'                  );\n'
'                // slsteammoon: force the fix DLLs to load under Proton via a\n'
'                // WINEDLLOVERRIDES launch option (best-effort auto-set, plus\n'
'                // show the line to paste — SteamClient.Apps is absent on the\n'
'                // store-page context).\n'
'                try { applyLuaToolsFixOverrides(appid, overlayEl); } catch (_) {}\n'
'                replaceFixButtonsWithClose(overlayEl);\n'
)
if s.count(call_anchor) != 1:
    sys.stderr.write(
        "[patch-frontend] FIX-OVERRIDE CALL ANCHOR FAILED: found %d matches "
        "(need 1). pollFixProgress done-branch moved; update patch-frontend.sh.\n"
        % s.count(call_anchor))
    sys.exit(3)
s = s.replace(call_anchor, call_repl, 1)

# 2. Define the helper just before pollFixProgress (declarations hoist).
helper_anchor = '  function pollFixProgress(appid, fixType) {\n'
helper = (
'  // slsteammoon: after a fix, get the WINEDLLOVERRIDES launch option from the\n'
'  // backend and show it for the user to paste into Properties -> Launch\n'
'  // Options (SteamClient.Apps is absent on the store-page context, so we\n'
'  // cannot set it programmatically there; we still try best-effort).\n'
'  function applyLuaToolsFixOverrides(appid, overlayEl) {\n'
'    try {\n'
'      var installPath = window.__LuaToolsGameInstallPath || "";\n'
'      Millennium.callServerMethod("luatools", "GetFixLaunchOptions", {\n'
'        appid: Number(appid),\n'
'        compatToolName: "",\n'
'        currentLaunchOptions: "",\n'
'        installPath: installPath,\n'
'        contentScriptQuery: "",\n'
'      })\n'
'        .then(function (res) {\n'
'          var payload = typeof res === "string" ? JSON.parse(res) : res;\n'
'          if (!(payload && payload.success && payload.apply && payload.launchOptions)) {\n'
'            backendLog("LuaTools: GetFixLaunchOptions apply=false (no fix DLLs?)");\n'
'            return;\n'
'          }\n'
'          var opts = String(payload.launchOptions);\n'
'          // Best-effort auto-set where the API exists (non-store contexts).\n'
'          try {\n'
'            if (typeof SteamClient !== "undefined" && SteamClient.Apps &&\n'
'                typeof SteamClient.Apps.SetAppLaunchOptions === "function") {\n'
'              SteamClient.Apps.SetAppLaunchOptions(Number(appid), opts);\n'
'              backendLog("LuaTools: auto-set WINEDLLOVERRIDES for " + appid);\n'
'            }\n'
'          } catch (_) {}\n'
'          // Always show the line to paste.\n'
'          try { showLuaToolsLaunchOptionHint(overlayEl, opts); } catch (e) {\n'
'            backendLog("LuaTools: launch-option hint error: " + e);\n'
'          }\n'
'        })\n'
'        .catch(function (e) {\n'
'          backendLog("LuaTools: GetFixLaunchOptions error: " + e);\n'
'        });\n'
'    } catch (e) {\n'
'      backendLog("LuaTools: applyLuaToolsFixOverrides error: " + e);\n'
'    }\n'
'  }\n'
'\n'
'  // Render the launch-option tutorial into the fix modal: rewrite the body\n'
'  // into a short step-by-step, place the copyable line in the MIDDLE, and\n'
'  // gate the Close button until the user presses Copy (so they leave with\n'
'  // the line in hand). Layout order: message -> copy row -> Close.\n'
'  function showLuaToolsLaunchOptionHint(overlayEl, opts) {\n'
'    if (!overlayEl) { ShowLuaToolsAlert("LuaTools", opts); return; }\n'
'    var modal = overlayEl.firstElementChild;\n'
'    if (!modal) return;\n'
'    if (modal.querySelector(".luatools-lo-hint")) return;\n'
'    var c = getThemeColors();\n'
'    // 1. Rewrite the body into a short tutorial.\n'
'    var msgEl = modal.querySelector("#lt-fix-progress-msg");\n'
'    if (msgEl) {\n'
'      msgEl.innerHTML =\n'
'        \'<div style="font-weight:600;color:\' + c.text + \';margin-bottom:10px;">\' +\n'
'        lt("Online Fix downloaded \\u2014 one more step to enable it:") + "</div>" +\n'
'        \'<div style="color:\' + c.textSecondary + \';line-height:1.6;">\' +\n'
'        lt("In your library, right-click the game and open Properties \\u2192 General, then paste the line below into Launch Options.") +\n'
'        "</div>" +\n'
'        \'<div style="color:#ffb84d;font-weight:600;margin-top:10px;">\' +\n'
'        lt("The online fix will not work until you do this.") + "</div>";\n'
'    }\n'
'    // 2. Copy row (line + Copy button), placed between the message and Close.\n'
'    var box = document.createElement("div");\n'
'    box.className = "luatools-lo-hint";\n'
'    box.style.cssText =\n'
'      "margin:0 0 20px 0;display:flex;gap:8px;align-items:stretch;";\n'
'    var inp = document.createElement("input");\n'
'    inp.readOnly = true; inp.value = opts;\n'
'    inp.style.cssText =\n'
'      "flex:1;min-width:0;background:rgba(0,0,0,0.35);color:" + c.text +\n'
'      ";border:1px solid " + c.border +\n'
'      ";border-radius:6px;padding:10px 12px;font-family:monospace;font-size:12px;";\n'
'    inp.addEventListener("focus", function () { this.select(); });\n'
'    inp.addEventListener("click", function () { this.select(); });\n'
'    var copyBtn = document.createElement("a");\n'
'    copyBtn.href = "#"; copyBtn.className = "luatools-btn primary";\n'
'    copyBtn.style.cssText = "min-width:110px;display:flex;align-items:center;justify-content:center;";\n'
'    copyBtn.innerHTML = "<span>" + lt("Copy") + "</span>";\n'
'    // 3. Gate Close until Copy is pressed.\n'
'    var btnRow = modal.querySelector(".lt-fix-btn-row");\n'
'    var closeBtn = btnRow ? btnRow.querySelector(".luatools-btn") : null;\n'
'    if (closeBtn) {\n'
'      closeBtn.style.pointerEvents = "none";\n'
'      closeBtn.style.opacity = "0.45";\n'
'      closeBtn.title = lt("Copy the line first");\n'
'    }\n'
'    copyBtn.onclick = function (e) {\n'
'      e.preventDefault();\n'
'      try { inp.focus(); inp.select(); } catch (_) {}\n'
'      try { document.execCommand("copy"); } catch (_) {}\n'
'      try {\n'
'        if (navigator.clipboard && navigator.clipboard.writeText) {\n'
'          navigator.clipboard.writeText(opts);\n'
'        }\n'
'      } catch (_) {}\n'
'      copyBtn.innerHTML = "<span>" + lt("Copied!") + "</span>";\n'
'      if (closeBtn) {\n'
'        closeBtn.style.pointerEvents = "";\n'
'        closeBtn.style.opacity = "";\n'
'        closeBtn.title = "";\n'
'      }\n'
'    };\n'
'    box.appendChild(inp); box.appendChild(copyBtn);\n'
'    if (btnRow && btnRow.parentElement === modal) {\n'
'      modal.insertBefore(box, btnRow);\n'
'    } else {\n'
'      modal.appendChild(box);\n'
'    }\n'
'  }\n'
'\n'
)
if s.count(helper_anchor) != 1:
    sys.stderr.write(
        "[patch-frontend] FIX-OVERRIDE HELPER ANCHOR FAILED: found %d matches "
        "(need 1). pollFixProgress decl moved; update patch-frontend.sh.\n"
        % s.count(helper_anchor))
    sys.exit(3)
s = s.replace(helper_anchor, helper + helper_anchor, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] WINEDLLOVERRIDES on-fix-apply wiring injected")
PY
