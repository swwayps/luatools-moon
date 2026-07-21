#!/usr/bin/env bash
# Run the repository's local test suite against a deterministic build.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for dependency in curl jq luajit node python3 tar unzip zip; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "$dependency is required" >&2
    exit 2
  }
done

command -v 7zz >/dev/null 2>&1 \
  || command -v 7z >/dev/null 2>&1 \
  || command -v 7za >/dev/null 2>&1 \
  || {
    echo "7-Zip is required" >&2
    exit 2
  }

SKIP_INDEX_REFRESH=1 scripts/build.sh >/dev/null

for test_file in scripts/test-*.sh tests/test_*.sh; do
  echo "[test] $test_file"
  bash "$test_file"
done

for test_file in scripts/test-*.lua; do
  echo "[test] $test_file"
  luajit "$test_file"
done

echo "[test] all tests passed"
