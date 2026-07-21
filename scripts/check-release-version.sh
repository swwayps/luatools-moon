#!/usr/bin/env bash
# Refuse release tags that do not match plugin/plugin.json.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-}"

[[ "$TAG" =~ ^v[0-9]+([.][0-9]+)*$ ]] || {
  echo "[release] invalid tag format: $TAG (expected vN or vN.N)" >&2
  exit 2
}

TAG_VERSION="${TAG#v}"
PLUGIN_VERSION="$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$ROOT/plugin/plugin.json")"

[[ "$TAG_VERSION" == "$PLUGIN_VERSION" ]] || {
  echo "[release] tag $TAG does not match plugin version $PLUGIN_VERSION" >&2
  exit 3
}

echo "[release] tag $TAG matches plugin version $PLUGIN_VERSION"
