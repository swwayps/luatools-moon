#!/usr/bin/env bash
# patch-frontend.sh <luatools.js>
#
# Adds a "Restart Steam" button to the "Game Added!" success modal.
#
# On Linux a freshly added game only shows up in the library after a
# Steam restart (slsteam-moon provisions it on the next launch via the
# PICS recv path). The upstream modal
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
# Morrenus key status: show the REAL problem, not always "Invalid or rejected".
#
# The backend (GetMorrenusStats, patched in build.sh) now returns a structured
# errorType: "rejected" only on a 401/403 (the server actively refused the
# key), "unreachable" when the validation request got no usable answer
# (offline, DNS/TLS, server down/busy, Cloudflare block). Upstream's UI shows
# one red "Invalid or rejected key" for every failure, which misleads a user
# whose key is fine but whose network can't reach hubcapmanifest.com. Branch on
# errorType: keep the red rejection message only for an actual rejection, and
# show a distinct amber connectivity message otherwise.
#
# Anchored: aborts loudly if the upstream stats-error block moved.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'                      } else {\n'
'                        statsDiv.innerHTML =\n'
'                          "<span style=\'color:#ff5c5c;\'>" +\n'
'                          lt("Invalid or rejected key") +\n'
'                          "</span>";\n'
'                      }\n'
)

