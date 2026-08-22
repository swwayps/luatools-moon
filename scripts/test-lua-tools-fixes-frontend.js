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

process.exitCode = failures ? 1 : 0;
