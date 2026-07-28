#!/usr/bin/env node
// Exercise the real card-state helper embedded in public/luatools.js without
// booting Steam's entire store-page runtime.
"use strict";

const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
const start = source.indexOf("function ryuuAuthFailure(");
const end = source.indexOf("\n  // Fixes Results popup", start);
if (start < 0 || end < 0) {
  console.error("FAIL Ryuu card-state helper is missing");
  process.exit(1);
}

// Stale-overlay heal: Game Mode dismisses the view with the gamepad, which never
// reaches our close handlers, so an orphaned overlay used to make the Fixes Menu
// unopenable for the rest of the session.
const healStart = source.indexOf("function clearStaleFixOverlays(");
const healEnd = source.indexOf("\n  try { window.__LuaToolsClearStaleFixOverlays", healStart);
if (healStart < 0 || healEnd < 0) {
  console.error("FAIL stale-overlay heal is missing");
  process.exit(1);
}
const listStart = source.indexOf("const LT_STALE_FIX_OVERLAYS");
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

const doc = fakeDoc(["luatools-fixes-results-overlay", "luatools-ryuu-auth-overlay",
                     "luatools-settings-overlay"]);
const removedCount = heal(doc);
console.log(removedCount === 2 ? "ok   F13 clears the stale fix overlays"
  : "FAIL F13 removed " + removedCount + " overlays");
if (removedCount !== 2) failuresLater = true;
const untouched = doc.nodes.filter(function (n) { return !n.removed; }).map(function (n) { return n.cls; });
console.log(untouched.length === 1 && untouched[0] === "luatools-settings-overlay"
  ? "ok   F14 leaves unrelated overlays alone"
  : "FAIL F14 touched unrelated overlays: " + JSON.stringify(untouched));
console.log(heal(fakeDoc([])) === 0 ? "ok   F15 nothing to heal is not an error"
  : "FAIL F15 empty document reported removals");
console.log(heal({}) === 0 ? "ok   F16 a broken document cannot throw"
  : "FAIL F16 broken document not contained");

const helperSource = source.slice(start, end).trim();
const sandbox = {};
vm.runInNewContext(
  helperSource +
    "\nglobalThis.__helpers = {" +
    "ryuuCrackUiState: ryuuCrackUiState, ryuuAuthFailure: ryuuAuthFailure};",
  sandbox,
);
const helper = sandbox.__helpers.ryuuCrackUiState;
const authFailure = sandbox.__helpers.ryuuAuthFailure;
let failures = 0;
let failuresLater = false;
function eq(name, got, want) {
  if (got === want) console.log("ok   " + name);
  else {
    console.error("FAIL " + name + ": got=" + JSON.stringify(got) + " want=" + JSON.stringify(want));
    failures++;
  }
}

const strings = {
  normal: "Ryuu fixes",
  auth: "Authentication required",
  badge: "Needs auth",
};
const needs = helper({status: 200, requiresAuth: true, authConfigured: false}, strings);
// The button keeps its own wrench: the key belongs to the badge, which is what
// actually says "needs auth".
eq("F1 missing auth keeps the wrench icon", needs.icon, "fa-wrench");
eq("F1b key icon rides on the badge", needs.badgeIcon, true);
eq("F2 missing auth has visible badge", needs.badge, "Needs auth");
eq("F3 missing auth explains requirement", needs.description, "Authentication required");
eq("F4 missing auth remains an available action", needs.available, true);

const ready = helper({status: 200, requiresAuth: true, authConfigured: true}, strings);
eq("F5 configured card uses wrench", ready.icon, "fa-wrench");
eq("F6 configured card has no badge", ready.badge, null);
eq("F6b configured card has no key on the badge", ready.badgeIcon, false);
eq("F7 configured card uses normal description", ready.description, "Ryuu fixes");

const absent = helper({status: 404}, strings);
eq("F8 unavailable source remains unavailable", absent.available, false);

// A rejected/expired session must surface as an authentication problem with a
// retry path, not as the generic "corrupt or incomplete archive" dead end.
eq("F9 typed 401 state is an auth failure",
  authFailure({status: "failed", errorCode: "authentication"}), true);
eq("F10 typed apply rejection is an auth failure",
  authFailure({errorCode: "authentication"}), true);
eq("F11 ordinary download failure is not an auth failure",
  authFailure({status: "failed", error: "corrupt"}), false);
eq("F12 nullish state is not an auth failure", authFailure(null), false);

if (failures || failuresLater) process.exit(1);
console.log("ALL RYUU FRONTEND CHECKS PASSED");
