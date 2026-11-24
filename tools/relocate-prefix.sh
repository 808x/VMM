#!/bin/bash
# Make an installed prefix relocatable by rewriting paths that the
# upstream installers baked in at build time.  Idempotent: it can be run
# after every install, and on a partial prefix.
#
# usage: tools/relocate-prefix.sh PREFIX
set -u

PREFIX="${1:-}"
if [ -z "$PREFIX" ]; then
    echo "usage: relocate-prefix.sh PREFIX" >&2
    exit 2
fi
[ -d "$PREFIX" ] || {
    echo "relocate-prefix: no such prefix: $PREFIX" >&2
    exit 1
}
PREFIX="$(cd "$PREFIX" && pwd)"

# ---------------------------------------------------------------- wrappers
# Upstream's wrapper generator expands the build-time share path.  Derive
# it from the wrapper's own realpath instead so renames keep working.
write_wrapper() {
    local path="$1" pkg="$2" mod="$3" tmp
    [ -f "$path" ] || return 0
    # A linked binary wrapper is not an installed upstream module.
    grep -q 'VMM linked virt-manager' "$path" && return 0
    tmp="$(mktemp "${path}.XXXXXX")" || return 1
    cat > "$tmp" <<EOF
#!/usr/bin/env python3

import os
import sys
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
    "share", "virt-manager"))
from $pkg import $mod

$mod.runcli()
EOF
    chmod 0755 "$tmp" && mv -f "$tmp" "$path"
}

write_wrapper "$PREFIX/bin/virt-manager" virtManager virtmanager
write_wrapper "$PREFIX/bin/virt-install" virtinst virtinstall
write_wrapper "$PREFIX/bin/virt-clone" virtinst virtclone
write_wrapper "$PREFIX/bin/virt-xml" virtinst virtxml

# ---------------------------------------------------------- virt-manager cfg
# buildconfig.py joins the prefix from build.cfg (an absolute build path)
# with share/.  The installed tree always has the same layout, so derive
# the prefix from this file and ignore the baked value.
bc="$PREFIX/share/virt-manager/virtinst/buildconfig.py"
if [ -f "$bc" ] && ! grep -q 'VMM relocatable prefix' "$bc"; then
    cat >> "$bc" <<'EOF'

# VMM relocatable prefix: the installed tree is self-contained, so the
# prefix follows this file wherever the directory is moved.  build.cfg's
# build-time value is intentionally not used.
BuildConfig._set_paths_by_prefix(
    os.path.abspath(os.path.join(
        os.path.dirname(_filepath), os.pardir, os.pardir, os.pardir)))
EOF
fi

cfg="$PREFIX/share/virt-manager/virtinst/build.cfg"
if [ -f "$cfg" ]; then
    sed -i '/^[[:space:]]*prefix[[:space:]]*=/d' "$cfg"
fi

# ------------------------------------------------------------- qemu assets
# Firmware descriptors live in qemu/share/qemu/firmware and reference the
# images one directory up.  Collapse whatever build-time prefix was baked
# in to a descriptor-relative path so the tree can move as a unit.
fwdir="$PREFIX/qemu/share/qemu/firmware"
if [ -d "$fwdir" ]; then
    sed -i -E 's#("(filename|template)": ").*/qemu/share/qemu/#\1../#' \
        "$fwdir"/*.json 2>/dev/null || true
fi

# vhost-user helpers are resolved through PATH by the launcher.
vh="$PREFIX/qemu/share/qemu/vhost-user"
if [ -d "$vh" ]; then
    sed -i -E 's#("binary": ").*/#\1#' "$vh"/*.json 2>/dev/null || true
fi

exit 0
