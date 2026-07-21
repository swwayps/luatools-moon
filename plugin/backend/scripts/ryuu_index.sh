#!/bin/bash
# ryuu_index.sh — build the Crack/Bypass index (appid -> fix archive) from the
# ryuu.lol fixes catalogue page.
#
# The catalogue at https://generator.ryuu.lol/fixes is an HTML page that embeds
# every fix as  data-appid="<id>" data-filename="<file>"  on its vote row, with
# preceding  data-badge-key="<badge>"  spans. There is no JSON index, so we
# scrape those attributes into a small JSON map the backend can look up by
# appid offline:
#
#   { "generated": "<iso8601>", "source": "...", "count": N,
#     "fixes": { "<appid>": [ { "file": "<name>.zip", "badge": "<badge>" } ] } }
#
# Used in TWO places, same code:
#   * build time  — the dev runs it to (re)generate the bundled
#                   plugin/backend/ryuu_index.json shipped in the release.
#   * run time    — the backend spawns it DETACHED to refresh a user-local
#                   cache copy (crackfix.lua), so newly added fixes appear
#                   without waiting on a fresh release. Never blocks a request.
#
# Filtering: drops "hypervisor" fixes (VM/anti-cheat patches that don't run
# under Proton) by badge OR filename. Everything else is kept; archive-only
# repacks are fine because the apply step extracts nested archives.
#
# Portability: POSIX awk only (no gawk 3-arg match) so it runs under mawk on
# Debian/Ubuntu. Atomic write via temp + mv.
#
# Usage:
#   ryuu_index.sh <out.json> [src]
#     src = a URL (default https://generator.ryuu.lol/fixes) or a local HTML file.

set -u

OUT="${1:-}"
SRC="${2:-https://generator.ryuu.lol/fixes}"
if [ -z "$OUT" ]; then
  echo "usage: ryuu_index.sh <out.json> [src-url-or-file]" >&2
  exit 2
fi

# Use system libraries when spawned from inside Steam's runtime (mirrors
# downloader.sh): otherwise curl can fail to load its libs.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
# Timeouts are env-overridable so the build can cap the fetch tightly (fall
# back to the bundled copy fast) while the runtime refresh can be generous.
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
MAX_TIME="${MAX_TIME:-60}"
TMP_HTML="$(mktemp 2>/dev/null || echo /tmp/ryuu_html.$$)"
TMP_JSON="$(mktemp 2>/dev/null || echo /tmp/ryuu_json.$$)"
trap 'rm -f "$TMP_HTML" "$TMP_JSON"' EXIT

if [ -f "$SRC" ]; then
  cp "$SRC" "$TMP_HTML" || exit 1
else
  curl -fsSL -A "$UA" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "$SRC" -o "$TMP_HTML" || {
    echo "ryuu_index: download failed" >&2; exit 1; }
fi

# Bail if the page looks empty/wrong (don't clobber a good index with garbage).
if ! grep -q 'data-filename="' "$TMP_HTML"; then
  echo "ryuu_index: no fix entries found in source" >&2
  exit 1
fi

GEN_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# One tag per line, then POSIX-awk scrape. Track badge spans; emit on the row
# that carries both appid and filename. Reset badge list after each emit.
sed 's/>/>\n/g' "$TMP_HTML" | awk -v gen="$GEN_ISO" -v src="$SRC" '
  function attr(line, key,   re, p, s, q) {
    re = key "=\""
    p = index(line, re)
    if (p == 0) return ""
    s = substr(line, p + length(re))
    q = index(s, "\"")
    if (q == 0) return ""
    return substr(s, 1, q - 1)
  }
  # Decode the handful of HTML entities that show up in filenames.
  function unent(s) {
    gsub(/&#39;/, "\x27", s); gsub(/&amp;/, "\\&", s)
    gsub(/&quot;/, "\"", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s)
    return s
  }
  # Minimal JSON string escaping (backslash and double-quote).
  function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
  function lc(s) { return tolower(s) }

  /data-badge-key="/ {
    bk = attr($0, "data-badge-key")
    if (bk != "") badges[++nb] = bk
    next
  }
  /data-filename="/ {
    fn = attr($0, "data-filename")
    ap = attr($0, "data-appid")
    if (fn == "" || ap !~ /^[0-9]+$/) { nb = 0; delete badges; next }
    fn = unent(fn)

    hyper = (lc(fn) ~ /hypervisor/) ? 1 : 0
    badge = ""
    for (i = 1; i <= nb; i++) {
      if (lc(badges[i]) == "hypervisor") hyper = 1
      badge = badges[i]   # keep the last as the representative badge
    }
    nb = 0; delete badges

    if (hyper) next

    entry = "{\"file\":\"" jesc(fn) "\",\"badge\":\"" jesc(badge) "\"}"
    if (ap in data) { data[ap] = data[ap] "," entry } else { data[ap] = entry; order[++no] = ap }
    count++
  }

  END {
    printf "{\"generated\":\"%s\",\"source\":\"%s\",\"count\":%d,\"fixes\":{", gen, src, count
    for (i = 1; i <= no; i++) {
      ap = order[i]
      printf "%s\"%s\":[%s]", (i > 1 ? "," : ""), ap, data[ap]
    }
    printf "}}\n"
  }
' > "$TMP_JSON"

# Sanity: must be non-trivial and contain the marker keys.
if ! grep -q '"fixes":{' "$TMP_JSON" || [ "$(wc -c < "$TMP_JSON")" -lt 64 ]; then
  echo "ryuu_index: generated JSON looks invalid" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null
mv -f "$TMP_JSON" "$OUT" || exit 1
trap 'rm -f "$TMP_HTML"' EXIT
echo "ryuu_index: wrote $OUT"