replacement = (
'                      } else if (res && res.errorType === "rejected") {\n'
'                        statsDiv.innerHTML =\n'
'                          "<span style=\'color:#ff5c5c;\'>" +\n'
'                          lt("Invalid or rejected key") +\n'
'                          (res.status ? \' (HTTP "\' + res.status + \'")\' : "") +\n'
'                          "</span>";\n'
'                      } else {\n'
'                        // slsteammoon: not a rejection — the request never got\n'
'                        // a usable answer (offline, DNS/TLS, server down/busy).\n'
'                        // Show the real problem (amber) + the HTTP code if any.\n'
'                        statsDiv.innerHTML =\n'
'                          "<span style=\'color:#f0ad4e;\'>" +\n'
'                          lt("Couldn\'t reach the key server. Check your connection.") +\n'
'                          (res && res.status ? \' (HTTP "\' + res.status + \'")\' : "") +\n'
'                          "</span>";\n'
'                      }\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] MORRENUS STATS ANCHOR FAILED: found %d matches (need 1).\n"
        "The Morrenus key-status block moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)

s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Morrenus key-status message split (rejected vs unreachable)")
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
# Manage Game / Un-Fix: the upstream steam://validate navigation is KEPT
# (no patch here). Un-Fix now restores the game to its original state, and
# the file-based fixes (Crack/Bypass, Online Fix) DO modify game files, so a
# Steam verify is the mechanism that restores them. (SpaceFix/FakeAppIds
# changes no files; that part is handled by UnFixGame dropping the mapping.)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Manage Game / Un-Fix: confirm copy. Reworded for the Linux Un-Fix, which
# now restores the game to its original state (drops the SpaceFix/FakeAppIds
# mapping AND verifies game files to undo the file-based Crack/Online fixes).
# Anchored on the confirm string literal.
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
'              "Are you sure you want to un-fix? This removes any applied fixes and restores the game to its original state.",\n'
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
print("[patch-frontend] Un-Fix confirm copy updated for restore-original-state")
PY

# ---------------------------------------------------------------------------
# Manage Game / Un-Fix: done-branch message. The upstream message read
# "Removed {count} files. Running Steam verification..." but the backend
# UnFixGame doesn't report a count (it drops the FakeAppIds mapping), so it
# showed a misleading "0 files". Replace it with a clear status; the
# upstream steam://validate that follows is KEPT (it restores the original
# game files modified by the file-based fixes).
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
'                    "Restoring the game to its original state\\u2026",\n'
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
print("[patch-frontend] Un-Fix done-branch message updated for restore-original-state")
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
      lt("Multiplayer fix via peron online-fix.me mirror"),
      "fa-globe",
      null,
      function (e) {
        e.preventDefault();
        if (!isGameInstalled) return;
        if (!window.__LuaToolsGameInstallPath) {
          ShowLuaToolsAlert("LuaTools", lt("Game install path not found"));
          return;
        }
        // slsteammoon: an online fix is a bundle of Windows DLLs that only
        // loads under Proton/Wine. A title that ships a native Linux build runs
        // WITHOUT Proton by default, so the fix would do nothing. Allow it only
        // when the user has forced a Proton compatibility tool; otherwise
        // explain how to turn that on. Windows-only titles (no native build)
        // always run under Proton, so they skip the check.
        function __ofLooksNativeLinux() {
          try {
            if (
              document.querySelector(
                ".platform_img.linux, .platform_img.steamos, .sysreq_tab[data-os='linux']",
              )
            )
              return true;
            var tabs = document.querySelectorAll(
              ".sysreq_tabs .sysreq_tab, .game_area_sys_req_full",
            );
            for (var i = 0; i < tabs.length; i++) {
              var txt = (tabs[i].textContent || "").toLowerCase();
              if (txt.indexOf("linux") !== -1 || txt.indexOf("steamos") !== -1)
                return true;
            }
          } catch (_) {}
          return false;
        }
        function __ofBlockNative() {
          ShowLuaToolsAlert(
            "LuaTools",
            lt(
              "This game has a native Linux version, so Steam runs it without Proton. Online fixes are Windows files that only work under Proton. To use one, open the game's Properties → Compatibility, turn on “Force the use of a specific Steam Play compatibility tool”, pick a Proton version, then try Online Fix again.",
            ),
          );
        }
        function __ofProceed() {
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
        }
        if (__ofLooksNativeLinux()) {
          // Native build present: only allow the fix when a Proton/compat tool
          // is forced for this game; otherwise guide the user to enable one.
          Millennium.callServerMethod("luatools", "IsCompatToolForced", {
            appid: data.appid,
            contentScriptQuery: "",
          })
            .then(function (res) {
              var p = typeof res === "string" ? JSON.parse(res) : res;
              if (p && p.success && p.forced) {
                __ofProceed();
              } else {
                __ofBlockNative();
              }
            })
            .catch(function (err) {
              backendLog("LuaTools: IsCompatToolForced error: " + err);
              __ofBlockNative();
            });
        } else {
          // No native build -> the title runs under Proton anyway, fix applies.
          __ofProceed();
        }
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
# Crack/Bypass button -> ryuu.lol fixes (replaces upstream's Generic Fix).
#
# Upstream's "Generic Fix" hits index.luatools.work (a rate-limited CF-Workers
# free tier that serves ~0 fixes), so it's effectively dead. Replace that
# button with "Crack/Bypass" sourced from the ryuu catalogue: availability +
# download URL come from data.crackFix (resolved server-side by CheckForFixes
# against the bundled appid->fix index). Same native/Proton gate as Online Fix
# (a Windows crack does nothing on a title Steam runs natively), then the normal
# applyFix download/extract flow (downloader.sh unpacks nested .rar payloads).
#
# Anchored on the upstream genericSection createFixButton block.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = r'''    // left thing in fixes modal
    const genericStatus = data.genericFix.status;
    const genericSection = createFixButton(
      lt("Generic Fix"),
      genericStatus === 200 ? lt("Apply") : lt("No generic fix"),
      genericStatus === 200 ? "fa-check" : "fa-circle-xmark",
      genericStatus === 200 ? true : false,
      function (e) {
        e.preventDefault();
        if (genericStatus === 200 && isGameInstalled) {
          const genericUrl =
            "https://files.luatools.work/GameBypasses/" + data.appid + ".zip";
          applyFix(
            data.appid,
            genericUrl,
            lt("Generic Fix"),
            data.gameName,
            overlay,
          );
        }
      },
    );
    columnsContainer.appendChild(genericSection);

    if (!isGameInstalled) {
      genericSection.style.opacity = "0.5";
      genericSection.style.cursor = "not-allowed";
    }'''

replacement = r'''    // slsteammoon: replace upstream's dead "Generic Fix" with a "Crack/Bypass"
    // button sourced from the ryuu catalogue. Availability + URL come from
    // data.crackFix (CheckForFixes resolves it against the bundled index).
    const crackStatus = (data.crackFix && data.crackFix.status) || 0;
    const crackSection = createFixButton(
      lt("Crack/Bypass"),
      // slsteammoon: static descriptive subtitle (like the sibling buttons),
      // not the Apply/No-crack status -- availability is conveyed by the
      // dimmed style below, not the text.
      lt("Fetches and applies fixes from Ryuu Fixes"),
      "fa-wrench",
      // slsteammoon: a normal (theme-colored) button when available, NOT the
      // green "success" highlight -- it's an action, not an applied state.
      // Match the sibling buttons (Online Fix passes null). Stay dimmed/
      // disabled when no crack/bypass exists (isSuccess === false).
      crackStatus === 200 ? null : false,
      function (e) {
        e.preventDefault();
        if (crackStatus !== 200 || !isGameInstalled) return;
        const crackUrl = data.crackFix && data.crackFix.url;
        if (!crackUrl) return;
        // slsteammoon: a crack/bypass is a bundle of Windows files that only
        // takes effect under Proton/Wine. A title that ships a native Linux
        // build runs WITHOUT Proton by default, so the crack would do nothing.
        // Allow it only when the user has forced a Proton compatibility tool;
        // otherwise explain how. Windows-only titles always run under Proton.
        function __cfLooksNativeLinux() {
          try {
            if (
              document.querySelector(
                ".platform_img.linux, .platform_img.steamos, .sysreq_tab[data-os='linux']",
              )
            )
              return true;
            var tabs = document.querySelectorAll(
              ".sysreq_tabs .sysreq_tab, .game_area_sys_req_full",
            );
            for (var i = 0; i < tabs.length; i++) {
              var txt = (tabs[i].textContent || "").toLowerCase();
              if (txt.indexOf("linux") !== -1 || txt.indexOf("steamos") !== -1)
                return true;
            }
          } catch (_) {}
          return false;
        }
        function __cfBlockNative() {
          ShowLuaToolsAlert(
            "LuaTools",
            lt(
              "This game has a native Linux version, so Steam runs it without Proton. Cracks are Windows files that only work under Proton. To use one, open the game's Properties \u2192 Compatibility, turn on \u201CForce the use of a specific Steam Play compatibility tool\u201D, pick a Proton version, then try Crack/Bypass again.",
            ),
          );
        }
        function __cfProceed() {
          applyFix(data.appid, crackUrl, lt("Crack/Bypass"), data.gameName, overlay);
        }
        if (__cfLooksNativeLinux()) {
          Millennium.callServerMethod("luatools", "IsCompatToolForced", {
            appid: data.appid,
            contentScriptQuery: "",
          })
            .then(function (res) {
              var p = typeof res === "string" ? JSON.parse(res) : res;
              if (p && p.success && p.forced) {
                __cfProceed();
              } else {
                __cfBlockNative();
              }
            })
            .catch(function (err) {
              backendLog("LuaTools: IsCompatToolForced error: " + err);
              __cfBlockNative();
            });
        } else {
          __cfProceed();
        }
      },
    );
    columnsContainer.appendChild(crackSection);

    if (!isGameInstalled) {
      crackSection.style.opacity = "0.5";
      crackSection.style.cursor = "not-allowed";
    }'''

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] CRACK/BYPASS ANCHOR FAILED: found %d matches (need 1). "
        "The genericSection block moved upstream; update patch-frontend.sh.\n" % n)
    sys.exit(3)
s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Generic Fix button replaced with Crack/Bypass (ryuu)")
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
'          // slsteammoon: reliable auto-set via the Lumen SharedJSContext relay\n'
'          // (SteamClient is absent in this store-page web view, so the\n'
'          // best-effort call above no-ops here; the relay runs it where\n'
'          // SteamClient lives).\n'
'          // slsteammoon: the Lumen relay sets the launch option automatically\n'
'          // in SharedJSContext, so on success the user has nothing to paste.\n'
'          // Only fall back to the paste-line tutorial if the relay reports a\n'
'          // failure or is unreachable (rare; e.g. the sidecar is not running).\n'
'          var __ltShowHintFallback = function () {\n'
'            try { showLuaToolsLaunchOptionHint(overlayEl, opts); } catch (e) {\n'
'              backendLog("LuaTools: launch-option hint error: " + e);\n'
'            }\n'
'          };\n'
'          try {\n'
'            Millennium.callServerMethod("luatools", "__lumenSetLaunchOptions", {\n'
'              appid: Number(appid),\n'
'              options: opts,\n'
'            })\n'
'              .then(function (r) {\n'
'                var ok = false;\n'
'                try { ok = (typeof r === "string" ? JSON.parse(r) : r).ok; } catch (_) {}\n'
'                backendLog("LuaTools: launch-option relay ok=" + ok);\n'
'                if (!ok) __ltShowHintFallback();\n'
'              })\n'
'              .catch(function (e) {\n'
'                backendLog("LuaTools: launch-option relay error: " + e);\n'
'                __ltShowHintFallback();\n'
'              });\n'
'          } catch (e) {\n'
'            backendLog("LuaTools: launch-option relay throw: " + e);\n'
'            __ltShowHintFallback();\n'
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

# ---------------------------------------------------------------------------
# Manage Game button -> "Unfix".
#
# The button's job on this fork is to undo any applied fix and restore the
# game to its original state (drop the SpaceFix/FakeAppIds mapping + verify
# game files to revert the file-based Crack/Online fixes). Rename the label
# from "Manage Game" to "Unfix" and give it a coherent description.
#
# Anchored on the unfixSection createFixButton label/subtitle.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'    const unfixSection = createFixButton(\n'
'      lt("Manage Game"),\n'
'      lt("Un-Fix (verify game)"),\n'
)
replacement = (
'    const unfixSection = createFixButton(\n'
'      lt("Unfix"),\n'
'      lt("Restore the game to its original state"),\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] UNFIX LABEL ANCHOR FAILED: found %d matches (need 1). "
        "The unfixSection block moved upstream; update patch-frontend.sh.\n" % n)
    sys.exit(3)
s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Manage Game button renamed to Unfix")
PY

# ---------------------------------------------------------------------------
# Remove the "Only possible thanks to ShayneVi" credit footer.
#
# Every fix option in this modal has been reworked by this fork, so the
# upstream attribution no longer reflects the feature set. Drop the footer by
# removing the line that inserts it into the DOM. The (now orphaned) creditMsg
# element is created but never shown; the link-wiring setTimeout finds nothing
# and no-ops. Keeping the creation avoids a ReferenceError on the append site.
#
# Anchored on the credit append.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = '    contentContainer.appendChild(creditMsg);\n'
replacement = (
'    // slsteammoon: credit footer removed (every fix option was reworked by\n'
'    // this fork). creditMsg is created above but intentionally not appended.\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] CREDIT FOOTER ANCHOR FAILED: found %d matches (need 1). "
        "The credit append moved upstream; update patch-frontend.sh.\n" % n)
    sys.exit(3)
s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] credit footer (ShayneVi) removed")
PY

# ---------------------------------------------------------------------------
# Un-Fix: clear the WINEDLLOVERRIDES launch option.
#
# A Crack/Online fix sets a WINEDLLOVERRIDES launch option (so Proton loads the
# fix DLLs). Un-Fix restores the game to its original state, so it must also
# remove that option -- without it the leftover Windows DLLs are inert. The
# backend UnFixGame computes the cleaned launch options (current minus the
# override) and returns clearLaunchOptions + launchOptions; here we apply them
# via the Lumen relay (SteamClient lives in SharedJSContext, not this store web
# view). Empty string clears the field entirely.
#
# Anchored on the startUnfix UnFixGame success branch.
# ---------------------------------------------------------------------------
"$PYBIN" - "$JS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

anchor = (
'            const payload = typeof res === "string" ? JSON.parse(res) : res;\n'
'            if (payload && payload.success) {\n'
'              showUnfixProgress(appid);\n'
'            } else {\n'
)
replacement = (
'            const payload = typeof res === "string" ? JSON.parse(res) : res;\n'
'            if (payload && payload.success) {\n'
'              // slsteammoon: clear the WINEDLLOVERRIDES launch option the fix\n'
'              // set, restoring the original launch options (the leftover fix\n'
'              // DLLs are inert without it). Relayed via Lumen -- SteamClient\n'
'              // lives in SharedJSContext, not this store web view.\n'
'              if (payload.clearLaunchOptions) {\n'
'                try {\n'
'                  Millennium.callServerMethod("luatools", "__lumenSetLaunchOptions", {\n'
'                    appid: Number(appid),\n'
'                    options: payload.launchOptions || "",\n'
'                  });\n'
'                } catch (_) {}\n'
'              }\n'
'              showUnfixProgress(appid);\n'
'            } else {\n'
)

n = s.count(anchor)
if n != 1:
    sys.stderr.write(
        "[patch-frontend] UNFIX CLEAR-LAUNCHOPTS ANCHOR FAILED: found %d matches "
        "(need 1). The startUnfix success branch moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n)
    sys.exit(3)
s = s.replace(anchor, replacement, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Un-Fix clears WINEDLLOVERRIDES launch option")
PY

# ---------------------------------------------------------------------------
# "Manage" header buttons for an already-added game.
#
# When a game is already added via LuaTools, HasLuaToolsForApp returns
# exists===true and the upstream code suppresses the "Add via LuaTools" header
# button (returning early). In that state the store-page button row only shows
# "Restart Steam", with no inline way to remove the game or open the fixes
# menu. This injects two buttons — "Remove via LuaTools" and "Fixes Menu" —
# styled like the native Restart Steam / Add via LuaTools buttons, right after
# Restart Steam.
#
# Three anchored splices:
#   1. the helper (linux/frontend/manage-buttons.js) is inserted into the IIFE
#      scope just before addLuaToolsButton (declarations hoist);
#   2. a call is added in the HasLuaToolsForApp exists===true branch;
#   3. the new insertion-guard flag is reset on page change (both reset blocks).
#
# Anchored: aborts loudly if any upstream anchor moved.
# ---------------------------------------------------------------------------
MANAGE_INC="$SCRIPT_DIR/../linux/frontend/manage-buttons.js"
if [[ ! -f "$MANAGE_INC" ]]; then
  echo "[patch-frontend] missing manage-buttons include at $MANAGE_INC" >&2
  exit 2
fi

INC="$MANAGE_INC" "$PYBIN" - "$JS" <<'PY'
import os, sys

path = sys.argv[1]
with open(os.environ["INC"], "r", encoding="utf-8") as f:
    fn = f.read()
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

# 1. Splice the helper before addLuaToolsButton (same IIFE scope).
def_anchor = "  function addLuaToolsButton() {\n"
if s.count(def_anchor) != 1:
    sys.stderr.write(
        "[patch-frontend] MANAGE DEF ANCHOR FAILED: found %d matches (need 1).\n"
        "addLuaToolsButton moved upstream; update scripts/patch-frontend.sh.\n"
        % s.count(def_anchor))
    sys.exit(3)
s = s.replace(def_anchor, fn.rstrip() + "\n\n" + def_anchor, 1)

# 2. Call the helper in the exists===true branch (game already added).
call_anchor = (
'                if (payload && payload.success && payload.exists === true) {\n'
'                  backendLog(\n'
'                    "LuaTools already present for this app; not inserting button",\n'
'                  );\n'
'                  window.__LuaToolsPresenceCheckInFlight = false;\n'
'                  return; // do not insert\n'
'                }\n'
)
if s.count(call_anchor) != 1:
    sys.stderr.write(
        "[patch-frontend] MANAGE CALL ANCHOR FAILED: found %d matches (need 1).\n"
        "The HasLuaToolsForApp exists branch moved upstream; update "
        "scripts/patch-frontend.sh.\n" % s.count(call_anchor))
    sys.exit(3)
call_repl = (
'                if (payload && payload.success && payload.exists === true) {\n'
'                  backendLog(\n'
'                    "LuaTools already present for this app; not inserting button",\n'
'                  );\n'
'                  // slsteammoon: the game is already added, so "Add via\n'
'                  // LuaTools" is suppressed. Surface inline header buttons to\n'
'                  // remove the game and open the Fixes Menu (same layout as\n'
'                  // Restart Steam / Add via LuaTools).\n'
'                  try {\n'
'                    addLuaToolsManageButtons(appid, steamdbContainer);\n'
'                  } catch (_) {}\n'
'                  window.__LuaToolsPresenceCheckInFlight = false;\n'
'                  return; // do not insert\n'
'                }\n'
)
s = s.replace(call_anchor, call_repl, 1)

# 3. Reset the manage insertion-guard flag on page change (both reset blocks
#    carry the same 4-line flag-reset sequence -> expect exactly 2 matches).
reset_anchor = (
'      window.__LuaToolsButtonInserted = false;\n'
'      window.__LuaToolsRestartInserted = false;\n'
'      window.__LuaToolsIconInserted = false;\n'
'      window.__LuaToolsHeaderInserted = false;\n'
)
n_reset = s.count(reset_anchor)
if n_reset != 2:
    sys.stderr.write(
        "[patch-frontend] MANAGE RESET ANCHOR FAILED: found %d matches (need 2).\n"
        "The page-change flag-reset blocks moved upstream; update "
        "scripts/patch-frontend.sh.\n" % n_reset)
    sys.exit(3)
reset_repl = reset_anchor + '      window.__LuaToolsManageInserted = false;\n'
s = s.replace(reset_anchor, reset_repl)

with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch-frontend] Remove via LuaTools + Fixes Menu header buttons injected")
PY
