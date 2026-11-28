#!/bin/bash
# Launch the VMM virt-manager fork from this prefix.
set -u

# sudo must not own the session: re-exec as the invoking user with their
# display and runtime dir, before any file or desktop entry is written.
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    u=$SUDO_USER
    home=$(getent passwd "$u" | cut -d: -f6)
    uid=$(id -u "$u")
    [ -n "$home" ] || home="/home/$u"
    export XDG_RUNTIME_DIR="/run/user/$uid"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    exec sudo -u "$u" -H env \
        HOME="$home" \
        DISPLAY="${DISPLAY:-:0}" \
        XAUTHORITY="${XAUTHORITY:-$home/.Xauthority}" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        VMM_ROOT="${VMM_ROOT:-}" \
        "$0" "$@"
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DIR"
# When launch.sh is copied to the install root (filesystems without symlink
# support), the real prefix lives alongside it; cd into it so relative
# profile/config paths and the desktop Exec= rewrite resolve correctly.
if [ -d "$DIR/prefix" ]; then
    cd "$DIR/prefix" || exit 1
    PREFIX="$(pwd)"
fi
[ -f "$PREFIX/profile.conf" ] && . "$PREFIX/profile.conf"

# Keep the desktop entry pointing here after the prefix is moved.  The
# entry lives outside the tree (XDG data dir) and install.sh writes it with
# an absolute path, so re-point it at this copy on startup.  No-op when the
# entry is absent (launchitem was not selected) or already correct.
desktop="${XDG_DATA_HOME:-$HOME/.local/share}/applications/vmm.desktop"
if [ -f "$desktop" ] && ! grep -qxF "Exec=$PREFIX/launch.sh" "$desktop"; then
    tmp="$desktop.vmm.$$"
    if awk -v ex="Exec=$PREFIX/launch.sh" '
        BEGIN { done = 0 }
        /^Exec=/ { print ex; done = 1; next }
        { print }
        END { if (!done) print ex }
    ' "$desktop" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$desktop"
    else
        rm -f "$tmp"
    fi
fi

if [ ! -x "$PREFIX/bin/virt-manager" ]; then
    echo "launch: no virt-manager in $PREFIX/bin; run ./install.sh --virtmgr:bin=compile" >&2
    exit 1
fi

# Keep virt-manager's log/cache inside the prefix, owned by the user running
# this launcher.  Avoids stale root-owned ~/.cache/virt-manager from sudo runs.
export XDG_CACHE_HOME="${VMM_CACHE_DIR:-$PREFIX/cache}"
mkdir -p "$XDG_CACHE_HOME" 2>/dev/null ||
    echo "launch: cannot create cache dir $XDG_CACHE_HOME" >&2

export GSETTINGS_SCHEMA_DIR="$PREFIX/share/glib-2.0/schemas${GSETTINGS_SCHEMA_DIR:+:$GSETTINGS_SCHEMA_DIR}"
export PYTHONPATH="$PREFIX/share/virt-manager${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -x "$PREFIX/libexec/virgl_render_server" ] &&
    export RENDER_SERVER_EXEC_PATH="$PREFIX/libexec/virgl_render_server"

if [ -z "${VK_DRIVER_FILES:-}" ]; then
    for f in /usr/share/vulkan/icd.d/*.json; do
        [ -e "$f" ] || continue
        case "$f" in *lvp_*|*virtio*) ;; *)
            VK_DRIVER_FILES="${VK_DRIVER_FILES:+$VK_DRIVER_FILES:}$f" ;;
        esac
    done
    export VK_DRIVER_FILES
fi

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if [ "${GDK_BACKEND:-}" != "x11" ]; then
        echo "launch: Wayland session detected; forcing GDK_BACKEND=x11" >&2
        echo "launch: X11 reparent needs XWayland, and scaling is per-monitor" >&2
    fi
    export GDK_BACKEND=x11
fi

RUN_DIR="${VMM_RUN_DIR:-$PREFIX/run}"
mkdir -p "$RUN_DIR" "$PREFIX/state"
exec 9>"$RUN_DIR/instance.lock"
if ! flock -n 9; then
    echo "launch: already running" >&2
    if command -v wmctrl >/dev/null; then
        wmctrl -a "Virtual Machine" 2>/dev/null || true
    elif command -v xdotool >/dev/null; then
        xdotool search --name "Virtual Machine" windowactivate 2>/dev/null || true
    fi
    exit 0
fi

if [ ! -x "$PREFIX/bin/qemu-system-x86_64" ] &&
   [ ! -x "$PREFIX/qemu/bin/qemu-system-x86_64" ] &&
   [ ! -x "$PREFIX/state/qemu" ] &&
   ! command -v qemu-system-x86_64 >/dev/null; then
    echo "launch: no QEMU configured; run ./install.sh --qemu:bin=compile" >&2
fi

# Slot the current profile.conf values into the existing domain definitions.
# The template is only used at install time for the first define; launch never
# rebuilds a domain from it.
if [ -z "${VMM_NO_SYNC:-}" ] && [ -x "$PREFIX/bin/vmm-define" ] &&
   [ -f "$PREFIX/profile.conf" ] && command -v virsh >/dev/null 2>&1; then
    "$PREFIX/bin/vmm-define" --sync ||
        echo "launch: profile sync failed; continuing" >&2
fi

exec "$PREFIX/bin/virt-manager" "$@"
