#!/bin/bash
# Build the dxvk-native tarball used by the QEMU profile.
#
# usage: tools/build-dxvk.sh SRC LOCK BUILD_DIR OUT_TARBALL [URL]
#
# SRC          dxvk-native source directory (cloned here if missing)
# LOCK         git branch/tag to check out
# BUILD_DIR    staging directory for package-native.sh output
# OUT_TARBALL  where to copy the final dxvk-native-*.tar.gz
# URL          git clone URL (optional; defaults to DXVK_URL env or
#              the dxvc-native entry in tools/upstreams.conf)
#
# Prints OUT_TARBALL on stdout on success.  Exits non-zero on failure.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: build-dxvk.sh SRC LOCK BUILD_DIR OUT_TARBALL [URL]}"
LOCK="${2:?missing lock}"
BUILD_DIR="${3:?missing build dir}"
OUT_TARBALL="${4:?missing output tarball path}"
URL="${5:-${DXVK_URL:-}}"

note() { echo "-- $*"; }
die() { echo "build-dxvk: $*" >&2; exit 1; }

ver="${LOCK#v}"
[ -z "$URL" ] && URL="$(awk -F= '/^\[dxvk-native\]/{s=1} s&&/^url[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$DIR/tools/upstreams.conf")"
[ -n "$URL" ] || die "no dxvk-native URL (set DXVK_URL or edit tools/upstreams.conf)"

# Skip rebuild if a caller-supplied tarball is already in place.
if [ -n "${DXVK_NATIVE_TARBALL:-}" ]; then
    [ -f "$DXVK_NATIVE_TARBALL" ] || die "no such tarball: $DXVK_NATIVE_TARBALL"
    cp -f "$DXVK_NATIVE_TARBALL" "$OUT_TARBALL" || die "cannot copy $DXVK_NATIVE_TARBALL to $OUT_TARBALL"
    echo "$OUT_TARBALL"
    exit 0
fi

# Reuse a previously built tarball.
if [ -f "$OUT_TARBALL" ]; then
    echo "$OUT_TARBALL"
    exit 0
fi

# Clone the source if needed.
if [ ! -d "$SRC/.git" ]; then
    note "clone dxvk-native $LOCK"
    rm -rf "$SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet --depth 1 --branch "$LOCK" \
        --recurse-submodules --shallow-submodules \
        "$URL" "$SRC" || die "dxvk clone failed"
fi

note "build dxvk-native $LOCK"
rm -rf "$BUILD_DIR/dxvk-out"
( cd "$SRC" && ./package-native.sh "$ver" "$BUILD_DIR/dxvk-out" --64-only ) ||
    die "dxvk-native build failed"
cp "$BUILD_DIR/dxvk-out/dxvk-native-$ver.tar.gz" "$OUT_TARBALL" ||
    die "dxvk package missing"
rm -rf "$BUILD_DIR/dxvk-out"
echo "$OUT_TARBALL"
