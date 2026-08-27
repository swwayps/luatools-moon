-- guard: validation for values that reach the backend from the frontend bridge.
--
-- Every RPC argument here is untrusted. The bridge is reachable from script
-- running inside the Steam store/community web views, and several endpoints
-- interpolated their arguments straight into a /bin/sh command line — inside
-- DOUBLE quotes, where the shell still performs command substitution, so
-- "http://x$(cmd)" ran cmd. Others accepted an arbitrary destination path or
-- download URL and then wrote a downloaded archive over it.
--
-- The rules below are deliberately strict and allowlist-shaped: the legitimate
-- callers pass ordinary URLs and Steam library paths, so refusing anything
-- unusual costs nothing.
local guard = {}

-- Longest URL we will hand to curl. Real download URLs are far shorter; a
-- multi-kilobyte one is a sign of something being smuggled.
local MAX_URL = 2048
local MAX_TAG = 128

-- shell_quote(value) -> a single-quoted shell word.
-- Single quotes are the only quoting in POSIX sh that suppresses ALL expansion.
-- A literal quote is closed, escaped and reopened ('\''), which is why the
-- result can contain \' sequences. NUL cannot cross an argv boundary, so it is
-- dropped rather than silently truncating the rest of the value.
function guard.shell_quote(value)
  local s = tostring(value == nil and "" or value):gsub("%z", "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Reject anything that is not a printable, space-free URL character. This kills
-- CR/LF (header and command-line splitting), NUL, tabs, escape sequences and
-- spaces in one check.
local function url_charset_ok(url)
  if url:find("[%c%s]") then return false end
  return true
end

-- split_url(url) -> scheme, authority, rest   (nil when unparseable)
local function split_url(url)
  local scheme, authority, rest = url:match("^(%a[%w+.-]*)://([^/%?#]*)([^%s]*)$")
  if not scheme then return nil end
  return scheme:lower(), authority, rest or ""
end

-- https_url(url, opts) -> url, or nil + reason.
--   opts.hosts      : set of exact lowercase hosts to allow (nil = any host)
--   opts.allow_http : also accept plain http (opt-in; used only for legacy
--                     sources that are explicitly marked untrusted)
-- The host must match the allowlist EXACTLY: no subdomains, no suffixes, and no
-- explicit port, because a port turns "github.com:8443" into a different peer
-- while still reading like an allowlisted host.
function guard.https_url(url, opts)
  opts = opts or {}
  if type(url) ~= "string" or url == "" then return nil, "not a string" end
  if #url > MAX_URL then return nil, "too long" end
  if not url_charset_ok(url) then return nil, "illegal character" end
  local scheme, authority, rest = split_url(url)
  if not scheme then return nil, "unparseable" end
  if scheme ~= "https" and not (opts.allow_http and scheme == "http") then
    return nil, "scheme not allowed"
  end
  if authority == "" then return nil, "empty host" end
  if authority:find("@", 1, true) then return nil, "userinfo not allowed" end
  local host = authority:lower()
  if opts.hosts then
    if host:find(":", 1, true) then return nil, "explicit port not allowed" end
    if not opts.hosts[host] then return nil, "host not allowed" end
  end
  return scheme .. "://" .. authority .. rest
end

-- external_url(url) -> url, or nil + reason.
-- For URLs handed to the desktop browser. http is tolerated (the legitimate
-- targets are fixed product links, some of which still redirect from http).
--
-- The characters refused here are the ones that cannot legally appear unescaped
-- in a URL and that a shell would act on: quotes, backticks, `$`, `;`, `|`, `&`,
-- redirection and braces. Query strings and fragments are NOT refused — `?`, `#`,
-- `*`, `~`, `[` and `]` are ordinary URL characters, and rejecting them made a
-- perfectly good link like https://steamdb.info/app/440/?x=1 surface to the user
-- as "Invalid URL". Injection is prevented by single-quoting at the call site
-- (guard.shell_quote); this blocklist is the second layer, not the first.
local SHELL_META = '[`$\\;|&<>()"\'{}]'
function guard.external_url(url)
  local checked, reason = guard.https_url(url, { allow_http = true })
  if not checked then return nil, reason end
  if checked:find(SHELL_META) then return nil, "shell metacharacter" end
  return checked
end

-- normalize_path(path) -> canonical absolute path, or nil.
-- Purely lexical: it resolves "." and ".." and collapses separators, but does
-- not touch the filesystem, so it cannot be defeated by a race. Relative paths
-- are refused outright — every path this validates is supposed to be absolute,
-- and "resolving" a relative one would only invent a base directory.
function guard.normalize_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  if path:find("[%z\n\r]") then return nil end
  if path:sub(1, 1) ~= "/" then return nil end
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then                      -- no-op
    elseif seg == ".." then
      -- Popping at the root keeps the result inside the root instead of
      -- producing a path with a leading "..".
      if #parts > 0 then parts[#parts] = nil end
    else
      parts[#parts + 1] = seg
    end
  end
  if #parts == 0 then return "/" end
  return "/" .. table.concat(parts, "/")
end

-- same_path(a, b) -> true when both normalize to the same absolute path.
-- Used to check a caller-supplied install path against the one the backend
-- derived itself from libraryfolders.vdf + appmanifest_<appid>.acf.
function guard.same_path(a, b)
  local na, nb = guard.normalize_path(a), guard.normalize_path(b)
  if not na or not nb then return false end
  return na == nb
end

-- tag_name(s) -> s, or nil. A git tag / release identifier that is safe to
-- interpolate into a URL path.
function guard.tag_name(s)
  if type(s) ~= "string" or s == "" or #s > MAX_TAG then return nil end
  if not s:match("^[%w%.%-_]+$") then return nil end
  return s
end

-- repo_segment(s) -> s, or nil. A single GitHub owner or repository name. Same
-- charset as a tag: one path segment, no separators, nothing the shell or a URL
-- parser would treat specially.
function guard.repo_segment(s)
  if s == ".." or s == "." then return nil end
  return guard.tag_name(s)
end

return guard
