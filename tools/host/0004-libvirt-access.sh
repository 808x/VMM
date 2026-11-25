#!/bin/bash
# VMM_PAGE: host
# VMM_FLAG: libvirt-access
# VMM_NAME: Grant libvirt access to this prefix
# VMM_DESC: Fix AppArmor rules, parent traversal and prefix ownership so libvirtd can launch the compiled QEMU.
# VMM_SUDO: yes
# VMM_POST: yes
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

prefix=$(vmm_prefix)
user=${VMM_USER:-${SUDO_USER:-root}}
note "configuring libvirt access for $prefix (owner $user)"

# Make every parent traversable for libvirt/qemu.
d=$prefix
while [ -n "$d" ] && [ "$d" != / ]; do
    [ -d "$d" ] || break
    [ "$(stat -c %A "$d" 2>/dev/null | cut -c10)" = x ] ||
        chmod o+x "$d" 2>/dev/null ||
        warn "cannot set traversal on $d"
    d=$(dirname "$d")
done

# Own the prefix by the invoking user; sudo builds otherwise leave root files.
if [ -n "$user" ] && [ "$user" != root ] && id -u "$user" >/dev/null 2>&1; then
    uid=$(id -u "$user"); gid=$(id -gn "$user")
    chown -R "$uid:$gid" "$prefix" 2>/dev/null ||
        warn "cannot chown $prefix to $user"
fi

# Session libvirtd tries to raise RLIMIT_CORE to infinity; a normal user's
# hard limit is 0, so setrlimit fails before the emulator is exec'd.
uc="/home/$user/.config/libvirt/qemu.conf"
if [ -f "$uc" ] && ! grep -qE '^[[:space:]]*max_core[[:space:]]*=' "$uc"; then
    printf '\n# VMM: avoid setrlimit(RLIM_INFINITY) under a user session.\nmax_core = 0\n' >> "$uc"
    note "set max_core = 0 in $uc"
fi

# AppArmor rules for the emulator and the data disks.
marker="# VMM prefix: $prefix"
qa=/etc/apparmor.d/local/abstractions/libvirt-qemu
ld=/etc/apparmor.d/local/usr.sbin.libvirtd
mkdir -p "$(dirname "$qa")" "$(dirname "$ld")"
if ! grep -qF "$marker" "$qa" 2>/dev/null; then
    {
        printf '%s\n' "$marker"
        printf '  "%s/**" rwklix,\n' "$prefix"
        printf '  /usr/bin/** rix,\n'
        printf '  /usr/lib/** rix,\n' 
        [ -f "$prefix/profile.conf" ] &&
            awk -F'"' '/DISK=/ && $2 ~ /^\// { print $2 }' "$prefix/profile.conf" |
            while IFS= read -r disk; do
                printf '  "%s" rwk,\n' "$disk"
                printf '  "%s/*" rwk,\n' "$(dirname "$disk")"
            done
    } >> "$qa"
    note "wrote $qa"
fi
if ! grep -qF "$marker" "$ld" 2>/dev/null; then
    printf '%s\n  "%s/**" rwklix,\n' "$marker" "$prefix" >> "$ld"
    note "wrote $ld"
fi

if command -v apparmor_parser >/dev/null 2>&1; then
    for f in /etc/apparmor.d/usr.sbin.libvirtd /etc/apparmor.d/libvirt/libvirt-*; do
        [ -f "$f" ] && apparmor_parser -r "$f" >/dev/null 2>&1 || true
    done
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl reload libvirtd >/dev/null 2>&1 || true
fi
note "libvirt access configured"
