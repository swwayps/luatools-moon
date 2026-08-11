#!/usr/bin/env bash
# Unit tests for the CloudRedirect install/update decision.
#
# Contract under test: the installer asks about cloud saves only when the hook
# is not deployed yet. An existing deployment is never asked about again -- it is
# updated silently when the published hook differs, and left alone when it
# doesn't.
#
# Sourcing install.sh with SLSPLUGIN_LIB_ONLY=1 defines the functions WITHOUT
# running main().
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
HOME="$SANDBOX"
export HOME

SLSPLUGIN_LIB_ONLY=1 . "$HERE/install.sh"

fail=0
ck(){ if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (want '$2' got '$3')"; fail=1; fi; }

# ── ETag parsing (runs first, against the real cr_published_stamp) ───────────
curl(){ printf 'HTTP/2 200\r\nETag: "abc123"\r\ncontent-length: 42\r\n\r\n'; }
ck "etag parsed from headers" '"abc123"' "$(cr_published_stamp)"
curl(){ printf 'HTTP/2 301\r\netag: "redirect"\r\n\r\nHTTP/2 200\r\netag: "final"\r\n\r\n'; }
ck "last etag wins across redirects" '"final"' "$(cr_published_stamp)"
curl(){ printf 'HTTP/2 200\r\ncontent-length: 42\r\n\r\n'; }
ck "missing etag yields empty" "" "$(cr_published_stamp)"
curl(){ return 22; }
ck "failed HEAD yields empty" "" "$(cr_published_stamp)"
unset -f curl

# ── stubs: keep the decision logic, cut out network / disk side effects ──────
PROMPTED=0; DOWNLOADED=0; REPAIRED=0
log_info(){ :; }
log_warn(){ :; }
log_success(){ :; }
print_section(){ :; }
set_disable_cloud(){ :; }
ensure_cloudredirect_config(){ :; }
repair_cas_save_layout(){ REPAIRED=1; }
prompt_yes_no(){ PROMPTED=1; return 1; }   # user declines

PUBLISHED_STAMP='"published-v2"'
cr_published_stamp(){ [ -n "$PUBLISHED_STAMP" ] && printf '%s\n' "$PUBLISHED_STAMP"; return 0; }
install_cloudredirect_so(){
	DOWNLOADED=1
	mkdir -p "$CR_DIR"
	printf 'hook\n' > "$CR_SO_PATH"
	cr_write_so_stamp
	return 0
}

reset_state(){ PROMPTED=0; DOWNLOADED=0; REPAIRED=0; PREASK_CLOUD=""; rm -rf "$CR_DIR"; }
deploy_hook(){ mkdir -p "$CR_DIR"; printf 'hook\n' > "$CR_SO_PATH"; }

# ── predicate ───────────────────────────────────────────────────────────────
reset_state
ck "not installed when file absent" "no" \
  "$(cloudredirect_installed && echo yes || echo no)"
deploy_hook
ck "installed when file present" "yes" \
  "$(cloudredirect_installed && echo yes || echo no)"
: > "$CR_SO_PATH"
ck "not installed when file is empty" "no" \
  "$(cloudredirect_installed && echo yes || echo no)"

# ── fresh install: still asks ───────────────────────────────────────────────
reset_state
install_cloudredirect >/dev/null 2>&1
ck "fresh install asks the user" "1" "$PROMPTED"
ck "declined fresh install downloads nothing" "0" "$DOWNLOADED"

# ── installed + already current: do nothing ─────────────────────────────────
reset_state
deploy_hook
printf '%s\n' "$PUBLISHED_STAMP" > "$CR_SO_STAMP"
install_cloudredirect >/dev/null 2>&1
ck "current install does not ask" "0" "$PROMPTED"
ck "current install does not download" "0" "$DOWNLOADED"
ck "current install skips the legacy CAS scan" "0" "$REPAIRED"

# ── installed + update published: update silently ───────────────────────────
reset_state
deploy_hook
printf '%s\n' '"published-v1"' > "$CR_SO_STAMP"
install_cloudredirect >/dev/null 2>&1
ck "stale install does not ask" "0" "$PROMPTED"
ck "stale install updates itself" "1" "$DOWNLOADED"
ck "stale install refreshes the stamp" "$PUBLISHED_STAMP" "$(cat "$CR_SO_STAMP")"
ck "stale install runs the legacy CAS scan" "1" "$REPAIRED"

# ── installed by an older installer (no stamp): check, don't ask ────────────
reset_state
deploy_hook
install_cloudredirect >/dev/null 2>&1
ck "stampless install does not ask" "0" "$PROMPTED"
ck "stampless install verifies against the published hook" "1" "$DOWNLOADED"

# ── stamp unavailable (offline / header stripped): check, don't ask ─────────
reset_state
deploy_hook
printf '%s\n' "$PUBLISHED_STAMP" > "$CR_SO_STAMP"
PUBLISHED_STAMP=""
install_cloudredirect >/dev/null 2>&1
ck "unknown published stamp does not ask" "0" "$PROMPTED"
ck "unknown published stamp falls back to a content check" "1" "$DOWNLOADED"
PUBLISHED_STAMP='"published-v2"'

# ── the Deck pre-ask must be guarded by the same predicate ──────────────────
preask_body="$(awk '/^preask_prompts\(\)/,/^}/' "$HERE/install.sh")"
case "$preask_body" in
	*'cloudredirect_installed'*'Q_CLOUD_EN'*)
		echo "ok   - preask skips the cloud question when installed" ;;
	*)
		echo "FAIL - preask asks the cloud question unconditionally"; fail=1 ;;
esac

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
