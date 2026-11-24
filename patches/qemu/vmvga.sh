#!/bin/bash
# Overlay the vmvga device sources onto a QEMU tree.
#
# usage: patches/qemu/vmvga.sh TREE [VMVGA_DIR]
#
# Only hw/ is replaced: the vendor repo is a drop-in overlay and does not
# ship the rest of QEMU.  The lock in tools/upstreams.conf is enforced when the
# source directory is a git checkout.
#
# VMM_FLAG: vmvga
# VMM_NAME: VMware SVGA 3D support
# VMM_DESC: vmvga overlay for host-driven 3D in guests.
# VMM_DEPS: -
# VMM_TICK: yes
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: vmvga.sh TREE [VMVGA_DIR]}"
SRC="${2:-$DIR/src/qemu-vmvga}"
CONF="$DIR/tools/upstreams.conf"

[ -d "$TREE/hw" ] || { echo "vmvga.sh: $TREE is not a QEMU tree" >&2; exit 1; }
[ -d "$SRC/hw" ] || { echo "vmvga.sh: missing vmvga checkout at $SRC" >&2; exit 1; }

want=$(awk -F= '/^\[vmvga\]/{s=1} s&&/^lock[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CONF")
if [ -n "$want" ] && [ -d "$SRC/.git" ]; then
    have=$(git -C "$SRC" rev-parse HEAD)
    case "$have" in
        "$want"*) ;;
        *) echo "vmvga.sh: $SRC is $have, lock is $want (use --update)" >&2
           exit 1 ;;
    esac
fi

cp -a "$SRC/hw/." "$TREE/hw/"
echo "merged vmvga overlay from $SRC"
