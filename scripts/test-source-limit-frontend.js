const fs = require("fs");
const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

check("U1 frontend maps source limit codes to dedicated copy",
  source.includes("function sourceLimitMessage")
    && source.includes('case "daily_limit"')
    && source.includes('case "rate_limited"')
    && source.includes('case "quota_exhausted"'));
check("U2 daily and temporary limits use different messages",
  source.includes("Daily download limit reached for {source}")
    && source.includes("Too many requests to {source}")
    && source.includes("The quota for {source} has been exhausted"));
check("U3 manual availability errors do not become game-not-found",
  source.includes("firstSourceLimit")
    && source.includes("sourceLimitMessage(firstSourceLimit.errorCode"));
check("U4 worker failures use the same localized limit copy",
  source.includes("downloadFailureMessage(st)"));

process.exitCode = failures ? 1 : 0;
