  // ===========================================================================
  // slsteammoon: ProtonDB compatibility badge
  // ---------------------------------------------------------------------------
  // A refined, Steam-store-native badge that sits in the app page's button row
  // (next to SteamDB / PCGamingWiki / the LuaTools button). It carries
  // ProtonDB's tier identity (a glowing medal + tier color) while matching the
  // store's dark-pill button geometry so it reads as a first-class control.
  //
  // Tier data comes from the Lua backend (GetProtonDBStatus -> protondb.com
  // summaries API) to avoid cross-origin fetches from the store page. A fast
  // local DOM probe short-circuits to "Native" when the app ships a Linux
  // build, so the badge resolves instantly for native titles even offline.
  //
  // Spliced into luatools.js (IIFE scope) by scripts/patch-frontend.sh.
  // ===========================================================================

  // Tier palette — desaturated just enough to harmonize with Steam's dark
  // store chrome while staying unmistakably ProtonDB (medal colors).
  const LTP_TIERS = {
    platinum: { color: "#dbe6f2", glow: "rgba(198,216,236,0.55)", text: "#e8f0fa", label: "Platinum" },
    gold:     { color: "#ffce54", glow: "rgba(255,206,84,0.50)",  text: "#ffd76a", label: "Gold" },
    silver:   { color: "#c3ccd6", glow: "rgba(195,204,214,0.45)", text: "#d4dce5", label: "Silver" },
    bronze:   { color: "#d1854a", glow: "rgba(209,133,74,0.50)",  text: "#e3a06a", label: "Bronze" },
    borked:   { color: "#ff5a4d", glow: "rgba(255,90,77,0.55)",   text: "#ff7d72", label: "Borked" },
    native:   { color: "#69b34c", glow: "rgba(105,179,76,0.60)",  text: "#90db70", label: "Native" },
    pending:  { color: "#8f98a0", glow: "rgba(143,152,160,0.0)",  text: "#aab4bd", label: "Pending" },
  };

  function ltpEnsureStyles() {
    if (document.getElementById("luatools-protondb-styles")) return;
    const css =
      ".luatools-proton-btn{" +
      "position:relative;display:inline-flex !important;align-items:center;gap:7px;" +
      "margin-left:6px;padding:0 12px;height:32px;border-radius:3px;box-sizing:border-box;" +
      "vertical-align:bottom;cursor:pointer;text-decoration:none !important;" +
      "font-family:'Motiva Sans',Arial,Helvetica,sans-serif;font-size:11px;font-weight:700;" +
      "letter-spacing:.04em;line-height:1;white-space:nowrap;color:#c7d5e0;" +
      "background:linear-gradient(135deg,rgba(60,78,98,.55) 0%,rgba(33,44,58,.92) 100%);" +
      "border:1px solid rgba(0,0,0,.35);" +
      "box-shadow:inset 0 1px 0 rgba(255,255,255,.05);" +
      "transition:transform .15s ease,box-shadow .2s ease,border-color .2s ease,filter .2s ease;}" +
      ".luatools-proton-btn:hover{transform:translateY(-1px);filter:brightness(1.08);" +
      "box-shadow:inset 0 1px 0 rgba(255,255,255,.06),0 4px 14px var(--ltp-glow,rgba(0,0,0,.4));}" +
      ".luatools-proton-btn:active{transform:translateY(0);}" +
      ".luatools-proton-btn .ltp-medal{width:13px;height:13px;border-radius:50%;flex:0 0 auto;" +
      "background:radial-gradient(circle at 34% 30%,rgba(255,255,255,.75),transparent 58%)," +
      "var(--ltp-color,#66c0f4);" +
      "box-shadow:0 0 0 1px rgba(0,0,0,.45),0 0 7px var(--ltp-glow,transparent);}" +
      ".luatools-proton-btn .ltp-mark{color:#8fa1b2;font-weight:600;}" +
      ".luatools-proton-btn .ltp-sep{color:#5b6b7a;font-weight:600;}" +
      ".luatools-proton-btn .ltp-tier{text-transform:uppercase;color:var(--ltp-text,#c7d5e0);" +
      "text-shadow:0 0 10px var(--ltp-glow,transparent);}" +
      ".luatools-proton-btn.ltp-loading .ltp-medal{" +
      "background:conic-gradient(from 0deg,rgba(102,192,244,0),#66c0f4);" +
      "-webkit-mask:radial-gradient(circle 4.5px,transparent 96%,#000 0);" +
      "mask:radial-gradient(circle 4.5px,transparent 96%,#000 0);" +
      "animation:ltpSpin .8s linear infinite;box-shadow:none;}" +
      "@keyframes ltpSpin{to{transform:rotate(360deg);}}" +
      ".luatools-proton-btn.ltp-pulse .ltp-medal{animation:ltpPulse 1.6s ease-in-out infinite;}" +
      "@keyframes ltpPulse{0%,100%{opacity:.55;}50%{opacity:1;}}";
    const s = document.createElement("style");
    s.id = "luatools-protondb-styles";
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
  }

  // Instant local check: does this app ship a native Linux/SteamOS build?
  function ltpLooksNative() {
    if (document.querySelector(".platform_img.linux, .platform_img.steamos, .sysreq_tab[data-os='linux']")) {
      return true;
    }
    const tabs = document.querySelectorAll(".sysreq_tabs .sysreq_tab, .game_area_sys_req_full");
    for (let i = 0; i < tabs.length; i++) {
      const txt = (tabs[i].textContent || "").toLowerCase();
      if (txt.indexOf("linux") !== -1 || txt.indexOf("steamos") !== -1) return true;
    }
    return false;
  }

  function addLuaToolsProtonDBButton(appid, container) {
    if (!container || !appid || isNaN(appid)) return;
    if (container.querySelector(".luatools-proton-btn")) return;
    ltpEnsureStyles();

    const btn = document.createElement("a");
    btn.className = "luatools-proton-btn ltp-loading";
    btn.href = "https://www.protondb.com/app/" + appid;
    btn.target = "_blank";
    btn.rel = "noopener noreferrer";
    btn.title = "ProtonDB — Linux/Proton compatibility";

    const medal = document.createElement("span");
    medal.className = "ltp-medal";
    const mark = document.createElement("span");
    mark.className = "ltp-mark";
    mark.textContent = "ProtonDB";
    btn.appendChild(medal);
    btn.appendChild(mark);
    container.appendChild(btn);

    let locked = false; // native DOM probe wins over backend (more authoritative)

    const apply = function (tierKey, meta) {
      const t = LTP_TIERS[tierKey] || LTP_TIERS.pending;
      btn.classList.remove("ltp-loading", "ltp-pulse");
      btn.style.setProperty("--ltp-color", t.color);
      btn.style.setProperty("--ltp-glow", t.glow);
      btn.style.setProperty("--ltp-text", t.text);
      btn.style.borderColor = t.glow;
      btn.innerHTML = "";
      btn.appendChild(medal);
      const m = document.createElement("span");
      m.className = "ltp-mark";
      m.textContent = "ProtonDB";
      const sep = document.createElement("span");
      sep.className = "ltp-sep";
      sep.textContent = "·";
      const tier = document.createElement("span");
      tier.className = "ltp-tier";
      tier.textContent = t.label;
      btn.appendChild(m);
      btn.appendChild(sep);
      btn.appendChild(tier);

      let tip = "ProtonDB: " + t.label;
      if (meta && typeof meta.score === "number") {
        tip += "  ·  " + Math.round(meta.score * 100) + "%";
      }
      if (meta && typeof meta.total === "number" && meta.total > 0) {
        tip += "  ·  " + meta.total + " report" + (meta.total === 1 ? "" : "s");
      }
      if (tierKey === "native") tip = "Native Linux build  ·  ProtonDB";
      btn.title = tip;
    };

    const lockNative = function () {
      if (locked) return;
      locked = true;
      apply("native", null);
    };

    // Fast path: short DOM-probe window for a native badge.
    if (ltpLooksNative()) {
      lockNative();
    } else {
      let tries = 0;
      const probe = setInterval(function () {
        if (locked) { clearInterval(probe); return; }
        if (ltpLooksNative()) { clearInterval(probe); lockNative(); return; }
        if (++tries > 24) clearInterval(probe); // ~1.2s
      }, 50);
    }

    // Authoritative path: backend ProtonDB summary.
    try {
      Millennium.callServerMethod("luatools", "GetProtonDBStatus", {
        appid: appid,
        contentScriptQuery: "",
      })
        .then(function (res) {
          if (locked) return;
          const r = typeof res === "string" ? JSON.parse(res) : res;
          if (r && r.success && r.data && r.data.tier) {
            apply(String(r.data.tier).toLowerCase(), r.data);
          } else {
            apply("pending", null);
          }
        })
        .catch(function () {
          if (!locked) apply("pending", null);
        });
    } catch (_) {
      if (!locked) apply("pending", null);
    }
  }
