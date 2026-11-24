#!/bin/bash
# Apply virt-manager groups to a source tree.
#
# usage: tools/patch-vmgr.sh TREE [GROUP...]
#
# New modules live in patches/virt-manager/modules and are copied, so the
# patch files stay insertion-only edits of upstream files.  install.sh uses
# the same mapping.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: patch-vmgr.sh TREE [GROUP...]}"
shift

groups=("$@")
if [ ${#groups[@]} -eq 0 ]; then
    groups=(pci-menu usb-cache usb-menu reparent)
fi

has() {
    local g
    for g in "${groups[@]}"; do
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

P="$DIR/patches/virt-manager"

for g in pci-menu usb-cache usb-menu reparent; do
    has "$g" || continue
    patch=$(ls "$P"/*-"$g".patch 2>/dev/null) || {
        echo "patch-vmgr: missing patch for $g" >&2
        exit 1
    }
    case "$g" in
        pci-menu)
            cp "$P/modules/pci_redirect.py" "$TREE/virtManager/"
            ;;
        usb-cache)
            cp "$P/modules/usb_redirect.py" "$TREE/virtManager/"
            ;;
        reparent)
            cp "$P/modules/gtk_embed.py" "$TREE/virtManager/details/"
            ;;
    esac
    if grep -qx "$g" "$TREE/.vmm-groups" 2>/dev/null; then
        echo "$g already applied"
        continue
    fi
    ( cd "$TREE" && git apply --whitespace=nowarn "$patch" )
    printf '%s\n' "$g" >> "$TREE/.vmm-groups"
    echo "applied $g"
done
