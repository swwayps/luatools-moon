#!/usr/bin/env bash
# Reproducibly rebuild the bundled cloud_redirect.so.
#
# Clones CloudRedirect at the pinned upstream commit, applies our patch
# (slsteammoon-cloudredirect.patch), and builds a 32-bit .so inside the
# glibc-2.35 container (Dockerfile.builder). The result is copied next to this
# script as cloud_redirect.so.
#
# Usage:  ./build.sh
# Needs:  podman or docker.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="https://github.com/Selectively11/CloudRedirect.git"
BASE_COMMIT="0251ed93e4223a89b5d1eebea80615eabba78f81"  # pinned upstream HEAD (v2.1.8)
IMAGE="slsteammoon-cloudredirect-builder"
WORK="$HERE/.build-src"

runtime=""
for c in podman docker; do
	if command -v "$c" >/dev/null 2>&1; then runtime="$c"; break; fi
done
[ -n "$runtime" ] || { echo "need podman or docker" >&2; exit 1; }

echo "==> building builder image ($IMAGE)"
"$runtime" build -f "$HERE/Dockerfile.builder" -t "$IMAGE" "$HERE"

echo "==> fetching upstream @ $BASE_COMMIT"
rm -rf "$WORK"
git clone --no-checkout "$UPSTREAM" "$WORK"
git -C "$WORK" checkout "$BASE_COMMIT"

echo "==> applying slsteam-moon patch"
git -C "$WORK" apply "$HERE/slsteammoon-cloudredirect.patch"

echo "==> building 32-bit cloud_redirect.so in container"
"$runtime" run --rm -v "$WORK":/build:Z -w /build "$IMAGE" bash -c '
  set -e
  cmake -S . -B _b -DLINUX_32BIT=ON -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc-12 -DCMAKE_CXX_COMPILER=g++-12 >/dev/null
  cmake --build _b --target cloud_redirect -j"$(nproc)"
'

cp -f "$WORK/_b/cloud_redirect.so" "$HERE/cloud_redirect.so"
chmod 755 "$HERE/cloud_redirect.so"
rm -rf "$WORK"

echo "==> done: $HERE/cloud_redirect.so"
file "$HERE/cloud_redirect.so"
# Sanity: must be 32-bit, must NOT require glibc newer than the Steam runtime.
if file -b "$HERE/cloud_redirect.so" | grep -q "ELF 32-bit"; then
	echo "OK: 32-bit"
else
	echo "ERROR: not 32-bit" >&2; exit 1
fi
if readelf -V "$HERE/cloud_redirect.so" 2>/dev/null | grep -qE "GLIBC_ABI_GNU_TLS|GLIBC_2\.3[6-9]|GLIBC_2\.4[0-9]"; then
	echo "ERROR: links against too-new glibc (won't load in Steam runtime)" >&2
	exit 1
fi
echo "OK: glibc symbols within Steam-runtime range"
