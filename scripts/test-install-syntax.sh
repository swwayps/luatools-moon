#!/usr/bin/env bash
# The standalone installer must remain parseable even when a downloader or
# editor normalizes indentation from tabs to spaces.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT/install.sh"
NORMALIZED="$(mktemp)"
trap 'rm -f "$NORMALIZED"' EXIT

bash -n "$INSTALL_SH"
expand -t 4 "$INSTALL_SH" > "$NORMALIZED"
bash -n "$NORMALIZED"

echo "ALL PASS"
