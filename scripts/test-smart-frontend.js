#!/usr/bin/env node
const fs = require("fs");
const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log(`ok   - ${name}`);
  else { console.log(`FAIL - ${name}`); failures += 1; }
}
const startHelper = source.indexOf("const startSmartDownload = function");
const continueHelper = source.indexOf("const continueWithAdd = function", startHelper);
const fastHelperBody = source.slice(startHelper, continueHelper);
const apiCheck = source.indexOf('"CheckApisForApp"');
check("fast helper exists", startHelper >= 0);
check("fast helper is defined before manual API check", startHelper >= 0 && startHelper < apiCheck);
check("fast RPC handles immediate rejection", fastHelperBody.includes(".catch(function"));
check("polling starts only after smart RPC succeeds",
  fastHelperBody.indexOf(".then(function") >= 0 &&
  fastHelperBody.indexOf("startPolling(appid") > fastHelperBody.indexOf(".then(function"));
check("fast branch starts aggregation directly",
  /if \(isFastDownload\) \{\s*startSmartDownload\(appid\);\s*return;\s*\}/s.test(source));
check("manual branch retains API availability check", apiCheck >= 0);
check("manual branch retains source selection modal", source.includes("showSourceSelectionModal(appid, available)"));
check("smart RPC remains wired", source.includes('"StartAddViaLuaToolsSmart"'));
if (failures) process.exit(1);
console.log("\nALL TESTS OK");