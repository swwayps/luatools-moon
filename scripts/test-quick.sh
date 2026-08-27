#!/usr/bin/env bash
# Fast local suite: builds once (with the zip, which some tests compare against)
# then runs every scripts/test-* and tests/test_* file, reporting one line each.
# Same set as scripts/test.sh but it keeps going after a failure and summarises,
# which is what you want while iterating.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
	SKIP_INDEX_REFRESH=1 scripts/build.sh --zip >/dev/null || {
		echo "build failed" >&2
		exit 2
	}
fi

pass=0
fail=0
failed=()

run_one() {
	local name="$1"
	shift
	local out rc
	out=$("$@" </dev/null 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "FAIL  $name"
		printf '%s\n' "$out" | tail -10 | sed 's/^/      /'
		fail=$((fail + 1))
		failed+=("$name")
	else
		echo "ok    $name"
		pass=$((pass + 1))
	fi
}

for t in scripts/test-*.sh tests/test_*.sh; do
	[ "$t" = "scripts/test-quick.sh" ] && continue
	run_one "$t" bash "$t"
done
for t in scripts/test-*.lua; do run_one "$t" luajit "$t"; done
for t in scripts/test-*.js; do run_one "$t" node "$t"; done
for t in scripts/test-*.py; do run_one "$t" python3 "$t"; done

echo "----"
echo "passed: $pass  failed: $fail"
if [ "$fail" -ne 0 ]; then
	printf 'failed:\n'
	printf '  %s\n' "${failed[@]}"
	exit 1
fi
