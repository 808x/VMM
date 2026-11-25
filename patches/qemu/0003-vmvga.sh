#!/bin/bash
# VMM_PAGE: qemu
# VMM_FLAG: vmvga
# VMM_NAME: VMware SVGA 3D support
# VMM_DESC: vmvga overlay for host-driven 3D in guests.
# VMM_TICK: yes
# VMM_SOURCE: vmvga
set -eu
TREE="${1:?usage: vmvga.sh TREE}"
SRC="${VMM_SOURCE_DIR:-}"
[ -d "$TREE/hw" ] || { echo "vmvga: $TREE is not a QEMU tree" >&2; exit 1; }
[ -d "$SRC/hw" ] || { echo "vmvga: source missing at ${SRC:-<unset>}" >&2; exit 1; }
cp -a "$SRC/hw/." "$TREE/hw/"
echo "merged vmvga overlay from $SRC"
