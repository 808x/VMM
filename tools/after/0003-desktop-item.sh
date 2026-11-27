#!/bin/bash
# VMM_PAGE: after
# VMM_FLAG: desktop-item
# VMM_NAME: Create .desktop launcher item
# VMM_VAR: launchitem
# VMM_TICK: yes
# VMM_PHASE: post
# VMM_DESC: Write vmm.desktop so the app appears in the desktop menu.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

prefix=$(vmm_prefix)
if [ ! -x "$prefix/launch.sh" ]; then
    warn "no launcher at $prefix/launch.sh; skipping desktop item"
    exit 0
fi
dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$dir" || { warn "cannot create $dir"; exit 0; }
cat > "$dir/vmm.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=VMM
Comment=Launch the VMM QEMU/virt-manager profile
Exec=$prefix/launch.sh
Icon=$prefix/share/icons/vmm.png
Terminal=false
Categories=System;Emulator;
StartupWMClass=virt-manager
EOF
note "wrote $dir/vmm.desktop"
