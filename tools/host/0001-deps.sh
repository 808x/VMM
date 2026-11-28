#!/bin/bash
# VMM_PAGE: host
# VMM_FLAG: deps
# VMM_NAME: Install build and runtime dependencies (host-global)
# VMM_VAR: install_deps
# VMM_PHASE: early
# VMM_ARGS: --install build,runtime
# VMM_DESC: Compiler, Meson/Ninja, dev headers for build; GTK3, libvirt, SPICE, Vulkan to run.
# VMM_SUDO: yes
# VMM_POST: no
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

: "${VMM_STATE:?VMM_STATE is not set}"
deps_state="$VMM_STATE/new-deps"
runtime_state="$VMM_STATE/new-runtime-deps"

pkg_snapshot() {
    case "$(distro_id)" in
        *arch*) pacman -Qq 2>/dev/null ;;
        *debian*|*ubuntu*)
            dpkg-query -W -f='${binary:Package}\n' 2>/dev/null ;;
        *fedora*|*rhel*|*centos*)
            rpm -qa --qf '%{NAME}\n' 2>/dev/null ;;
    esac | sort -u
}

record_new_deps() {
    local before="$1" after="$2" target="$3" label="$4"
    local newf="$target.tmp.new"
    [ -n "$before" ] && [ -n "$after" ] || {
        warn "package list unavailable; dependency tally skipped"
        return 0
    }
    mkdir -p "$VMM_STATE"
    comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") |
        sed '/^$/d' > "$newf"
    [ -s "$newf" ] || { rm -f "$newf"; return 0; }
    { [ -f "$target" ] && cat "$target"; cat "$newf"; } |
        sort -u > "$target.tmp"
    mv -f "$target.tmp" "$target"
    rm -f "$newf"
    note "recorded $(wc -l < "$target") package(s) added by $label"
}

# ---------------------------------------------------------------- probes

pkg_missing=()
pkg_check() { pkg-config --exists "$1" 2>/dev/null || pkg_missing+=("$1"); }

deps_check() {
    local c
    for c in git curl tar meson ninja pkg-config python3 gcc rst2man; do
        command -v "$c" >/dev/null 2>&1 || pkg_missing+=("cmd:$c")
    done
    for p in glib-2.0 gtk+-3.0 spice-protocol spice-server gbm libdrm epoxy \
             x11 vulkan libusb-1.0 pciaccess sdl3 sdl2 glfw3; do
        pkg_check "$p"
    done
    python3 - <<'PY' 2>/dev/null || pkg_missing+=("python:gi")
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("LibvirtGLib", "1.0")
PY
}

vm_deps_check() {
    local c
    for c in git meson ninja pkg-config python3 rst2man; do
        command -v "$c" >/dev/null 2>&1 || pkg_missing+=("cmd:$c")
    done
    pkg_check glib-2.0
    pkg_check gtk+-3.0
    python3 - <<'PY' 2>/dev/null || pkg_missing+=("python:gi")
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("LibvirtGLib", "1.0")
PY
}

ovmf_deps_check() {
    local c
    for c in gcc make nasm iasl python3; do
        command -v "$c" >/dev/null 2>&1 || pkg_missing+=("cmd:$c")
    done
}

# ldconfig lives in sbin, which is not on a normal user's PATH on Debian or
# Arch.  Resolve it explicitly; otherwise every soname looks absent.
ld_cache() {
    local ld
    for ld in "$(command -v ldconfig 2>/dev/null)" \
              /usr/sbin/ldconfig /sbin/ldconfig /usr/bin/ldconfig; do
        [ -n "$ld" ] && [ -x "$ld" ] || continue
        "$ld" -p 2>/dev/null && return 0
    done
    return 1
}

have_lib() {
    local so=$1 d
    for d in /usr/lib /usr/lib64 /lib /lib64 \
             /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu \
             /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu; do
        [ -e "$d/$so" ] && return 0
    done
    return 1
}

# Runtime check: the deployed prefix loads these at run time, so test
# sonames and GI typelibs rather than -dev pkg-config files.
runtime_deps_check() {
    command -v python3 >/dev/null 2>&1 || pkg_missing+=("cmd:python3")
    if ! command -v libvirtd >/dev/null 2>&1 &&
       [ ! -x /usr/sbin/libvirtd ] && [ ! -x /usr/bin/libvirtd ]; then
        pkg_missing+=("libvirtd")
    fi
    python3 - <<'PY' 2>/dev/null || pkg_missing+=("python:gi")
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("LibvirtGLib", "1.0")
gi.require_version("SpiceClientGtk", "3.0")
PY
    local so cache
    cache=$(ld_cache) || cache=""
    for so in libgtk-3.so.0 libspice-client-gtk-3.0.so.5 \
              libgtksourceview-4.so.0 libvte-2.91.so.0 libvulkan.so.1 \
              libdrm.so.2 libepoxy.so.0 libSDL2-2.0.so.0 libSDL3.so.0 \
              libglfw.so.3 libvirt.so.0; do
        if [ -n "$cache" ]; then
            printf '%s\n' "$cache" | grep -Fq "$so" || pkg_missing+=("lib:$so")
        else
            have_lib "$so" || pkg_missing+=("lib:$so")
        fi
    done
}

