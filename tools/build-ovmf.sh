#!/bin/bash
# Build the bundled silent OVMF images from a QEMU edk2 tree.
#
# usage: tools/build-ovmf.sh [EDK2_SRC] [OUT_DIR]
#
# EDK2_SRC defaults to src/qemu-*/roms/edk2, i.e. the snapshot that
# comes with the pinned QEMU tarball.  OUT_DIR defaults to build/ovmf; the
# files are never copied over share/firmware automatically.
#
# OVMF_GROUPS (comma separated) selects the patch groups: logo, bds or none.
# It defaults to logo,bds.
#
# Produces OVMF_CODE_4M.fd, OVMF_CODE_4M.secboot.fd, OVMF_VARS_4M.fd and
# OVMF_VARS_4M.ms.fd.  The secure image uses blank variables, so enroll
# keys before enabling Secure Boot on a domain.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"
SRC="${1:-}"
OUT="${2:-$DIR/build/ovmf}"

if [ -z "$SRC" ]; then
    for d in "$DIR"/src/qemu-*/roms/edk2; do
        [ -f "$d/OvmfPkg/OvmfPkgX64.dsc" ] && SRC="$d" && break
    done
fi
[ -n "$SRC" ] && [ -f "$SRC/OvmfPkg/OvmfPkgX64.dsc" ] || {
    echo "usage: tools/build-ovmf.sh EDK2_SRC [OUT_DIR]" >&2
    echo "EDK2_SRC not found; run install.sh --qemu:bin=compile first or pass a tree" >&2
    exit 1
}
  [ -f "$SRC/MdeModulePkg/Logo/Logo.bmp" ] || {
    echo "build-ovmf: $SRC is not an edk2 tree" >&2
    exit 1
}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Use VMM_CFLAGS/VMM_CXXFLAGS from install.sh (include diagnostic flags).
# If not set, default to empty (project defaults).
# Strip unsupported diagnostic flags that older GCC doesn't recognize.
VMM_CFLAGS="${VMM_CFLAGS:-}"
VMM_CXXFLAGS="${VMM_CXXFLAGS:-}"
# Remove flags not supported by GCC < 13
VMM_CFLAGS=$(echo "$VMM_CFLAGS" | sed 's/-fno-diagnostics-show-source-lines//g; s/-fno-diagnostics-show-event-links//g')
VMM_CXXFLAGS=$(echo "$VMM_CXXFLAGS" | sed 's/-fno-diagnostics-show-source-lines//g; s/-fno-diagnostics-show-event-links//g')

for tool in gcc make python3 nasm; do
    command -v "$tool" >/dev/null || {
        echo "build-ovmf: missing tool: $tool" >&2
        exit 1
    }
done

note() { echo "-- $*"; }
die() { echo "build-ovmf: $*" >&2; exit 1; }

OVMF_GROUPS="${OVMF_GROUPS:-logo,bds}"
groups=()
local_ifs="$IFS"
IFS=,
for g in $OVMF_GROUPS; do
    [ -n "$g" ] && groups+=("$g")
