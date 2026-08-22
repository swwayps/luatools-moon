const fs = require("fs");
const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

check("L1 source picker renders the Luie login gate in Lumen blue",
  source.includes("sourceNeedsLogin") && source.includes('lt("Needs login")')
    && source.includes("#1a9fff"));
check("L2 managed sources are explicitly identified in settings",
  source.includes("const isManaged = api.managed === true"));
check("L3 managed Luie never receives drag behavior",
  source.includes("if (!isManaged) {") && source.includes("row.addEventListener('dragstart'"));
check("L4 managed Luie name is not editable",
  source.includes("if (!isManaged) nameDisplay.onclick"));
check("L5 managed Luie has no delete control",
  source.includes("if (!isManaged) row.appendChild(delBtn)"));
check("L6 Luie retains the same enable toggle as other sources",
  source.includes('callServerMethod("luatools", "ToggleApi"'));
check("L7 manual Luie downloads stay behind the managed-source RPC",
  source.includes('"StartAddViaLuaToolsSource"')
    && source.includes("source.managed === true"));

process.exitCode = failures ? 1 : 0;
