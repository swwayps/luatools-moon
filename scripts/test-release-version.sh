#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-release-version.sh"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$ROOT/plugin/plugin.json")"

"$CHECK" "v$VERSION"

if "$CHECK" "v999.999" >/dev/null 2>&1; then
  echo "a mismatched release tag must be rejected" >&2
  exit 1
fi

if "$CHECK" "release-$VERSION" >/dev/null 2>&1; then
  echo "a malformed release tag must be rejected" >&2
  exit 1
fi

echo "ok - release tag must match the canonical plugin version"
