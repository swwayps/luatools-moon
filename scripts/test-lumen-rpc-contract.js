#!/usr/bin/env node

// Contract test: every static LuaTools frontend RPC must be published by the
// plugin-owned contract and have a real backend export. Lumen keeps a frozen
// fallback allowlist for old plugin builds; new methods must not have to be
// duplicated there.

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const lumenRoot = path.resolve(root, "..", "lumen");

function read(file) {
  return fs.readFileSync(file, "utf8");
}

function matches(source, regex, group = 1) {
  return [...source.matchAll(regex)].map((match) => match[group]);
}

function luaSources(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return luaSources(full);
    return entry.isFile() && entry.name.endsWith(".lua") ? [read(full)] : [];
  });
}

const frontend = read(path.join(root, "plugin", "public", "luatools.js"));
const backend = read(path.join(root, "plugin", "backend", "main.lua"));
const contractSource = read(path.join(root, "plugin", "backend", "rpc_contract.lua"));
const boot = read(path.join(lumenRoot, "lua", "boot.lua"));
const injector = read(path.join(lumenRoot, "lua", "injector.lua"));
const menu = fs.readdirSync(path.join(lumenRoot, "lua", "menu"))
  .filter((name) => name.endsWith(".js"))
  .sort()
  .map((name) => read(path.join(lumenRoot, "lua", "menu", name)))
  .join("\n");

const contractBlock = contractSource.match(/return\s*\{([\s\S]*?)\n\}/);
if (!contractBlock) throw new Error("RPC method table not found in rpc_contract.lua");

const literalCalls = matches(
  frontend,
  /Millennium\.callServerMethod\(\s*["']luatools["']\s*,\s*["']([^"']+)["']/g,
);
const rpcInvocations = matches(
  frontend,
  /Millennium\.callServerMethod\(\s*["']luatools["']\s*,/g,
  0,
);
const menuCalls = matches(
  menu,
  /(?:^|[^.A-Za-z0-9_])(?:call|relay)\(\s*["']([^"']+)["']/gm,
);
const calls = new Set([...literalCalls, ...menuCalls]);
const contract = new Set(matches(contractBlock[1], /["']([^"']+)["']/g));
const controls = new Set(matches(injector, /req\.fn\s*==\s*["']([^"']+)["']/g));
const backendExports = new Set([
  ...matches(backend, /^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm),
  ...matches(backend, /_G\[["']([^"']+)["']\]\s*=/g),
  ...matches(backend, /^([A-Z][A-Za-z0-9_.]*)\s*=\s*[A-Z][A-Za-z0-9_.]*\s*$/gm),
]);
const nativeRegistrations = new Set(
  luaSources(path.join(lumenRoot, "lua")).flatMap((source) =>
    matches(source, /registry\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function\b/g),
  ),
);
const unexpectedDynamicMenuCalls = menu.split("\n").filter((line) =>
  /(?:^|[^.A-Za-z0-9_])call\(\s*(?!["'])/.test(line)
  && !/^\s*(?:\/\/|\/\*|\*)/.test(line)
  && !/function\s+call\s*\(/.test(line)
  && !/call\(fn\)/.test(line),
);

const missingDispatch = [...calls]
  .filter((name) => !contract.has(name)
    && !controls.has(name)
    && !nativeRegistrations.has(name))
  .sort();
const missingBackend = [...calls]
  .filter((name) => contract.has(name)
    && !backendExports.has(name))
  .sort();
const missingContractTargets = [...contract]
  .filter((name) => !backendExports.has(name))
  .sort();
const errors = [];
if (rpcInvocations.length !== literalCalls.length) {
  errors.push("frontend contains a dynamic RPC method name that cannot be audited");
}
if (unexpectedDynamicMenuCalls.length) {
  errors.push(
    `Lumen menu contains dynamic RPC names that cannot be audited: ${unexpectedDynamicMenuCalls.join(" | ")}`,
  );
}
if (missingDispatch.length) {
  errors.push(`would return unknown method: ${missingDispatch.join(", ")}`);
}
if (missingBackend.length) {
  errors.push(`allowlisted without a backend export: ${missingBackend.join(", ")}`);
}
if (missingContractTargets.length) {
  errors.push(`contract entries have no implementation: ${missingContractTargets.join(", ")}`);
}
if (!backend.includes('rpc_methods         = require("rpc_contract")')) {
  errors.push("backend lifecycle does not publish rpc_contract");
}
if (!boot.includes("lifecycle.rpc_methods")) {
  errors.push("Lumen does not consume the plugin-owned RPC contract");
}
if (errors.length) throw new Error(`LuaTools/Lumen RPC contract broken: ${errors.join("; ")}`);

console.log(
  `ok   ${new Set(literalCalls).size} LuaTools frontend + ${new Set(menuCalls).size} Lumen menu RPC methods are registered`,
);