missing_count() {
    case "$1" in
        qemu)         pkg_missing=(); deps_check ;;
        virt-manager) pkg_missing=(); vm_deps_check ;;
        ovmf)         pkg_missing=(); ovmf_deps_check ;;
        runtime)      pkg_missing=(); runtime_deps_check ;;
        *) die "unknown dependency target '$1'" ;;
    esac
    printf '%s' "${#pkg_missing[@]}"
}

# ---------------------------------------------------------------- install

install_build_deps() {
    local id pkgs before after
    id=$(distro_id)
    before=$(pkg_snapshot)
    case "$id" in
        *arch*)
            pkgs="base-devel git curl meson ninja pkgconf python gobject-introspection
                  gtk3 spice-protocol spice spice-gtk libusb libpciaccess libdrm libepoxy
                  mesa vulkan-icd-loader vulkan-headers libx11 libxkbcommon gettext
                  libxml2 python-gobject python-cairo libvirt libvirt-glib python-docutils
                  gtksourceview4 vte3 nasm acpica sdl3 sdl2 glfw glslang"
            as_root pacman -S --needed --noconfirm $pkgs
            ;;
        *debian*|*ubuntu*)
            pkgs="build-essential git curl meson ninja-build pkg-config python3 python3-venv
                  libglib2.0-dev libgtk-3-dev libspice-protocol-dev libspice-server-dev
                  libusb-1.0-0-dev libpciaccess-dev libdrm-dev libepoxy-dev libgbm-dev
                  libvulkan-dev libx11-dev libxkbcommon-dev gettext libxml2-dev
                  python3-gi python3-cairo gir1.2-gtk-3.0 gir1.2-libvirt-glib-1.0
                  gir1.2-spiceclientgtk-3.0 libvirt-daemon-system libvirt-clients
                  gir1.2-gtksource-4 gir1.2-vte-2.91 python3-docutils nasm acpica-tools
                  libsdl3-dev libsdl2-dev libglfw3-dev glslang-tools"
            as_root apt-get update && as_root apt-get install -y $pkgs
            ;;
        *fedora*|*rhel*|*centos*)
            pkgs="gcc gcc-c++ git curl meson ninja-build pkgconf python3-devel glib2-devel
                  gtk3-devel spice-protocol-devel spice-server-devel libusb1-devel
                  libpciaccess-devel libdrm-devel libepoxy-devel mesa-libgbm-devel
                  vulkan-loader-devel libX11-devel libxkbcommon-devel gettext
                  libxml2-devel python3-gobject python3-cairo libvirt-devel
                  libvirt-glib-devel gtksourceview4 python3-docutils nasm acpica-tools
                  SDL3-devel SDL2-devel glfw-devel glslang"
            as_root dnf install -y $pkgs
            ;;
        *) die "unknown distro; install meson, gtk3, spice, virgl and python-gi manually" ;;
    esac
    after=$(pkg_snapshot)
    record_new_deps "$before" "$after" "$deps_state" "deps"
}

install_runtime_deps() {
    local id pkgs before after
    id=$(distro_id)
    before=$(pkg_snapshot)
    case "$id" in
        *arch*)
            pkgs="python python-gobject python-cairo gtk3 spice-gtk libusb
                  libpciaccess libdrm libepoxy mesa vulkan-icd-loader libx11
                  libxkbcommon libxml2 libvirt libvirt-glib gtksourceview4 vte3
                  sdl3 sdl2 glfw pixman zlib libslirp"
            as_root pacman -S --needed --noconfirm $pkgs
            ;;
        *debian*|*ubuntu*)
            pkgs="python3 python3-gi python3-cairo gir1.2-gtk-3.0
                  gir1.2-libvirt-glib-1.0 gir1.2-spiceclientgtk-3.0
                  gir1.2-gtksource-4 gir1.2-vte-2.91 libgtk-3-0
                  libspice-client-gtk-3.0-5 libusb-1.0-0 libpciaccess0 libdrm2
                  libepoxy0 libgbm1 libvulkan1 libx11-6 libxkbcommon0 libxml2
                  libvirt-daemon-system libvirt-clients libsdl3-0 libsdl2-2.0-0
                  libglfw3 libpixman-1-0 libslirp0 zlib1g"
            as_root apt-get update && as_root apt-get install -y $pkgs
            ;;
        *fedora*|*rhel*|*centos*)
            pkgs="python3 python3-gobject python3-cairo gtk3 spice-gtk libusb1
                  libpciaccess libdrm libepoxy mesa-libgbm vulkan-loader libX11
                  libxkbcommon libxml2 libvirt libvirt-daemon-kvm
                  libvirt-daemon-config-network libvirt-glib gtksourceview4
                  vte291 SDL2 SDL3 glfw pixman zlib libslirp"
            as_root dnf install -y $pkgs
            ;;
        *) die "unknown distro; install GTK3, python3-gi, libvirt and Vulkan manually" ;;
    esac
    after=$(pkg_snapshot)
    record_new_deps "$before" "$after" "$runtime_state" "runtime deps"
}

case "${1:-}" in
    --missing)
        for t in qemu virt-manager ovmf runtime; do
            printf '%s|%s\n' "$t" "$(missing_count "$t")"
        done
        ;;
    --install)
        targets="${2:-build,runtime}"
        case ",$targets," in *,build,*)   install_build_deps ;; esac
        case ",$targets," in *,runtime,*) install_runtime_deps ;; esac
        ;;
    ""|-h|--help)
        echo "usage: 0001-deps.sh --missing | --install [build[,runtime]]" >&2
        exit 2
        ;;
    *) die "unknown argument: $1" ;;
esac
