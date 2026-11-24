#!/bin/bash
# Build and install the virt-manager profile.
#
# usage: tools/build-vm.sh SRC BUILD_DIR PREFIX JOBS [PATCH_GROUP...]
#
# SRC           virt-manager source tree
# BUILD_DIR     meson build directory
# PREFIX        install prefix
# JOBS          parallel build jobs
# PATCH_GROUP   zero or more groups: pci-menu usb-cache usb-menu reparent
#
# Applies patches, runs meson + ninja, installs, and copies the
# patched Python modules into the prefix.  Exits non-zero on failure.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: build-vm.sh SRC BUILD_DIR PREFIX JOBS [PATCH_GROUP...]}"
BUILD_DIR="${2:?missing build dir}"
PREFIX="${3:?missing prefix}"
JOBS="${4:-$(nproc 2>/dev/null || echo 4)}"
shift 4
PATCH_GROUPS=("$@")

note() { echo "-- $*"; }
die() { echo "build-vm: $*" >&2; exit 1; }

[ -d "$SRC" ] || die "missing virt-manager source: $SRC"

# Apply virt-manager patches inline.
if [ ${#PATCH_GROUPS[@]} -gt 0 ]; then
    note "vm patches: ${PATCH_GROUPS[*]}"
    PATCH_DIR="$DIR/patches/virt-manager"
    MODULES="$PATCH_DIR/modules"
    # Resolve DEPS: auto-enable any dependency flags listed in patch metadata.
    resolved=()
    for g in "${PATCH_GROUPS[@]}"; do
        [ -n "$g" ] || continue
        resolved+=("$g")
        for f in "$PATCH_DIR"/*.patch; do
            [ -e "$f" ] || continue
            fflag=""; fdeps="-"
            while IFS= read -r line; do
                case "$line" in
                    "# VMM_FLAG:"*) fflag="${line#*VMM_FLAG:}"; fflag="${fflag# }" ;;
                    "# VMM_DEPS:"*) fdeps="${line#*VMM_DEPS:}"; fdeps="${fdeps# }" ;;
                esac
            done < "$f"
            [ "$fflag" = "$g" ] || continue
            if [ "$fdeps" != "-" ]; then
                oldifs="$IFS"; IFS=','
                for d in $fdeps; do
                    [ -n "$d" ] || continue
                    case " ${resolved[*]} " in *" $d "*) ;; esac
                    resolved+=("$d")
                done
                IFS="$oldifs"
            fi
        done
    done
    # Deduplicate while preserving order.
    uniq=()
    for g in "${resolved[@]}"; do
        case " ${uniq[*]} " in *" $g "*) ;; *) uniq+=("$g") ;; esac
    done
    PATCH_GROUPS=("${uniq[@]}")

    for g in "${PATCH_GROUPS[@]}"; do
        found=""
        for f in "$PATCH_DIR"/*.patch; do
            [ -e "$f" ] || continue
            fflag=""
            while IFS= read -r line; do
                case "$line" in
                    "# VMM_FLAG:"*) fflag="${line#*VMM_FLAG:}"; fflag="${fflag# }" ;;
                esac
            done < "$f"
            [ "$fflag" = "$g" ] || continue
            found="$f"
            break
        done
        [ -n "$found" ] || { echo "build-vm: no patch file for flag $g" >&2; exit 1; }
        if grep -qx "$g" "$SRC/.vmm-groups" 2>/dev/null; then
            echo "$g already applied"
            continue
        fi
        ( cd "$SRC" && git apply --whitespace=nowarn "$found" ) ||
            { echo "build-vm: failed to apply $found" >&2; exit 1; }
        printf '%s\n' "$g" >> "$SRC/.vmm-groups"
        echo "applied $g"
    done
fi

# Meson setup (reuse existing build dir if possible).
if [ -f "$BUILD_DIR/build.ninja" ]; then
    if ! meson setup --reconfigure "$BUILD_DIR" "$SRC" \
            --prefix="$PREFIX" --buildtype=release; then
        note "stale virt-manager build dir; recreating"
        rm -rf "$BUILD_DIR"
    fi
fi
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    meson setup "$BUILD_DIR" "$SRC" \
        --prefix="$PREFIX" --buildtype=release || die "meson setup failed"
fi

# Build and install.
local_log="$BUILD_DIR/build.log"
mkdir -p "$(dirname "$local_log")"
CFLAGS="${VMM_CFLAGS:-}" CXXFLAGS="${VMM_CXXFLAGS:-}" \
    ninja -C "$BUILD_DIR" -j "$JOBS" 2>&1 | tee "$local_log" || die "ninja build failed"
CFLAGS="${VMM_CFLAGS:-}" CXXFLAGS="${VMM_CXXFLAGS:-}" \
    ninja -C "$BUILD_DIR" install 2>&1 | tee -a "$local_log" ||
    die "ninja install failed"

# Copy patched Python modules.
DEST="$PREFIX/share/virt-manager/virtManager"
MODS="$DIR/patches/virt-manager/modules"
[ -d "$DEST" ] || die "virt-manager install tree missing: $DEST"
for g in "${PATCH_GROUPS[@]}"; do
    case "$g" in
        pci-menu)   install -m 0644 "$MODS/pci_redirect.py" "$DEST/" ;;
        usb-cache|usb-menu) install -m 0644 "$MODS/usb_redirect.py" "$DEST/" ;;
        reparent)   install -m 0644 "$MODS/gtk_embed.py" "$DEST/details/" ;;
    esac
done

note "virt-manager installed to $PREFIX"
