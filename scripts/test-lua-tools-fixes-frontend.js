const fs = require("fs");

const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

check("VF1 store Fixes applies the selected official fix ID",
  source.includes('callServerMethod("luatools", "StartLuaToolsFix"'));
check("VF2 store Fixes completes the same persisted receipt after launch options",
  source.includes('callServerMethod("luatools", "CompleteLuaToolsFixApply"'));
check("VF3 store Fixes renders a rounded category badge selector",
  source.includes("__LuaToolsGroupFixCategories")
    && source.includes("luatools-fix-category-badge"));
check("VF4 no-login Online Fix remains a clearly secondary fallback",
  source.includes('lt("Online Fix · No login")')
    && source.includes("Fallback mirror. Fixes may be outdated")
    && source.includes('callServerMethod("luatools", "ResolveOnlineFix"'));
check("VF5 applied state is visible but does not disable reapply",
  source.includes("luatools-fix-applied")
    && source.includes("applyLuaToolsOfficialFix(data.appid"));
check("VF6 official card fills the left side and three equal actions stack beside it",
  source.includes('next.style.gridRow = "1 / 4"')
    && source.includes('fallbackOnlineSection.style.gridRow = "1"')
    && source.includes('aioSection.style.gridRow = "2"')
    && source.includes('unfixSection.style.gridRow = "3"'));
check("VF7 official card uses the native LuaTools SVG and reference purple",
  source.includes("luatools-logo-brand")
    && source.includes("#AC4EAD")
    && source.includes("#670867"));
check("VF8 fallback apply participates in the durable receipt flow",
  source.includes('receiptKind === "online_fix_fallback"')
    && source.includes("data.fallbackOnlineApplied"));
check("VF9 Spacewar renders its persisted FakeAppIds state",
  source.includes("data.spacewarApplied"));
// Lumen ships its settings menu to the DESKTOP shell only, so in Game Mode the
// bridge is present in this web view but the window it opens is a mouse-and-
// menubar overlay drawn over the 10-foot UI. Both sign-in paths have to ask the
// mode, not just whether the function exists.
check("VF10 the Lumen sign-in bridge is only used outside Big Picture",
  source.includes("function canOpenLumenAccount()")
    && source.includes("!window.__LUATOOLS_IS_BIG_PICTURE__")
    // one definition plus both sign-in paths, and the raw `typeof` guard survives
    // ONLY inside the helper, so no call site can bypass the mode check
    && (source.match(/canOpenLumenAccount\(\)/g) || []).length === 3
    && (source.match(/typeof window\.__lumenOpenLuaToolsAccount === "function"/g) || []).length === 1
    && (source.match(/luaToolsSignInHint\(\)/g) || []).length === 3
    && source.includes("Sign in to lua.tools from Desktop Mode first."));
// Game Mode has no file manager to open into, so the button is a dead end there.
check("VF11 Game folder is a desktop-only action",
  source.includes("if (!window.__LUATOOLS_IS_BIG_PICTURE__) rightButtons.appendChild(gameFolderBtn);")
    && (source.match(/rightButtons\.appendChild\(gameFolderBtn\)/g) || []).length === 1);

process.exitCode = failures ? 1 : 0;
