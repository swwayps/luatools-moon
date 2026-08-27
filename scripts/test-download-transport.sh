#!/usr/bin/env bash
# Transport and integrity rules for the download workers.
#
# Both workers used to call curl with no --proto restriction, so the scheme was
# whatever the URL said: file:// read a local file into the pipeline, and an
# https URL could be redirected down to http without anything noticing. Neither
# worker had any way to verify what it downloaded before unpacking it over a
# game directory.
#
# Run from the repo root:  bash scripts/test-download-transport.sh
set -u
fails=0
checks=0
check() {
	checks=$((checks + 1))
	if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }
command -v zip >/dev/null 2>&1 || { echo "SKIP: no zip"; exit 0; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DL="$REPO/plugin/backend/scripts/downloader.sh"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT

status_of() {
	sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}
err_of() {
	sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}

# A small real zip to serve.
mkdir -p "$TMP/payload"
printf 'hello\n' > "$TMP/payload/file.txt"
(cd "$TMP/payload" && zip -q -r "$TMP/good.zip" .)
GOOD_SHA="$(sha256sum "$TMP/good.zip" | cut -d' ' -f1)"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
(cd "$TMP" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do
	curl -fsS -o /dev/null "http://127.0.0.1:$PORT/good.zip" 2>/dev/null && break
	sleep 0.1
done

run_dl() {
	# run_dl <label> <url> [env assignments...]
	local label="$1" url="$2"
	shift 2
	local dest="$TMP/${label}.zip"
	local extract="$TMP/${label}-out"
	local state="$TMP/${label}-state.json"
	mkdir -p "$extract"
	env "$@" bash "$DL" "$url" "$dest" "$extract" "$state" >/dev/null 2>&1
	printf '%s' "$state"
}

# ---------------------------------------------------------------------------
# T1: a file:// source is refused. It is not a download at all, and it used to
#     be accepted because curl was called with no protocol restriction.
# ---------------------------------------------------------------------------
S="$(run_dl t1 "file://$TMP/good.zip")"
check "T1 a file:// source is refused" '[ "$(status_of "$S")" = "failed" ]'
check "T1b nothing was extracted from a file:// source" '[ -z "$(ls -A "$TMP/t1-out" 2>/dev/null)" ]'

# ---------------------------------------------------------------------------
# T2: plaintext http is refused unless the caller states the source has no TLS.
# ---------------------------------------------------------------------------
S="$(run_dl t2 "http://127.0.0.1:$PORT/good.zip")"
check "T2 plaintext http is refused by default" '[ "$(status_of "$S")" = "failed" ]'

S="$(run_dl t3 "http://127.0.0.1:$PORT/good.zip" ALLOW_HTTP=1)"
check "T3 ALLOW_HTTP=1 permits a declared plaintext source" \
	'[ "$(status_of "$S")" = "extracted" ]'
check "T3b the archive contents landed in the extract directory" \
	'[ -f "$TMP/t3-out/file.txt" ]'

# ---------------------------------------------------------------------------
# T4: an unsupported scheme is refused outright.
# ---------------------------------------------------------------------------
for scheme in ftp scp gopher dict; do
	S="$(run_dl "t4-$scheme" "$scheme://127.0.0.1/x.zip")"
	check "T4 a $scheme:// source is refused" '[ "$(status_of "$S")" = "failed" ]'
done

# ---------------------------------------------------------------------------
# T5: integrity. When the caller states the expected digest, a mismatch must
#     stop BEFORE anything is written into the extract directory.
# ---------------------------------------------------------------------------
S="$(run_dl t5 "http://127.0.0.1:$PORT/good.zip" ALLOW_HTTP=1 \
	EXPECTED_SHA256=0000000000000000000000000000000000000000000000000000000000000000)"
check "T5 a digest mismatch fails the download" '[ "$(status_of "$S")" = "failed" ]'
check "T5b a digest mismatch extracts nothing" \
	'[ -z "$(ls -A "$TMP/t5-out" 2>/dev/null)" ]'
check "T5c the failure names the integrity check" \
	'echo "$(err_of "$S")" | grep -qi "verif\|integrity\|match"'

S="$(run_dl t6 "http://127.0.0.1:$PORT/good.zip" ALLOW_HTTP=1 \
	EXPECTED_SHA256="$GOOD_SHA")"
check "T6 the correct digest lets the download through" \
	'[ "$(status_of "$S")" = "extracted" ]'
check "T6b the verified archive is extracted" '[ -f "$TMP/t6-out/file.txt" ]'

# A digest given in upper case, or with surrounding whitespace, still matches.
S="$(run_dl t7 "http://127.0.0.1:$PORT/good.zip" ALLOW_HTTP=1 \
	EXPECTED_SHA256="$(printf '  %s  ' "${GOOD_SHA^^}")")"
check "T7 digest comparison ignores case and padding" \
	'[ "$(status_of "$S")" = "extracted" ]'

# A malformed digest must be treated as a failure, never as "no digest given".
S="$(run_dl t8 "http://127.0.0.1:$PORT/good.zip" ALLOW_HTTP=1 EXPECTED_SHA256=notahash)"
check "T8 a malformed expected digest fails closed" '[ "$(status_of "$S")" = "failed" ]'

# ---------------------------------------------------------------------------
# T9: both workers pin the redirect protocol, so a 302 cannot downgrade the
#     transport of an https download.
# ---------------------------------------------------------------------------
check "T9 downloader pins the request and redirect protocols" \
	'grep -q -- "--proto-redir" "$DL" && grep -q -- "--proto" "$DL"'
check "T9b the smart downloader pins them too" \
	'grep -q -- "--proto-redir" "$REPO/plugin/backend/scripts/smart_download.sh"'
check "T9c neither worker leaves curl unrestricted" \
	'! grep -qE "^\s*curl [^|]*-o .*\\\$URL" "$DL"'

echo
echo "$checks check(s), $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
