#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

while IFS= read -r -d '' file; do
  node --check "$file" >/dev/null
done < <(find "$ROOT/plugin" -type f -name '*.js' -print0)

echo "ok - plugin JavaScript parses without syntax errors"
