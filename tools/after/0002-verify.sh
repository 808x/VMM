#!/bin/bash
# VMM_PAGE: after
# VMM_FLAG: verify
# VMM_NAME: Verify installation
# VMM_VAR: verify
# VMM_PHASE: post
# VMM_DESC: Check the launcher, QEMU and firmware paths after install.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

prefix=$(vmm_prefix)
rc=0
section "verify"

if [ -x "$prefix/bin/vmm-qemu" ]; then
    "$prefix/bin/vmm-qemu" -version 2>/dev/null | head -1 || rc=1
fi
if [ -x "$prefix/launch.sh" ]; then
    note "launcher: $prefix/launch.sh"
else
    warn "launcher missing: $prefix/launch.sh"
    rc=1
fi
if [ -d "$prefix/firmware/OVMF" ]; then
    for f in OVMF_CODE_4M.fd OVMF_VARS_4M.fd; do
        [ -e "$prefix/firmware/OVMF/$f" ] ||
            { warn "firmware missing: $prefix/firmware/OVMF/$f"; rc=1; }
    done
fi
if [ -e "$prefix/state/qemu" ] || [ -d "$prefix/qemu" ]; then
    note "qemu: $prefix/state/qemu"
fi
[ "$rc" = 0 ] && note "verify: ok" || warn "verify: issues above"
