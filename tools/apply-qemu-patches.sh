#!/bin/bash
# Apply the QEMU series to a source tree.
#
# usage: tools/apply-qemu-patches.sh TREE [VMVGA_DIR] [GROUP...]
#
# Groups: vmvga (source overlay), spice-virgl, resolution, gtk-egl.
# With no groups all four are applied; pass "none" to apply nothing.
# The resolution patch edits files the vmvga overlay provides, so selecting
# resolution also requires vmvga.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: apply-qemu-patches.sh TREE [VMVGA_DIR] [GROUP...]}"
shift

SRC="${1:-$DIR/src/qemu-vmvga}"
case "$SRC" in
    -*|"") SRC="$DIR/src/qemu-vmvga" ;;
    *) shift ;;
esac

groups=("$@")
if [ ${#groups[@]} -eq 0 ]; then
    groups=(vmvga spice-virgl resolution gtk-egl)
fi

has() {
    local g
    for g in "${groups[@]}"; do
        case "$g" in
            no|none|-) return 1 ;;
        esac
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

if has vmvga; then
    [ -d "$SRC/hw" ] || {
        echo "apply-qemu: vmvga source not found at $SRC" >&2
        exit 1
    }
    "$DIR/tools/apply-vmvga.sh" "$TREE" "$SRC"
fi

for g in spice-virgl resolution gtk-egl; do
    has "$g" || continue
    case "$g" in
        spice-virgl) n=0001-spice-virgl.patch ;;
        resolution)  n=0002-resolution.patch ;;
        gtk-egl)     n=0003-gtk-egl.patch ;;
    esac
    p="$DIR/patches/qemu/$n"
    [ -f "$p" ] || { echo "apply-qemu: missing $n" >&2; exit 1; }
    # The resolution patch edits the overlay's files.
    if [ "$g" = resolution ] && ! has vmvga && \
       [ -d "$DIR/src/qemu-vmvga/hw" ]; then
        echo "apply-qemu: resolution needs the vmvga overlay; enabling it" >&2
        "$DIR/tools/apply-vmvga.sh" "$TREE" "$SRC"
        groups+=(vmvga)
    fi
    # The vmvga overlay rewrites hw/ on every run, so a marker can be
    # stale even though the group was applied earlier.  Trust the tree,
    # not the marker: a patch that reverses cleanly is already present.
    if ( cd "$TREE" && git apply --reverse --check "$DIR/patches/qemu/$n" ) >/dev/null 2>&1; then
        echo "qemu/$g already applied"
        grep -qx "$g" "$TREE/.vmm-groups-qemu" 2>/dev/null ||
            printf '%s\n' "$g" >> "$TREE/.vmm-groups-qemu"
        continue
    fi
    ( cd "$TREE" && git apply --whitespace=nowarn "$DIR/patches/qemu/$n" )
    if ! grep -qx "$g" "$TREE/.vmm-groups-qemu" 2>/dev/null; then
        printf '%s\n' "$g" >> "$TREE/.vmm-groups-qemu"
    fi
    echo "applied qemu/$g"
done
