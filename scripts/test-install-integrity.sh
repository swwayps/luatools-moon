#!/usr/bin/env bash
# Integrity and extraction safety in install.sh.
#
# The installer's pipeline was: curl the release asset -> `unzip -qo` into a
# destination -> run setup.sh from it. `unzip -qo` happily writes entries with an
# absolute path or a "../" component outside the destination, and the archive was
# never checked against anything. The only control was TLS to github.com.
#
# Run from the repo root:  bash scripts/test-install-integrity.sh
set -u
fails=0
checks=0
check() {
	checks=$((checks + 1))
	if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

command -v zip >/dev/null 2>&1 || { echo "SKIP: no zip"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"
export SLSPLUGIN_LIB_ONLY=1
# shellcheck disable=SC1090
source "$INSTALL_SH" >/dev/null 2>&1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# A benign archive still extracts.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/src/sub"
printf 'setup\n' > "$TMP/src/setup.sh"
printf 'nested\n' > "$TMP/src/sub/file.txt"
(cd "$TMP/src" && zip -q -r "$TMP/good.zip" .)

DEST="$TMP/out-good"
check "E1 a benign archive extracts" 'extract_zip "$TMP/good.zip" "$DEST"'
check "E1b top-level entry present" '[ -f "$DEST/setup.sh" ]'
check "E1c nested entry present" '[ -f "$DEST/sub/file.txt" ]'

# ---------------------------------------------------------------------------
# Zip-slip: an entry whose path climbs out of the destination must be refused,
# and nothing may be written.
# ---------------------------------------------------------------------------
python3 - "$TMP/slip.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("harmless.txt", "ok")
    z.writestr("../escaped.txt", "pwned")
PY
DEST="$TMP/out-slip"
mkdir -p "$DEST"
check "E2 a parent-traversal entry is refused" '! extract_zip "$TMP/slip.zip" "$DEST"'
check "E2b nothing escaped the destination" '[ ! -f "$TMP/escaped.txt" ]'
check "E2c the destination was left empty" '[ -z "$(ls -A "$DEST")" ]'

# A deeper traversal, and one using a backslash separator.
python3 - "$TMP/slip2.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("a/b/../../../escaped2.txt", "pwned")
PY
check "E3 a nested traversal is refused" '! extract_zip "$TMP/slip2.zip" "$TMP/out-slip2"'
check "E3b nothing escaped" '[ ! -f "$TMP/escaped2.txt" ]'

# ---------------------------------------------------------------------------
# Absolute paths.
# ---------------------------------------------------------------------------
python3 - "$TMP/abs.zip" "$TMP/absolute-target.txt" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr(sys.argv[2].lstrip("/"), "x")
    zi = zipfile.ZipInfo(sys.argv[2])
    z.writestr(zi, "pwned")
PY
check "E4 an absolute-path entry is refused" '! extract_zip "$TMP/abs.zip" "$TMP/out-abs"'
check "E4b the absolute target was not created" '[ ! -f "$TMP/absolute-target.txt" ]'

# ---------------------------------------------------------------------------
# A symlink entry is refused: it would let a later write in the same archive (or
# the setup script that runs afterwards) land outside the destination.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/link-src"
ln -s /etc/passwd "$TMP/link-src/link"
(cd "$TMP/link-src" && zip -q -y -r "$TMP/link.zip" .)
check "E5 a symlink entry is refused" '! extract_zip "$TMP/link.zip" "$TMP/out-link"'
check "E5b no symlink was created" '[ ! -L "$TMP/out-link/link" ]'

# ---------------------------------------------------------------------------
# Digest verification.
# ---------------------------------------------------------------------------
GOOD_SHA="$(sha256sum "$TMP/good.zip" | cut -d' ' -f1)"
check "V1 the matching digest verifies" \
	'verify_sha256 "$TMP/good.zip" "$GOOD_SHA"'
check "V2 a wrong digest fails" \
	'! verify_sha256 "$TMP/good.zip" "0000000000000000000000000000000000000000000000000000000000000000"'
check "V3 a malformed digest fails rather than passing" \
	'! verify_sha256 "$TMP/good.zip" "notahash"'
check "V4 an empty digest fails rather than passing" \
	'! verify_sha256 "$TMP/good.zip" ""'
check "V5 case and whitespace in the digest are tolerated" \
	'verify_sha256 "$TMP/good.zip" "  ${GOOD_SHA^^}  "'
check "V6 a sidecar line with a filename column is accepted" \
	'verify_sha256 "$TMP/good.zip" "$GOOD_SHA  good.zip"'
check "V7 a missing file fails" \
	'! verify_sha256 "$TMP/nope.zip" "$GOOD_SHA"'

# ---------------------------------------------------------------------------
# The packaging scripts must publish a sidecar for every asset they build, so
# there is something for the installer to verify.
# ---------------------------------------------------------------------------
check "P1 the plugin packager writes a sha256 sidecar" \
	'grep -q "sha256sum" "$SCRIPT_DIR/build.sh"'

# ---------------------------------------------------------------------------
# The entry guard must not depend on python3. python3 is not in the installer's
# required_tools, so an implementation that returns success when it is missing
# deletes the guard on exactly the systems that lack it. unzip IS a hard
# prerequisite, so that is the implementation that has to carry the check.
# ---------------------------------------------------------------------------
NOPY="$TMP/nopy"
BASH="$(command -v bash)"
mkdir -p "$NOPY"
for tool in bash sh unzip zip sha256sum awk sed grep printf cut tr cat mktemp rm id uname; do
	real="$(command -v "$tool" 2>/dev/null)" || continue
	ln -sf "$real" "$NOPY/$tool"
done

run_without_python3() {
	# run_without_python3 <archive> <dest>
	# Absolute bash: the point is a PATH without python3, not without a shell.
	PATH="$NOPY" "$BASH" -c '
		SLSPLUGIN_LIB_ONLY=1
		export SLSPLUGIN_LIB_ONLY
		. "$1" >/dev/null 2>&1
		archive_entries_safe "$2"
	' _ "$INSTALL_SH" "$1"
}

check "N1 python3 really is unavailable on the stripped PATH" \
	'! PATH="$NOPY" command -v python3 >/dev/null 2>&1'
check "N2 a benign archive still passes without python3" \
	'run_without_python3 "$TMP/good.zip"'
check "N3 a traversal entry is still refused without python3" \
	'! run_without_python3 "$TMP/slip.zip"'
check "N4 a nested traversal is still refused without python3" \
	'! run_without_python3 "$TMP/slip2.zip"'
check "N5 an absolute-path entry is still refused without python3" \
	'! run_without_python3 "$TMP/abs.zip"'
check "N6 a symlink entry is still refused without python3" \
	'! run_without_python3 "$TMP/link.zip"'
check "N7 a non-archive is refused without python3" \
	'printf notazip > "$TMP/bogus.zip"; ! run_without_python3 "$TMP/bogus.zip"'

# ---------------------------------------------------------------------------
# A digest mismatch must be distinguishable from a network failure, so the
# installer does not tell the user to check their connection after an integrity
# failure.
# ---------------------------------------------------------------------------
check "D1 download_and_verify returns a distinct code for an integrity failure" \
	'grep -q "return 2" "$INSTALL_SH"'
check "D2 the CloudRedirect .so goes through download_and_verify" \
	'grep -q "download_and_verify \"\$CR_SO_URL\"" "$INSTALL_SH"'
check "D3 no asset download bypasses the verified path" \
	'! grep -qE "curl -fL \"\\\$(CR_SO_URL|url)\" -o" "$INSTALL_SH"'

echo
echo "$checks check(s), $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
