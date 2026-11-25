#!/bin/bash
# VMM_PAGE: host
# VMM_FLAG: session-vfio
# VMM_NAME: Session VFIO helper (host-global)
# VMM_DESC: Install /usr/local/sbin/vmm-vfio-ctl, a udev rule and sudoers entry.
# VMM_SUDO: yes
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

root=$(vmm_root)
helper="$root/share/bin/vmm-vfio-ctl"
[ -f "$helper" ] || die "share/bin/vmm-vfio-ctl is not present"

note "installing vfio helper (host-global, opt-in)"
install -d /usr/local/sbin
install -m 0755 "$helper" /usr/local/sbin/vmm-vfio-ctl
cat > /etc/sudoers.d/vmm-vfio <<'EOF'
# Installed by VMM-git --tool=session-vfio. Grants device bind/unbind only.
%libvirt ALL=(root) NOPASSWD: /usr/local/sbin/vmm-vfio-ctl
EOF
chmod 0440 /etc/sudoers.d/vmm-vfio
cat > /etc/udev/rules.d/60-vmm-vfio.rules <<'EOF'
SUBSYSTEM=="vfio", MODE="0666"
EOF
udevadm control --reload-rules 2>/dev/null || true
note "vfio helper installed; this grants libvirt-group users device control"
