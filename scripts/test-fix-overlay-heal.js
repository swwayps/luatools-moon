#!/usr/bin/env node
// Exercise the real helpers embedded in public/luatools.js without booting
// Steam's entire store-page runtime.
//
// Stale-overlay heal: Game Mode dismisses the view with the gamepad, which never
// reaches our close handlers, so an orphaned overlay used to make the Fixes Menu
// unopenable for the rest of the session.
//
// Download auth failure: downloader.sh tags HTTP 401/403 with errorCode
// "authentication", which must surface as "the source refused this" and not as
// the generic "corrupt or incomplete archive" dead end.
"use strict";
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
let failures = 0;

function eq(name, got, want) {
  if (got === want) console.log("ok   " + name);
  else {
    console.error("FAIL " + name + ": got=" + JSON.stringify(got) + " want=" + JSON.stringify(want));
    failures++;
  }
}

// ── stale-overlay heal ──────────────────────────────────────────────────────
const healEnd = source.indexOf("\n  try { window.__LuaToolsClearStaleFixOverlays");
const listStart = source.indexOf("const LT_STALE_FIX_OVERLAYS");
if (listStart < 0 || healEnd < 0) {
  console.error("FAIL stale-overlay heal is missing");
  process.exit(1);
}
const healSandbox = {};
vm.runInNewContext(
  source.slice(listStart, healEnd) + "\nglobalThis.heal = clearStaleFixOverlays;",
  healSandbox,
);
const heal = healSandbox.heal;

function fakeDoc(classNames) {
  const nodes = classNames.map(function (cls) {
    return { cls: cls, removed: false, remove: function () { this.removed = true; } };
  });
  return {
    nodes: nodes,
    querySelectorAll: function (selector) {
      const wanted = selector.split(",").map(function (s) { return s.trim().slice(1); });
      return nodes.filter(function (n) {
        return wanted.indexOf(n.cls) >= 0 && !n.removed;
      });
    },
  };
}

const doc = fakeDoc(["luatools-fixes-results-overlay", "luatools-settings-overlay"]);
eq("F13 clears the stale fix overlay", heal(doc), 1);
const untouched = doc.nodes.filter(function (n) { return !n.removed; })
  .map(function (n) { return n.cls; });
eq("F14 leaves unrelated overlays alone",
  untouched.length === 1 && untouched[0] === "luatools-settings-overlay", true);
eq("F15 nothing to heal is not an error", heal(fakeDoc([])), 0);
eq("F16 a broken document cannot throw", heal({}), 0);

// ── download auth failure ───────────────────────────────────────────────────
const start = source.indexOf("function downloadAuthFailure(");
const end = source.indexOf("\n  function groupOfficialFixCategories(", start);
if (start < 0 || end < 0) {
  console.error("FAIL download auth-failure helper is missing");
  process.exit(1);
}
const sandbox = {};
vm.runInNewContext(
  source.slice(start, end).trim()
    + "\nglobalThis.authFailure = downloadAuthFailure;",
  sandbox,
);
const authFailure = sandbox.authFailure;
eq("F9 typed 401 state is an auth failure",
  authFailure({ status: "failed", errorCode: "authentication" }), true);
eq("F10 typed apply rejection is an auth failure",
  authFailure({ errorCode: "authentication" }), true);
eq("F11 ordinary download failure is not an auth failure",
  authFailure({ status: "failed", error: "corrupt" }), false);
eq("F12 nullish state is not an auth failure", authFailure(null), false);

// ── nothing collects a fix-download credential any more ─────────────────────
eq("F17 no credential modal survives in the frontend",
  /showRyuuAuthPopup|SaveRyuuAuthCredential|luatools-ryuu-/.test(source), false);

if (failures) process.exit(1);
console.log("ALL FIX-OVERLAY/AUTH FRONTEND CHECKS PASSED");
