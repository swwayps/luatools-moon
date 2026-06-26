  // ===========================================================================
  // slsteammoon: "manage" header buttons for an already-added game
  // ---------------------------------------------------------------------------
  // When a game is already added via LuaTools the "Add via LuaTools" header
  // button is suppressed (HasLuaToolsForApp -> exists). In that state the
  // store-page button row would otherwise only carry "Restart Steam", leaving
  // the user no inline way to remove the game or open the fixes menu (both were
  // reachable only through the settings popup). This adds two buttons —
  // "Remove via LuaTools" and "Fixes Menu" — styled exactly like the native
  // Restart Steam / Add via LuaTools buttons and placed right after Restart
  // Steam (order: Community Hub -> Restart Steam -> Remove -> Fixes Menu).
  //
  // Spliced into luatools.js (IIFE scope) by scripts/patch-frontend.sh; reuses
  // the in-scope helpers (lt/t, ensureStyles, backendLog, ShowLuaToolsAlert,
  // showLuaToolsConfirm, showFixesLoadingPopupAndCheck, addLuaToolsButton).
  // ===========================================================================
  function addLuaToolsManageButtons(appid, container) {
    if (!container || isNaN(appid)) return;
    if (
      container.querySelector(".luatools-remove-button") ||
      window.__LuaToolsManageInserted
    ) {
      return;
    }
    try {
      ensureStyles();
    } catch (_) {}

    // Reference an existing button so the new ones inherit the native store
    // look-and-feel. Prefer the Restart Steam button (same row, same styling);
    // fall back to the first link in the container / the BP queue button.
    const isBigPicture = window.__LUATOOLS_IS_BIG_PICTURE__;
    const referenceBtn =
      container.querySelector(".luatools-restart-button") ||
      (isBigPicture
        ? document.querySelector("#queueBtnFollow")
        : container.querySelector("a"));

    const makeBtn = function (cls, label) {
      const a = document.createElement("a");
      if (referenceBtn && referenceBtn.className) {
        // Strip any LuaTools marker classes the reference button carries so we
        // copy only the native Steam button styling, then add our own marker.
        const base = referenceBtn.className.replace(/luatools-[\w-]+/g, "").trim();
        a.className = (base + " " + cls).replace(/\s+/g, " ").trim();
      } else {
        a.className = "btnv6_blue_hoverfade btn_medium " + cls;
      }
      a.href = "#";
      a.title = label;
      a.setAttribute("data-tooltip-text", label);
      const span = document.createElement("span");
      span.textContent = label;
      a.appendChild(span);
      return a;
    };

    const removeText = t("menu.removeLuaTools", "Remove via LuaTools");
    const fixesText = t("menu.fixesMenu", "Fixes Menu");
    const removeBtn = makeBtn("luatools-remove-button", removeText);
    const fixesBtn = makeBtn("luatools-fixes-button", fixesText);

    // --- Remove via LuaTools -------------------------------------------------
    // Mirrors the settings-popup remove flow: confirm, delete the .lua via the
    // backend, then drop these buttons and restore "Add via LuaTools".
    const doDelete = function () {
      try {
        Millennium.callServerMethod("luatools", "DeleteLuaToolsForApp", {
          appid,
          contentScriptQuery: "",
        })
          .then(function () {
            try {
              removeBtn.remove();
              fixesBtn.remove();
              window.__LuaToolsManageInserted = false;
              window.__LuaToolsButtonInserted = false;
              window.__LuaToolsPresenceCheckInFlight = false;
              window.__LuaToolsPresenceCheckAppId = undefined;
              addLuaToolsButton();
              ShowLuaToolsAlert(
                "LuaTools",
                t("menu.remove.success", "LuaTools removed for this app."),
              );
            } catch (err) {
              backendLog("LuaTools: post-delete cleanup failed: " + err);
            }
          })
          .catch(function (err) {
            const failureText = t(
              "menu.remove.failure",
              "Failed to remove LuaTools.",
            );
            ShowLuaToolsAlert(
              "LuaTools",
              err && err.message ? err.message : failureText,
            );
          });
      } catch (err) {
        backendLog("LuaTools: doDelete failed: " + err);
      }
    };

    removeBtn.addEventListener("click", function (e) {
      e.preventDefault();
      showLuaToolsConfirm(
        "LuaTools",
        t("menu.remove.confirm", "Remove via LuaTools for this game?"),
        function () {
          doDelete();
        },
        function () {},
      );
    });

    // --- Fixes Menu ----------------------------------------------------------
    // Mirrors the settings-popup fixes flow: resolve the install path (so the
    // modal knows whether the game is installed), then open the fixes popup.
    fixesBtn.addEventListener("click", function (e) {
      e.preventDefault();
      try {
        Millennium.callServerMethod("luatools", "GetGameInstallPath", {
          appid,
          contentScriptQuery: "",
        })
          .then(function (pathRes) {
            try {
              let isGameInstalled = false;
              const pathPayload =
                typeof pathRes === "string" ? JSON.parse(pathRes) : pathRes;
              if (
                pathPayload &&
                pathPayload.success &&
                pathPayload.installPath
              ) {
                isGameInstalled = true;
                window.__LuaToolsGameInstallPath = pathPayload.installPath;
              }
              window.__LuaToolsGameIsInstalled = isGameInstalled;
              showFixesLoadingPopupAndCheck(appid);
            } catch (err) {
              backendLog("LuaTools: Fixes Menu (header) error: " + err);
            }
          })
          .catch(function () {
            ShowLuaToolsAlert(
              "LuaTools",
              t("menu.error.getPath", "Error getting game path"),
            );
          });
      } catch (err) {
        backendLog("LuaTools: Fixes Menu header button error: " + err);
      }
    });

    // Insert after Restart Steam (order: Restart -> Remove -> Fixes Menu).
    // Spacing: the row uses a 6px inter-button gap. The Restart button forces
    // margin:0 6px !important via .luatools-restart-button, and the ProtonDB
    // badge that follows carries its own 6px margin-left. So to keep every gap
    // at a uniform 6px (instead of the 12px two equally-margined buttons would
    // produce), each new button provides spacing on a single side: Remove uses
    // margin-right:6px (and margin-left:0 since Restart already supplies 6px on
    // its right), and Fixes uses margin:0 (ProtonDB/the row edge supplies the
    // trailing gap). When no Restart button precedes (edge case), Remove takes
    // the leading 6px itself.
    const anchorBtn =
      container.querySelector(".luatools-restart-button") || referenceBtn;
    const afterRestart = !!(
      anchorBtn && anchorBtn.classList.contains("luatools-restart-button")
    );
    removeBtn.style.marginLeft = afterRestart ? "0px" : "6px";
    removeBtn.style.marginRight = "6px";
    fixesBtn.style.marginLeft = "0px";
    fixesBtn.style.marginRight = "0px";
    if (anchorBtn && anchorBtn.after) {
      anchorBtn.after(removeBtn);
      removeBtn.after(fixesBtn);
    } else {
      container.appendChild(removeBtn);
      container.appendChild(fixesBtn);
    }
    window.__LuaToolsManageInserted = true;
    backendLog("Inserted Remove via LuaTools + Fixes Menu header buttons");
  }
