#!/bin/bash
# QEMU launcher for libvirt.  The domain emulator points here so the
# profile, render server, shim and Vulkan ICD filter travel with the tree.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$(dirname "$BIN")"

[ -f "$PREFIX/profile.conf" ] && . "$PREFIX/profile.conf"

if [ -x "$PREFIX/state/qemu" ]; then
    QEMU="$PREFIX/state/qemu"
elif [ -x "$PREFIX/qemu/bin/qemu-system-x86_64" ]; then
    QEMU="$PREFIX/qemu/bin/qemu-system-x86_64"
else
    QEMU="$(command -v qemu-system-x86_64)" || {
        echo "vmm-qemu: no QEMU at $PREFIX/qemu or in PATH" >&2
        exit 1
    }
fi

# vhost-user helper descriptors name the binary without a path.
export PATH="$PREFIX/qemu/bin:$PREFIX/qemu/libexec${PATH:+:$PATH}"

export LD_LIBRARY_PATH="$PREFIX/qemu/lib:$PREFIX/qemu/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -x "$PREFIX/qemu/libexec/virgl_render_server" ] &&
    export RENDER_SERVER_EXEC_PATH="$PREFIX/qemu/libexec/virgl_render_server"
[ -f "$PREFIX/libexec/qemu-embed-shim.so" ] &&
    export LD_PRELOAD="$PREFIX/libexec/qemu-embed-shim.so${LD_PRELOAD:+:$LD_PRELOAD}"

if [ -z "${VK_DRIVER_FILES:-}" ]; then
    for f in /usr/share/vulkan/icd.d/*.json; do
        [ -e "$f" ] || continue
        case "$f" in *lvp_*|*virtio*) ;; *)
            VK_DRIVER_FILES="${VK_DRIVER_FILES:+$VK_DRIVER_FILES:}$f" ;;
        esac
    done
    export VK_DRIVER_FILES
fi

# libvirtd strips the session environment; the gtk,gl=on display needs X.
export DISPLAY="${DISPLAY:-:0.0}"
export XAUTHORITY="${XAUTHORITY:-${HOME:-}/.Xauthority}"
export GDK_BACKEND=x11
export VIRTMGR_HIDE_WINDOW=1

if [ -d "$PREFIX/qemu/share/qemu" ]; then
    exec "$QEMU" "$@" -L "$PREFIX/qemu/share/qemu"
fi
exec "$QEMU" "$@"
