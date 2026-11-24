#!/bin/bash
# Build the QEMU profile from prepared sources.
#
# usage: tools/build-qemu.sh PREFIX QEMU_SRC VMVGA_SRC VIRGL_SRC DXVK_TARBALL
#
# QEMU_SRC is a clean QEMU tree (patched in place).  VIRGL_SRC must be at
# the locked commit and include subprojects/venus-protocol-*.  The build
# tree lives under build/ and never touches PREFIX until install.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${1:?usage: build-qemu.sh PREFIX QEMU_SRC VMVGA_SRC VIRGL_SRC DXVK_TARBALL}"
QEMU_SRC="${2:?}"
VMVGA_SRC="${3:?}"
VIRGL_SRC="${4:?}"
DXVK_TARBALL="${5:?}"
JOBS="${JOBS:-$(nproc)}"
BUILD="$DIR/build"
VIRGL_PREFIX="$BUILD/virgl-prefix"
VIRGL_BUILD="$BUILD/virgl-build"
QEMU_BUILD="$BUILD/qemu-build"
QEMU_SRC_REAL="$(cd "$QEMU_SRC" && pwd)"
VIRGL_SRC_REAL="$(cd "$VIRGL_SRC" && pwd)"

mkdir -p "$BUILD" "$VIRGL_PREFIX" "$PREFIX"

# Use VMM_CFLAGS/VMM_CXXFLAGS from install.sh (include diagnostic flags).
# If not set, default to empty (project defaults).
# Strip unsupported diagnostic flags that older GCC doesn't recognize.
VMM_CFLAGS="${VMM_CFLAGS:-}"
VMM_CXXFLAGS="${VMM_CXXFLAGS:-}"
VMM_CFLAGS=$(echo "$VMM_CFLAGS" | sed 's/-fno-diagnostics-show-source-lines//g; s/-fno-diagnostics-show-event-links//g')
VMM_CXXFLAGS=$(echo "$VMM_CXXFLAGS" | sed 's/-fno-diagnostics-show-source-lines//g; s/-fno-diagnostics-show-event-links//g')

note() { echo "-- $*"; }

note "virglrenderer"
if [ ! -f "$VIRGL_PREFIX/lib/x86_64-linux-gnu/pkgconfig/virglrenderer.pc" ] ||
   [ "$(cat "$VIRGL_PREFIX/.vmm-source" 2>/dev/null)" != "$VIRGL_SRC_REAL" ] ||
   [ "$(cat "$VIRGL_PREFIX/.vmm-prefix" 2>/dev/null)" != "$VIRGL_PREFIX" ]; then
    # A moved tree leaves absolute paths in the .pc file; rebuild it.
    rm -rf "$VIRGL_BUILD" "$VIRGL_PREFIX"
    mkdir -p "$VIRGL_PREFIX"
    CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
    meson setup "$VIRGL_BUILD" "$VIRGL_SRC" \
        --prefix="$VIRGL_PREFIX" --buildtype=release -Dvenus=true
    CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
    ninja -C "$VIRGL_BUILD" -j "$JOBS"
    CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
    ninja -C "$VIRGL_BUILD" install
    printf '%s\n' "$VIRGL_SRC_REAL" > "$VIRGL_PREFIX/.vmm-source"
    printf '%s\n' "$VIRGL_PREFIX" > "$VIRGL_PREFIX/.vmm-prefix"
fi
export PKG_CONFIG_PATH="$VIRGL_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$VIRGL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LDFLAGS="-L$VIRGL_PREFIX/lib/x86_64-linux-gnu -L$VIRGL_PREFIX/lib ${LDFLAGS:-}"
export CPPFLAGS="-I$VIRGL_PREFIX/include ${CPPFLAGS:-}"

note "qemu patches"
QEMU_GROUPS="${QEMU_GROUPS:-vmvga,spice-virgl,resolution,gtk-egl}"
qemu_group_args=()
qemu_ifs="$IFS"
IFS=,
for g in $QEMU_GROUPS; do
    [ -n "$g" ] && qemu_group_args+=("$g")
done
IFS="$qemu_ifs"
[ ${#qemu_group_args[@]} -gt 0 ] || qemu_group_args=(none)
"$DIR/tools/apply-qemu-patches.sh" "$QEMU_SRC" "$VMVGA_SRC" "${qemu_group_args[@]}"

qemu_has_group() {
    local g
    for g in "${qemu_group_args[@]}"; do
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

note "qemu configure (-Dsdl=disabled)"
if [ -f "$QEMU_BUILD/build.ninja" ] &&
   { [ "$(cat "$QEMU_BUILD/.vmm-prefix" 2>/dev/null)" != "$PREFIX" ] ||
     [ "$(cat "$QEMU_BUILD/.vmm-source" 2>/dev/null)" != "$QEMU_SRC_REAL" ]; }; then
    note "prefix or source moved; reconfiguring qemu build"
    rm -rf "$QEMU_BUILD"
fi
if [ ! -f "$QEMU_BUILD/build.ninja" ]; then
    mkdir -p "$QEMU_BUILD"
    ( cd "$QEMU_BUILD" && CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
        "$QEMU_SRC/configure" \
        --prefix="$PREFIX" \
        --target-list=x86_64-softmmu \
        --enable-gtk --enable-opengl --enable-virglrenderer --enable-spice \
        --disable-sdl --disable-docs --disable-werror )
    printf '%s\n' "$PREFIX" > "$QEMU_BUILD/.vmm-prefix"
    printf '%s\n' "$QEMU_SRC_REAL" > "$QEMU_BUILD/.vmm-source"
fi
CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
ninja -C "$QEMU_BUILD" -j "$JOBS"
CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
ninja -C "$QEMU_BUILD" install

note "dxvk-native"
DXVK_STAGE="$BUILD/dxvk"
if [ ! -d "$DXVK_STAGE/usr/lib" ]; then
    mkdir -p "$DXVK_STAGE"
    tar -xzf "$DXVK_TARBALL" -C "$DXVK_STAGE"
fi
note "runtime libs"
mkdir -p "$PREFIX/lib" "$PREFIX/libexec"
cp -a "$VIRGL_PREFIX"/lib/x86_64-linux-gnu/libvirglrenderer.so* "$PREFIX/lib/"
cp -a "$VIRGL_PREFIX"/libexec/. "$PREFIX/libexec/"
cp -a "$DXVK_STAGE"/usr/lib/libdxvk_*.so* "$PREFIX/lib/" 2>/dev/null || \
    cp -a "$DXVK_STAGE"/usr/lib/libdxvk_*.so* "$PREFIX/lib64/"

note "rpath"
for bin in "$PREFIX/bin/qemu-system-x86_64" "$PREFIX/libexec/virgl_render_server"; do
    [ -f "$bin" ] || continue
    patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../lib/x86_64-linux-gnu' "$bin"
done

note "checks"
"$PREFIX/bin/qemu-system-x86_64" -version
if qemu_has_group vmvga; then
    "$PREFIX/bin/qemu-system-x86_64" -L "$PREFIX/share/qemu" -device vmvga,help >/dev/null
fi
"$PREFIX/bin/qemu-system-x86_64" -L "$PREFIX/share/qemu" \
    -device virtio-vga-gl,help | grep -q venus

note "profile installed at $PREFIX"