done
IFS="$local_ifs"
[ ${#groups[@]} -gt 0 ] || groups=(none)

has_group() {
    local g
    for g in "${groups[@]}"; do
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

note "patches: ${groups[*]}"
"$DIR/tools/patch-ovmf.sh" "$SRC" "${groups[@]}"

note "BaseTools"
# GCC 15+ defaults to C23: the bundled Pccts tools declare K&R-style
# function pointers, so "()" now means "no arguments" and the build
# fails.  Keep those two tools on C11, and let newer -Wall warnings
# (unused-but-set-variable and friends) through instead of failing on
# -Werror.
#
# The stamp matters: a leftover bin/GenFw from an older build used to make
# this block skip the patches, after which edksetup.sh rebuilt BaseTools
# on its own without them.  Patch and rebuild unless this exact tree has
# already produced a complete, patched set.
BT="$SRC/BaseTools/Source/C"
BT_STAMP="$SRC/BaseTools/.vmm-gcc-compat"
if [ ! -x "$BT/bin/GenFw" ] || [ ! -f "$BT_STAMP" ]; then
    for mf in VfrCompile/Pccts/antlr/makefile VfrCompile/Pccts/dlg/makefile; do
        [ -f "$BT/$mf" ] || continue
        grep -q -- '-std=gnu11' "$BT/$mf" ||
            sed -i 's/^[[:space:]]*CFLAGS=/& -std=gnu11 /' "$BT/$mf"
    done
    # header.makefile appends EXTRA_OPTFLAGS last, after -Werror.  It is
    # shared with CXXFLAGS, so keep it free of -std overrides.
    # Include diagnostic flags from install.sh.
    EXTRA_OPTFLAGS="${EXTRA_OPTFLAGS:-} -Wno-error ${VMM_CFLAGS}"
    export EXTRA_OPTFLAGS
    make -C "$BT" clean >/dev/null 2>&1 || true
    CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" make -C "$BT" -j "$JOBS"
    : > "$BT_STAMP"
fi

cd "$SRC"
export WORKSPACE="$SRC"
export EDK_TOOLS_PATH="$SRC/BaseTools"
export PYTHON_COMMAND=python3
# edksetup.sh/BuildEnv read unset variables; nounset must be off for it.
set +u
# shellcheck disable=SC1091
source ./edksetup.sh BaseTools >/dev/null
set -u
# edksetup writes Conf/tools_def.txt from the template.  Roll the GCC5
# compiler flags back to gnu17 and stop -Werror from turning newer GCC
# diagnostics into firmware build failures.  Appending keeps edk2's own
# DEF(...) expansion intact, and the guard keeps reruns idempotent.
TOOLS_DEF="$SRC/Conf/tools_def.txt"
if [ ! -f "$TOOLS_DEF" ]; then
    mkdir -p "$SRC/Conf"
    cp "$SRC/BaseTools/Conf/tools_def.template" "$TOOLS_DEF"
fi
if ! grep -qE '^[[:space:]]*(DEBUG|RELEASE|NOOPT)_GCC5_[A-Z0-9_]*_CC_FLAGS *=.*-std=gnu17' "$TOOLS_DEF"; then
    sed -i '/^[[:space:]]*\(DEBUG\|RELEASE\|NOOPT\)_GCC5_[A-Z0-9_]*_CC_FLAGS *=/ s/$/ -std=gnu17 -Wno-error/' "$TOOLS_DEF"
fi
BUILD="$SRC/BaseTools/BinWrappers/PosixLike/build"
FV="$SRC/Build/OvmfX64/RELEASE_GCC5/FV"

build_one() {
    local name="$1" code="$2" vars="$3"; shift 3
    note "$name"
    rm -rf "$SRC/Build/OvmfX64"
    ( cd "$SRC" && "$BUILD" -a X64 -t GCC5 -b RELEASE \
        -p OvmfPkg/OvmfPkgX64.dsc -D FD_SIZE_4MB "$@" -n "$JOBS" )
    mkdir -p "$OUT"
    cp "$FV/OVMF_CODE.fd" "$OUT/$code"
    cp "$FV/OVMF_VARS.fd" "$OUT/$vars"
}

build_one "plain" "OVMF_CODE_4M.fd" "OVMF_VARS_4M.fd"

if has_group bds; then
    DXE="$FV/DXEFV.Fv"
    strings -e l "$DXE" | grep -qF '%a: %a %s "%s" from %s' &&
        die "success messages still present in $DXE"
    strings -e l "$DXE" | grep -qF '%a: failed to %a %s "%s" from %s: %r' ||
        die "failure messages missing from $DXE"
fi

build_one "secure boot" "OVMF_CODE_4M.secboot.fd" "OVMF_VARS_4M.ms.fd" \
    -D SECURE_BOOT_ENABLE -D SMM_REQUIRE

note "checks"
ln -sfn OVMF_CODE_4M.secboot.fd "$OUT/OVMF_CODE_4M.ms.fd"
sha256sum "$OUT"/OVMF_CODE_4M.fd "$OUT"/OVMF_CODE_4M.secboot.fd \
    "$OUT"/OVMF_VARS_4M.fd "$OUT"/OVMF_VARS_4M.ms.fd

cat <<EOF
-- images in $OUT
   Install by copying them to share/firmware/OVMF and rerunning install.sh,
   or pass OUT_DIR=share/firmware/OVMF explicitly.
   Expected silence: a normal boot stays black; with no bootable device the
   firmware still prints "No bootable option or device was found."
EOF
