#!/bin/bash
# VMM installer. See README.md.
# No -e: actions are checked explicitly with || die.
set -u
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$SELF_DIR"
# get.sh lays out ROOT/{install.sh -> src/install.sh, src/, prefix/}. Follow
# the link to the code root, but keep ROOT as the install root. A copied
# install.sh (no symlink support) is detected by the sibling src/tools.
if [ -L "$SELF" ] && command -v readlink >/dev/null 2>&1; then
    DIR="$(cd "$(dirname "$(readlink -f "$SELF")")" && pwd)"
elif [ -d "$SELF_DIR/src/tools" ] && [ ! -d "$SELF_DIR/tools" ]; then
    DIR="$SELF_DIR/src"
else
    DIR="$SELF_DIR"
fi
MANIFEST="$DIR/patches/manifest"
CONF="$DIR/tools/upstreams.conf"
BUILD="${VMM_BUILD_DIR:-$DIR/build}"
STATE="${VMM_STATE_DIR:-$DIR/state}"
DEPS_STATE="$STATE/new-deps"
RUNTIME_STATE="$STATE/new-runtime-deps"
DL="$BUILD/downloads"
SRC="${VMM_SRC_DIR:-$DIR/src}"

enable_vm=""
enable_qemu=""
qemu_mode="build"
qemu_bin=""
qemu_link=""
qemu_groups=""
qemu_bin_given=0
qemu_groups_given=0
vm_bin=""
vm_link=""
vm_groups=""
vm_bin_given=0
vm_groups_given=0
ovmf_bin=""
ovmf_code=""
ovmf_vars=""
ovmf_groups=""
ovmf_bin_given=0
ovmf_groups_given=0
install_deps=0
runtime_deps=0
host_deps=0
session_vfio=0
emit_domains=0
verify=0
launchitem=0
update=0
dry_run=0
list=0
clean_mode=""
clean_given=0
misc_given=0
no_clean=0
prefix="$ROOT/prefix"
# If a prefix already lives next to the installer, run from inside it; if the
# tree was copied (no symlinks) the prefix may instead be under src/.  All path
# variables above are absolute, so this chdir is safe.
if [ -d "$SELF_DIR/prefix" ]; then
    cd "$SELF_DIR/prefix"
elif [ -d "$SELF_DIR/src/prefix" ]; then
    cd "$SELF_DIR/src/prefix"
fi
jobs="$(nproc 2>/dev/null || echo 4)"
dxvk_tarball="${DXVK_NATIVE_TARBALL:-}"

menu_color=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    menu_color=1
    c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'
    if [ "${COLORTERM:-}" = truecolor ] || [ "${COLORTERM:-}" = 24bit ]; then
        c_primary=$'\033[38;2;250;178;131m'   # peach/orange
        c_secondary=$'\033[38;2;92;156;245m'  # blue
        c_accent=$'\033[38;2;157;124;216m'    # purple
        c_success=$'\033[38;2;127;216;143m'   # green
        c_warning=$'\033[38;2;229;192;123m'   # amber
        c_error=$'\033[38;2;224;108;117m'     # red
        c_info=$'\033[38;2;86;182;194m'       # cyan
        c_text=$'\033[38;2;238;238;238m'      # near-white
        c_muted=$'\033[38;2;128;128;128m'     # grey
        c_border=$'\033[38;2;72;72;72m'       # dark grey
        c_unselected=$'\033[38;2;176;176;176m'
        c_tab_bg=$'\033[48;2;250;178;131m'
        c_tab_fg=$'\033[38;2;10;10;10m'
    else
        colours=$(tput colors 2>/dev/null || echo 8)
        if [ "${colours:-8}" -ge 256 ] 2>/dev/null; then
            c_primary=$'\033[38;5;216m'
            c_secondary=$'\033[38;5;75m'
            c_accent=$'\033[38;5;141m'
            c_success=$'\033[38;5;114m'
            c_warning=$'\033[38;5;180m'
            c_error=$'\033[38;5;168m'
            c_info=$'\033[38;5;73m'
            c_text=$'\033[38;5;255m'
            c_muted=$'\033[38;5;244m'
            c_border=$'\033[38;5;238m'
            c_unselected=$'\033[38;5;250m'
            c_tab_bg=$'\033[48;5;216m'
            c_tab_fg=$'\033[38;5;232m'
        else
            c_primary=$'\033[33m'; c_secondary=$'\033[34m'
            c_accent=$'\033[35m'; c_success=$'\033[32m'
            c_warning=$'\033[33m'; c_error=$'\033[31m'
            c_info=$'\033[36m'; c_text=$'\033[37m'
            c_muted=$'\033[90m'; c_border=$'\033[90m'
            c_unselected=$'\033[37m'
            c_tab_bg=$'\033[7m'; c_tab_fg=""
        fi
    fi
    # Legacy names used by the non-menu notes and errors.
    c_cyan=$c_info; c_green=$c_success; c_yellow=$c_warning; c_red=$c_error
    c_header=$c_primary; c_item=$c_secondary; c_sub=$c_warning
    c_marker=$c_success; c_note=$c_error
else
    c_bold=""; c_dim=""; c_cyan=""; c_green=""; c_yellow=""; c_red=""
    c_header=""; c_item=""; c_sub=""; c_marker=""; c_note=""
    c_primary=""; c_secondary=""; c_accent=""; c_success=""; c_warning=""
    c_error=""; c_info=""; c_text=""; c_muted=""; c_border=""
    c_unselected=""; c_tab_bg=""; c_tab_fg=""
    c_reset=""
fi

# Build output filtering: collapse repetitive lines sharing the same prefix.
# Threshold = consecutive lines before collapsing (default 4).
# Prefix length = characters to compare (default 12).
FILTER_THRESHOLD="${VMM_FILTER_THRESHOLD:-4}"
FILTER_PREFIX_LEN="${VMM_FILTER_PREFIX_LEN:-12}"
FILTER_ENABLED="${VMM_FILTER_ENABLED:-1}"

# Compiler diagnostic flags (non-intrusive: affect output only, not codegen).
# -Wno-error: warnings non-fatal
# -Wno-macro-redefined: silence D3D8/D3D9 macro collisions (DXVK)
# Override via VMM_CFLAGS/VMM_CXXFLAGS env vars (e.g. "" to use project defaults).
VMM_DIAG_FLAGS="-Wno-error -Wno-macro-redefined"
if [ -n "${VMM_CFLAGS+x}" ] && [ -n "$VMM_CFLAGS" ]; then
    VMM_CFLAGS="$VMM_CFLAGS $VMM_DIAG_FLAGS"
else
    VMM_CFLAGS="$VMM_DIAG_FLAGS"
fi
if [ -n "${VMM_CXXFLAGS+x}" ] && [ -n "$VMM_CXXFLAGS" ]; then
    VMM_CXXFLAGS="$VMM_CXXFLAGS $VMM_DIAG_FLAGS"
else
    VMM_CXXFLAGS="$VMM_DIAG_FLAGS"
fi
export VMM_CFLAGS VMM_CXXFLAGS

filter_output() {
    # Usage: command | filter_output
    # Collapses consecutive lines sharing the same leading prefix.
    # Output format: first_line \n [... N collapsed] last_line
    local threshold="${FILTER_THRESHOLD:-4}"
    local prefix_len="${FILTER_PREFIX_LEN:-12}"
    local enabled="${FILTER_ENABLED:-1}"
    [ "$enabled" = 1 ] || { cat; return; }

    local line prefix count=0 last_prefix="" group=()
    while IFS= read -r line; do
        prefix="${line:0:prefix_len}"
        if [ "$prefix" = "$last_prefix" ] && [ -n "$prefix" ]; then
            count=$((count + 1))
            group+=("$line")
            continue
        else
            if [ "$count" -ge "$threshold" ] && [ ${#group[@]} -gt 0 ]; then
                echo "${group[0]}"
                echo "[... $((count - 1)) collapsed] ${group[-1]}"
            elif [ "$count" -gt 0 ]; then
                printf '%s\n' "${group[@]}"
            fi
            count=1
            last_prefix="$prefix"
            group=("$line")
        fi
    done
    if [ "$count" -ge "$threshold" ] && [ ${#group[@]} -gt 0 ]; then
        echo "${group[0]}"
        echo "[... $((count - 1)) collapsed] ${group[-1]}"
    elif [ "$count" -gt 0 ]; then
        printf '%s\n' "${group[@]}"
    fi
}

usage() {
cat <<EOF
usage: ./install.sh [actions]

  With no component flags on a terminal, opens the build menu.  Missing
  choices are asked there; fully specified flags run unattended.

 Components
   --qemu:bin=compile|skip|link:PATH     QEMU binary source
   --qemu:patch=LIST                    QEMU patch groups (empty = none)
   --ovmf:bin=pull|compile|link|skip    firmware source
   --ovmf:code=PATH --ovmf:vars=PATH    firmware files to link
   --ovmf:patch=LIST                    OVMF patch groups (empty = none)
   --virtmgr:bin=compile|skip|link:PATH virt-manager binary source
   --virtmgr:patch=LIST                 virt-manager patch groups

 After the build
   --deps:install                       install distro build dependencies
   --deps:runtime                       install runtime dependencies (sudo)
   --after:clean=sources|deps|all|none  post-build cleanup
   --after:misc=verify,launchitem       verification and desktop launcher
   --sessionvfio                        install the vfio helper (sudo + udev)
   --writexml                           write domain XML examples

 Other
   --update                       resolve latest upstreams and rewrite the lock
   --list-patches                 print the manifest
   --prefix=DIR                   install prefix (default: ./prefix)
   --jobs=N                       parallel build jobs (default: nproc)
   --dxvk-tarball=FILE            use this dxvk-native tarball instead of building
   --dry-run                      resolve and report, change nothing
   -h, --help

 Patch groups: see --list-patches.  Patch values accept both the manifest
 names (spice-virgl) and the compact menu names (spicevirgl).
EOF
}

die() { printf '%sERROR:%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
note() { printf '%s--%s %s\n' "$c_bold$c_cyan" "$c_reset" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
section() { printf '\n%s==>%s %s%s%s\n' "$c_bold$c_cyan" "$c_reset" "$c_bold" "$*" "$c_reset"; }

conf_get() {
    awk -F= -v s="[$1]" -v k="$2" '
        $0 == s { on = 1; next }
        /^\[/ { on = 0 }
        on && $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
            sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit
        }' "$CONF"
}

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

manifest_rows() {
    grep -vE '^[[:space:]]*(#|$)' "$MANIFEST"
}

list_patches() {
    printf '%-14s %-12s %-10s %-9s %s\n' ENGINE GROUP DEPENDS STATUS DESCRIPTION
    manifest_rows | while IFS=$'\t' read -r eng name dep status desc; do
        printf '%-14s %-12s %-10s %-9s %s\n' "$eng" "$name" "$dep" "$status" "$desc"
    done
}

groups_for() {
    manifest_rows | awk -F'\t' -v e="$1" '$1==e && $4=="feature" {print $2}'
}

validate_selection() {
    local engine="$1" sel="$2"
    local known
    known=" $(groups_for "$engine" | tr '\n' ' ') "
    local g dep d
    for g in $(echo "$sel" | tr ',' ' '); do
        case "$known" in
            *" $g "*) ;;
            *) die "unknown $engine group '$g' (see --list-patches)" ;;
        esac
    done
    for g in $(echo "$sel" | tr ',' ' '); do
        dep=$(manifest_rows | awk -F'\t' -v e="$engine" -v n="$g" '$1==e && $2==n {print $3}')
        [ "$dep" = "-" ] && continue
        for d in $(echo "$dep" | tr ',' ' '); do
            case " $(echo "$sel" | tr ',' ' ') " in
                *" $d "*) ;;
                *) die "$engine/$g requires $engine/$d" ;;
            esac
        done
    done
}

# Map a menu/flag patch value to the manifest group name.
map_group() {
    case "$1:$2" in
        qemu:vmvga) REPLY=vmvga ;;
        qemu:spicevirgl|qemu:spice-virgl) REPLY=spice-virgl ;;
        qemu:gtkegl|qemu:gtk-egl) REPLY=gtk-egl ;;
        qemu:flexresize|qemu:resolution) REPLY=resolution ;;
        virt-manager:reparent) REPLY=reparent ;;
        virt-manager:pcimenu|virt-manager:pci-menu) REPLY=pci-menu ;;
        virt-manager:usbmenu|virt-manager:usb-menu) REPLY=usb-menu ;;
        virt-manager:usbcache|virt-manager:usb-cache) REPLY=usb-cache ;;
        ovmf:logo|ovmf:nosplash) REPLY=logo ;;
        ovmf:bds|ovmf:nomessage) REPLY=bds ;;
        *:none|*:|"") REPLY="" ;;
        *) die "unknown $1 patch group '$2' (see --list-patches)" ;;
    esac
}

assign_groups() {
    local eng="$1" list="$2" var="$3" out="" g
    local IFS=,
    for g in $list; do
        [ -n "$g" ] || continue
        map_group "$eng" "$g"
        [ -n "$REPLY" ] || continue
        case ",$out," in *",$REPLY,"*) continue ;; esac
        out="${out:+$out,}$REPLY"
    done
    printf -v "$var" '%s' "$out"
}

default_groups() {
    case "$1" in
        qemu|virt-manager|ovmf) groups_for "$1" | paste -sd, ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --list-patches) list=1; shift ;;
        --qemu:bin=*)
            v="${1#*=}"; qemu_bin_given=1
            case "$v" in
                compile|skip) qemu_bin="$v" ;;
                link) qemu_bin=link ;;
                link:*) qemu_bin=link; qemu_link="${v#link:}" ;;
                *) die "--qemu:bin expects compile, skip or link:PATH" ;;
            esac; shift ;;
        --qemu:patch=*)
            assign_groups qemu "${1#*=}" qemu_groups
            qemu_groups_given=1; shift ;;
        --virtmgr:bin=*)
            v="${1#*=}"; vm_bin_given=1
            case "$v" in
                compile|skip) vm_bin="$v" ;;
                link) vm_bin=link ;;
                link:*) vm_bin=link; vm_link="${v#link:}" ;;
                *) die "--virtmgr:bin expects compile, skip or link:PATH" ;;
            esac; shift ;;
        --virtmgr:patch=*)
            assign_groups virt-manager "${1#*=}" vm_groups
            vm_groups_given=1; shift ;;
        --ovmf:bin=*)
            v="${1#*=}"; ovmf_bin_given=1
            case "$v" in
                pull|compile|link|skip) ovmf_bin="$v" ;;
                *) die "--ovmf:bin expects pull, compile, link or skip" ;;
            esac; shift ;;
        --ovmf:code=*) ovmf_code="${1#*=}"; shift ;;
        --ovmf:vars=*) ovmf_vars="${1#*=}"; shift ;;
        --ovmf:patch=*)
            assign_groups ovmf "${1#*=}" ovmf_groups
            ovmf_groups_given=1; shift ;;
        --deps:install) install_deps=1; shift ;;
        --deps:runtime) runtime_deps=1; shift ;;
        --after:clean=*)
            clean_given=1
            clean_mode="${1#*=}"
            if [ "$clean_mode" = none ]; then
                no_clean=1; clean_mode=""
            fi
            shift ;;
        --after:misc=*)
            misc_given=1; verify=0; launchitem=0
            for m in $(echo "${1#*=}" | tr ',' ' '); do
                case "$m" in
                    verify) verify=1 ;;
                    launchitem) launchitem=1 ;;
                    none|"") ;;
                    *) die "--after:misc expects verify, launchitem or none" ;;
                esac
            done; shift ;;
        --sessionvfio) session_vfio=1; shift ;;
        --writexml) emit_domains=1; shift ;;
        --update) update=1; shift ;;
        --prefix=*) prefix="${1#*=}"; shift ;;
        --jobs=*) jobs="${1#*=}"; shift ;;
        --dxvk-tarball=*) dxvk_tarball="${1#*=}"; shift ;;
        --dry-run) dry_run=1; shift ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

[ "$list" = 1 ] && { list_patches; exit 0; }
case "$clean_mode" in
    ""|sources|deps|all) ;;
    *) die "--after:clean expects sources, deps, all or none" ;;
esac
[ -f "$CONF" ] || die "missing $CONF"

# A patch or path flag implies the natural binary mode.
[ "$qemu_groups_given" = 1 ] && [ -z "$qemu_bin" ] && qemu_bin=compile
[ "$vm_groups_given" = 1 ] && [ -z "$vm_bin" ] && vm_bin=compile
[ "$ovmf_groups_given" = 1 ] && [ -z "$ovmf_bin" ] && ovmf_bin=compile
[ -n "$ovmf_code$ovmf_vars" ] && [ -z "$ovmf_bin" ] && ovmf_bin=link

finalize_modes() {
    [ "$qemu_bin" = compile ] && [ "$qemu_groups_given" = 0 ] &&
        qemu_groups=$(default_groups qemu)
    [ "$vm_bin" = compile ] && [ "$vm_groups_given" = 0 ] &&
        vm_groups=$(default_groups virt-manager)
    [ "$ovmf_bin" = compile ] && [ "$ovmf_groups_given" = 0 ] &&
        ovmf_groups=$(default_groups ovmf)
    [ "$ovmf_bin" != compile ] && [ "$ovmf_groups_given" = 0 ] &&
        ovmf_groups=""

    [ -n "$qemu_groups" ] && validate_selection qemu "$qemu_groups"
    [ -n "$vm_groups" ] && validate_selection virt-manager "$vm_groups"
    [ -n "$ovmf_groups" ] && validate_selection ovmf "$ovmf_groups"

    enable_qemu=""
    [ "$qemu_bin" = compile ] && enable_qemu="$qemu_groups"
    enable_vm=""
    [ "$vm_bin" = compile ] && enable_vm="$vm_groups"

    case "$qemu_bin" in
        compile) qemu_mode=build ;;
        link) qemu_mode="${qemu_link:-link}" ;;
        *) qemu_mode=skip ;;
    esac
    case "$ovmf_bin" in
        compile) ovmf_mode=build ;;
        pull) ovmf_mode=bundle ;;
        link) ovmf_mode=link ;;
        *) ovmf_mode=skip ;;
    esac
}

validate_paths() {
    case "$qemu_bin" in
        link)
            if [ "$qemu_link" = system ]; then
                qemu_link=$(command -v qemu-system-x86_64 2>/dev/null || true)
                [ -n "$qemu_link" ] ||
                    die "--qemu:bin=link: no system qemu-system-x86_64 found"
            fi
            [ -n "$qemu_link" ] || die "--qemu:bin=link needs a path"
            [ -x "$qemu_link" ] || die "not executable: $qemu_link"
            qemu_link=$(readlink -f "$qemu_link")
            ;;
        compile|skip|"") ;;
        *) die "--qemu:bin expects compile, skip or link:PATH" ;;
    esac
    case "$vm_bin" in
        link)
            [ -n "$vm_link" ] || die "--virtmgr:bin=link needs a path"
            [ -x "$vm_link" ] || die "not executable: $vm_link"
            vm_link=$(readlink -f "$vm_link")
            ;;
        compile|skip|"") ;;
        *) die "--virtmgr:bin expects compile, skip or link:PATH" ;;
    esac
    if [ "$ovmf_bin" = link ]; then
        [ -n "$ovmf_code" ] && [ -n "$ovmf_vars" ] ||
            die "--ovmf:bin=link needs --ovmf:code and --ovmf:vars"
        [ -f "$ovmf_code" ] || die "no such OVMF CODE file: $ovmf_code"
        [ -f "$ovmf_vars" ] || die "no such OVMF VARS file: $ovmf_vars"
        ovmf_code=$(readlink -f "$ovmf_code")
        ovmf_vars=$(readlink -f "$ovmf_vars")
    fi
}

finalize_modes

vm_lock=$(conf_get virt-manager lock)
qemu_lock=$(conf_get qemu lock)
qemu_file=$(conf_get qemu lock_file)
vmvga_lock=$(conf_get vmvga lock)
virgl_lock=$(conf_get virglrenderer lock)
dxvk_lock=$(conf_get dxvk-native lock)

for check in "virt-manager:${vm_lock#v}" "qemu:$qemu_lock" "dxvk-native:${dxvk_lock#v}"; do
    eng=${check%%:*}; got=${check#*:}; floor=$(conf_get "$eng" min)
    ver_ge "$got" "$floor" || die "$eng: resolved $got is below floor $floor"
done

note "prefix: $prefix"
note "locks: virt-manager $vm_lock, qemu $qemu_lock, vmvga ${vmvga_lock%????????????????????????}, virgl ${virgl_lock%????????????????????????}, dxvk $dxvk_lock"
[ -n "$enable_vm" ] && note "virt-manager groups: $enable_vm"
[ -n "$enable_qemu" ] && note "qemu groups: $enable_qemu ($qemu_mode)"
[ "$install_deps" = 1 ] && note "dependencies: requested"

component_given=0
[ "$qemu_bin_given$vm_bin_given$ovmf_bin_given" != 000 ] && component_given=1
other_action=0
if [ "$install_deps" = 1 ] || [ "$runtime_deps" = 1 ] ||
   [ "$session_vfio" = 1 ] ||
   [ "$emit_domains" = 1 ] || [ "$update" = 1 ] || [ -n "$clean_mode" ]; then
    other_action=1
fi

if [ "$dry_run" = 1 ]; then
    validate_paths
    [ -n "$clean_mode" ] &&
        note "dry run: would clean $clean_mode after any build"
    case ",$qemu_groups," in
        *,spice-virgl,*) [ -f "$DIR/patches/qemu/0001-spice-virgl.patch" ] ||
            die "missing patches/qemu/0001-spice-virgl.patch" ;;
    esac
    case ",$qemu_groups," in
        *,resolution,*) [ -f "$DIR/patches/qemu/0002-resolution.patch" ] ||
            die "missing patches/qemu/0002-resolution.patch" ;;
    esac
    case ",$qemu_groups," in
        *,gtk-egl,*) [ -f "$DIR/patches/qemu/0003-gtk-egl.patch" ] ||
            die "missing patches/qemu/0003-gtk-egl.patch" ;;
    esac
    for g in $(echo "$vm_groups" | tr ',' ' '); do
        ls "$DIR"/patches/virt-manager/*-"$g".patch >/dev/null 2>&1 ||
            die "missing virt-manager patch for $g"
    done
    for g in $(echo "$ovmf_groups" | tr ',' ' '); do
        case "$g" in
            logo) ;;  # blanked in place from the upstream edk2 image
            bds) [ -f "$DIR/patches/ovmf/0001-failure-only.patch" ] ||
                die "missing patches/ovmf/0001-failure-only.patch" ;;
        esac
    done
    [ -n "$qemu_file" ] || die "qemu lock_file missing (use --update)"
    note "dry run: sources, patches and locks resolve; no changes made"
    exit 0
fi

if [ -z "$qemu_bin$vm_bin$ovmf_bin" ] && \
   [ "$install_deps" = 0 ] && [ "$runtime_deps" = 0 ] && [ "$session_vfio" = 0 ] && \
   [ "$emit_domains" = 0 ] && [ "$update" = 0 ] && \
   [ "$verify" = 0 ] && [ "$launchitem" = 0 ] && \
   [ -z "$clean_mode" ] && [ ! -t 0 ]; then
    note "nothing to do (see --help)"
    exit 0
fi

# ---------------------------------------------------------------- dependencies

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

distro_id() { (. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}"); }

as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# Installed package names, sorted.  Used to diff what --deps:install added.
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
    local before="$1" after="$2" target="${3:-$DEPS_STATE}"
    local label="${4:---deps:install}" newf="$target.tmp.new"
    [ -n "$before" ] && [ -n "$after" ] || {
        warn "package list unavailable; dependency tally skipped"
        return 0
    }
    mkdir -p "$STATE"
    comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") |
        sed '/^$/d' > "$newf"
    [ -s "$newf" ] || { rm -f "$newf"; return 0; }
    { [ -f "$target" ] && cat "$target"; cat "$newf"; } |
        sort -u > "$target.tmp"
    mv -f "$target.tmp" "$target"
    rm -f "$newf"
    note "recorded $(wc -l < "$target") package(s) added by $label"
}

ask_yes() {
    local prompt="$1" def="$2" ans
    read -r -p "$prompt [$def]: " ans
    ans=${ans:-$def}
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- build menu

ovmf_find_code() {
    local f
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd \
             /usr/share/ovmf/OVMF_CODE_4M.fd \
             /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/edk2/x64/OVMF_CODE.4m.fd \
             /usr/share/ovmf/x64/OVMF_CODE.4m.fd; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
}

ovmf_find_vars() {
    local f
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd \
             /usr/share/ovmf/OVMF_VARS_4M.fd \
             /usr/share/edk2/ovmf/OVMF_VARS.fd \
             /usr/share/edk2/x64/OVMF_VARS.4m.fd \
             /usr/share/ovmf/x64/OVMF_VARS.4m.fd; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
}

menu_list_has() {
    case ",$1," in *",$2,"*) return 0 ;; esac
    return 1
}

menu_list_add() {
    if menu_list_has "$1" "$2"; then printf '%s' "$1"
    elif [ -n "$1" ]; then printf '%s,%s' "$1" "$2"
    else printf '%s' "$2"
    fi
}

menu_list_del() {
    local out="" p
    local IFS=,
    for p in $1; do
        [ "$p" = "$2" ] && continue
        out="${out:+$out,}$p"
    done
    printf '%s' "$out"
}

menu_order() {
    local list="$1" out="" p
    shift
    for p in "$@"; do
        menu_list_has "$list" "$p" && out="${out:+$out,}$p"
    done
    printf '%s' "$out"
}

menu_qemu_display() {
    local out="" p
    local IFS=,
    for p in $1; do
        case "$p" in
            spice-virgl) p=spicevirgl ;;
            gtk-egl) p=gtkegl ;;
            resolution) p=flexresize ;;
        esac
        out="${out:+$out,}$p"
    done
    printf '%s' "$out"
}

menu_vm_display() {
    local out="" p
    local IFS=,
    for p in $1; do
        case "$p" in
            pci-menu) p=pcimenu ;;
            usb-menu) p=usbmenu ;;
            usb-cache) p=usbcache ;;
        esac
        out="${out:+$out,}$p"
    done
    printf '%s' "$out"
}

menu_ovmf_display() {
    local out="" p
    local IFS=,
    for p in $1; do
        case "$p" in
            logo) p=nosplash ;;
            bds) p=nomessage ;;
        esac
        out="${out:+$out,}$p"
    done
    printf '%s' "$out"
}

menu_short_path() {
    local p="$1" base dir
    [ -n "$p" ] || { printf '<not found>'; return; }
    if [ ${#p} -le 55 ]; then printf '%s' "$p"; return; fi
    base=${p##*/}
    dir=${p%/*}
    dir=${dir%/*}
    printf '%s/.../%s' "$dir" "$base"
}

# The marker column is the right edge of the box: its last character lands
# on the same column as the end of the rule.  The flag "=" sits exactly on
# the star column of the marker.
menu_page=1
menu_pages=6
menu_mode=normal          # normal | link | sudo
menu_raw=0
menu_stty=""
MENU_COLS=100
MENU_KEY=""
MENU_DONE=0
MENU_TEXT=""
menu_signal=0
menu_subfirst=1
menu_sudo_pending=""
menu_text_active=0
menu_blocked=0
menu_revert_label=""
menu_warn=""
menu_error=""
MENU_PAGE_WARN=""

menu_calc_width() {
    local c="${COLUMNS:-}"
    [ -n "$c" ] || c=$(tput cols 2>/dev/null || true)
    case "$c" in ''|*[!0-9]*) c=100 ;; esac
    [ "$c" -gt 100 ] && c=100
    [ "$c" -lt 60 ] && c=60
    MENU_COLS=$c
}

menu_rule() {
    local n="$1" out=""
    while [ ${#out} -lt "$n" ]; do out="$out-"; done
    printf '%s' "$out"
}

menu_frame() {
    local right="page $menu_page/$menu_pages" gap
    menu_calc_width
    gap=$(( MENU_COLS - 12 - ${#right} ))
    [ "$gap" -lt 1 ] && gap=1
    printf '\n'
    printf ' %s%sVMM BUILDER%s%*s%s%s%s\n' \
        "$c_bold" "$c_primary" "$c_reset" "$gap" "" \
        "$c_border" "$right" "$c_reset"
    printf ' %s%s%s\n' "$c_border" "$(menu_rule "$((MENU_COLS - 1))")" "$c_reset"
}

menu_tabs() {
    local -a names=(QEMU OVMF VIRT-MGR HOST AFTER REVIEW)
    local i=1 n
    for n in "${names[@]}"; do
        if [ "$i" = "$menu_page" ]; then
            if [ "$menu_color" = 1 ]; then
                printf '%s%s  %s  %s' "$c_tab_bg" "$c_tab_fg" "$n" "$c_reset"
            else
                printf '  [%s]  ' "$n"
            fi
        else
            if [ "$menu_color" = 1 ]; then
                printf '%s %s %s' "$c_muted" "$n" "$c_reset"
            else
                printf ' %s ' "$n"
            fi
        fi
        i=$((i + 1))
        [ "$i" -le "${#names[@]}" ] &&
            printf '%s|%s' "$c_border" "$c_reset"
    done
    printf '\n'
}

menu_section() {
    menu_subfirst=1
    printf '\n %s%s[%s/%s]%s %s%s%s\n' \
        "$c_bold" "$c_accent" "$menu_page" "$menu_pages" "$c_reset" \
        "$c_bold$c_secondary" "$1" "$c_reset"
}

menu_subsection() {
    local label="$1" flag="${2:-}" left right pad
    if [ "$menu_subfirst" = 1 ]; then
        menu_subfirst=0
    else
        printf '\n'
    fi
    left="  ---  $label"
    if [ -n "$flag" ]; then
        right="$flag ="
        pad=$(( MENU_COLS - 1 - ${#right} ))
        [ "$pad" -lt 1 ] && pad=1
        [ ${#left} -gt "$pad" ] && left="${left:0:pad}"
        printf '%s%-*s%s%s%s%s\n' \
            "$c_bold$c_info" "$pad" "$left" "$c_reset" \
            "$c_info" "$right" "$c_reset"
    else
        printf '  ---  %s%s%s\n' "$c_bold$c_info" "$label" "$c_reset"
    fi
}

# key is three characters ("[A]") or three spaces.  The value ends at
# MENU_COLS-4 and the three-character marker ends on the last column.
menu_row() {
    local key="$1" label="$2" value="$3" mark="$4" sel="$5" pending="${6:-0}"
    local keycol labelcol valuecol markcol right avail lab pad
    if [ "$sel" = 1 ]; then
        keycol="$c_bold$c_success"; labelcol="$c_bold$c_success"
        valuecol="$c_success"; markcol="$c_success"
    elif [ "$pending" = 1 ]; then
        # Partially selected: the option is waiting on something (sudo).
        keycol="$c_bold$c_warning"; labelcol="$c_warning"
        valuecol="$c_warning"; markcol="$c_warning"
    else
        keycol="$c_accent"; labelcol="$c_unselected"
        valuecol="$c_muted"; markcol="$c_border"
    fi
    right="$value $mark"
    avail=$(( MENU_COLS - ${#right} - 7 ))
    [ "$avail" -lt 1 ] && avail=1
    lab="$label"
    [ ${#lab} -gt "$avail" ] && lab=${lab:0:$avail}
    pad=$(( avail - ${#lab} ))
    printf '  %s%-3s%s  %s%s%s%*s%s%s%s\n' \
        "$keycol" "$key" "$c_reset" "$labelcol" "$lab" "$c_reset" \
        "$pad" "" "$valuecol" "$right" "$c_reset"
}

menu_radio_mark() {
    if [ "$1" = 1 ]; then printf '(*)'; else printf '( )'; fi
}

menu_check_mark() {
    if [ "$1" = 1 ]; then printf '[*]'; else printf '[ ]'; fi
}

menu_path_line() {
    local text="$1" colour="${2:-$c_muted}"
    printf '           %s%s%s\n' "$colour" "$text" "$c_reset"
}

# A reverted link edit keeps its "Found" line yellow until the option is
# changed or the path is edited again.
menu_found_colour() {
    if [ "$menu_revert_label" = "$1" ]; then
        printf '%s' "$c_warning"
    else
        printf '%s' "$c_success"
    fi
}

menu_note() {
    local sel="${1:-0}" text="$2" colour line width=$((MENU_COLS - 9))
    if [ "$sel" = 1 ]; then colour="$c_success"; else colour="$c_muted"; fi
    [ "$width" -lt 20 ] && width=20
    printf '%s\n' "$text" | fold -s -w "$width" | while IFS= read -r line; do
        printf '         %s%s%s\n' "$colour" "$line" "$c_reset"
    done
}

menu_path_ok() { [ -n "$1" ] && [ -e "$1" ]; }

menu_deps_missing() {
    pkg_missing=()
    [ "$vm_bin" = compile ] && vm_deps_check
    [ "$qemu_bin" = compile ] && deps_check
    [ "$ovmf_bin" = compile ] && ovmf_deps_check
    printf '%s' "${#pkg_missing[@]}"
}

# A build cannot succeed without the build dependencies unless the user is
# about to grant sudo for them (host_deps=1).  While this is true the review
# and run pages are out of reach; only the component pages remain.
menu_build_blocked() {
    [ "$host_deps" = 0 ] || return 1
    [ "$(menu_deps_missing)" -gt 0 ]
}

menu_pages() {
    if { [ "$menu_page" = 4 ] || [ "$menu_page" = 6 ]; } && menu_build_blocked; then
        printf '1-3'
    else
        printf '1-6'
    fi
}

menu_toggle_qemu_group() {
    case "$1" in
        vmvga)
            if menu_list_has "$qemu_groups" vmvga; then
                qemu_groups=$(menu_list_del "$qemu_groups" vmvga)
                qemu_groups=$(menu_list_del "$qemu_groups" resolution)
            else
                qemu_groups=$(menu_list_add "$qemu_groups" vmvga)
            fi ;;
        resolution)
            if menu_list_has "$qemu_groups" resolution; then
                qemu_groups=$(menu_list_del "$qemu_groups" resolution)
            else
                qemu_groups=$(menu_list_add "$qemu_groups" resolution)
                qemu_groups=$(menu_list_add "$qemu_groups" vmvga)
            fi ;;
        spice-virgl|gtk-egl)
            if menu_list_has "$qemu_groups" "$1"; then
                qemu_groups=$(menu_list_del "$qemu_groups" "$1")
            else
                qemu_groups=$(menu_list_add "$qemu_groups" "$1")
            fi ;;
    esac
    qemu_groups=$(menu_order "$qemu_groups" vmvga spice-virgl gtk-egl resolution)
}

menu_toggle_vm_group() {
    case "$1" in
        usb-menu)
            if menu_list_has "$vm_groups" usb-menu; then
                vm_groups=$(menu_list_del "$vm_groups" usb-menu)
            else
                vm_groups=$(menu_list_add "$vm_groups" usb-menu)
                vm_groups=$(menu_list_add "$vm_groups" usb-cache)
            fi ;;
        usb-cache)
            if menu_list_has "$vm_groups" usb-cache; then
                vm_groups=$(menu_list_del "$vm_groups" usb-cache)
                vm_groups=$(menu_list_del "$vm_groups" usb-menu)
            else
                vm_groups=$(menu_list_add "$vm_groups" usb-cache)
            fi ;;
        reparent|pci-menu)
            if menu_list_has "$vm_groups" "$1"; then
                vm_groups=$(menu_list_del "$vm_groups" "$1")
            else
                vm_groups=$(menu_list_add "$vm_groups" "$1")
            fi ;;
    esac
    vm_groups=$(menu_order "$vm_groups" reparent pci-menu usb-menu usb-cache)
}

menu_toggle_ovmf_group() {
    if menu_list_has "$ovmf_groups" "$1"; then
        ovmf_groups=$(menu_list_del "$ovmf_groups" "$1")
    else
        ovmf_groups=$(menu_list_add "$ovmf_groups" "$1")
    fi
    ovmf_groups=$(menu_order "$ovmf_groups" logo bds)
}

menu_count() {
    [ -n "$1" ] || { printf '0'; return; }
    printf '%s' "$1" | tr ',' '\n' | grep -c .
}

menu_status_item() {
    local label="$1" detail="$2" colour="$3"
    if [ -n "$detail" ]; then
        printf '%s%s%s %s%s%s' "$c_bold$colour" "$label" "$c_reset" \
            "$c_muted" "$detail" "$c_reset"
    else
        printf '%s%s%s' "$c_bold$colour" "$label" "$c_reset"
    fi
}

menu_status_values() {
    case "$qemu_bin" in
        compile) MENU_Q="compile ($(menu_count "$qemu_groups")/4)" ;;
        link) MENU_Q=link ;;
        *) MENU_Q=skip ;;
    esac
    case "$ovmf_bin" in
        compile) MENU_O="compile ($(menu_count "$ovmf_groups")/2)" ;;
        link) MENU_O=link ;;
        pull) MENU_O=bundled ;;
        *) MENU_O=skip ;;
    esac
    case "$vm_bin" in
        compile) MENU_V="compile ($(menu_count "$vm_groups")/4)" ;;
        link) MENU_V=link ;;
        *) MENU_V=skip ;;
    esac
}

menu_status() {
    local plain compact=0 sep
    local q o v
    menu_status_values
    q=$MENU_Q; o=$MENU_O; v=$MENU_V
    plain="QEMU $q  |  OVMF $o  |  VM $v"
    [ $(( ${#plain} + 2 )) -gt "$MENU_COLS" ] && compact=1
    if [ "$compact" = 1 ]; then
        sep=' | '
        case "$qemu_bin" in
            compile) q="c$(menu_count "$qemu_groups")/4" ;;
            link) q=link ;;
            *) q=skip ;;
        esac
        case "$ovmf_bin" in
            compile) o="c$(menu_count "$ovmf_groups")/2" ;;
            link) o=link ;;
            pull) o=bundled ;;
            *) o=skip ;;
        esac
        case "$vm_bin" in
            compile) v="c$(menu_count "$vm_groups")/4" ;;
            link) v=link ;;
            *) v=skip ;;
        esac
        plain="QEMU $q$sep OVMF $o$sep VM $v"
        # The status strip is informative, not load-bearing; trim instead of
        # spilling past the frame on a narrow terminal.
        if [ $(( ${#plain} + 2 )) -gt "$MENU_COLS" ]; then
            plain="QEMU $q$sep OVMF $o$sep VM $v"
        fi
    else
        sep='  |  '
    fi

    printf '\n '
    menu_status_item QEMU "$q" "$c_primary"
    printf '%s%s%s' "$c_border" "$sep" "$c_reset"
    menu_status_item OVMF "$o" "$c_accent"
    printf '%s%s%s' "$c_border" "$sep" "$c_reset"
    menu_status_item VM "$v" "$c_secondary"
    printf '\n'
}

menu_key() {
    printf '%s%s%s%s%s' "$c_bold$c_info" "$1" "$c_reset" "$c_muted" "$2"
}

menu_range() {
    case "$menu_page" in
        1) if [ "$qemu_bin" = compile ]; then printf 'A-E'; else printf 'A'; fi ;;
        2) if [ "$ovmf_bin" = compile ]; then printf 'A-C'; else printf 'A'; fi ;;
        3) if [ "$vm_bin" = compile ]; then printf 'A-E'; else printf 'A'; fi ;;
        4) printf 'A-C' ;;
        5) printf 'A-D' ;;
    esac
}

menu_keys() {
    local range pages
    printf ' '
    if [ "$menu_mode" = link ]; then
        menu_key '[A]' ' Select option'
        printf '    '
        if [ "$menu_page" = 2 ]; then
            menu_key '[/]' ' Set CODE/VARS path'
        else
            menu_key '[/]' ' Set custom path'
        fi
        if [ "$menu_blocked" = 0 ]; then
            printf '    '
            menu_key '[1-6]' ' Select page'
        fi
        printf '\n'
        return
    fi
    if [ "$menu_page" = 6 ] && ! menu_build_blocked; then
        menu_key '[Enter]' ' Build'
        printf '    '
    elif [ "$menu_page" != 6 ]; then
        range=$(menu_range)
        menu_key "[$range]" ' Select option'
        printf '    '
    fi
    if [ "$menu_mode" = sudo ]; then
        printf '%s[/]%s Enter sudo password%s' \
            "$c_bold$c_warning" "$c_warning" "$c_reset"
    else
        pages=$(menu_pages)
        menu_key "[$pages]" ' Select page'
    fi
    printf '\n'
}

menu_render_qemu() {
    local sel
    menu_section "BUILD ITEMS | QEMU"
    menu_subsection "Binaries" "--qemu:bin"

    sel=0; [ "$qemu_bin" = compile ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Compile from upstream" compile "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "(Recommended) Builds a self-contained QEMU with the selected patches."

    sel=0; [ "$qemu_bin" = link ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Link existing binary" link "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Reuse a system QEMU; no patches, virgl profile or vmvga."
    if [ "$qemu_bin" = link ]; then
        if menu_path_ok "$qemu_link"; then
            menu_path_line "Found: $qemu_link" "$(menu_found_colour QEMU)"
        else
            menu_path_line "Not found: ${qemu_link:-qemu-system-x86_64}" "$c_error"
        fi
    fi

    sel=0; [ "$qemu_bin" = skip ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Do not compile" skip "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Install no QEMU; the launcher falls back to PATH."

    if [ "$qemu_bin" = compile ]; then
        menu_subsection "Patches ($(menu_count "$qemu_groups")/4)" "--qemu:patch"
        sel=0; menu_list_has "$qemu_groups" vmvga && sel=1
        menu_row '[B]' "VMware SVGA 3D support" vmvga "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "vmvga overlay for host-driven 3D in guests."
        sel=0; menu_list_has "$qemu_groups" spice-virgl && sel=1
        menu_row '[C]' "SPICE alongside a GL console" spicevirgl "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Keep SPICE channels usable while a GL console is active."
        sel=0; menu_list_has "$qemu_groups" gtk-egl && sel=1
        menu_row '[D]' "Re-blit and hidden-window guard" gtkegl "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Fix stale frames after window swaps and focus changes."
        sel=0; menu_list_has "$qemu_groups" resolution && sel=1
        menu_row '[E]' "Host-driven guest resolution" flexresize "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Resize the guest display from the host over vmport."
    fi
}

menu_render_ovmf() {
    local sel
    menu_section "BUILD ITEMS | OVMF"
    menu_subsection "Binaries" "--ovmf:bin"

    sel=0; [ "$ovmf_bin" = pull ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Pull pre-patched binaries" pull "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Use the silent images bundled with this repository."

    sel=0; [ "$ovmf_bin" = compile ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Compile from upstream" compile "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Build edk2 from the QEMU tarball; works without a QEMU build."

    sel=0; [ "$ovmf_bin" = link ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Link existing CODE + VARS" link "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Symlink a CODE/VARS pair already installed on the host."
    if [ "$ovmf_bin" = link ]; then
        if menu_path_ok "$ovmf_code"; then
            menu_path_line "Found: CODE: $ovmf_code" "$(menu_found_colour CODE)"
        else
            menu_path_line "Not found: CODE" "$c_error"
        fi
        if menu_path_ok "$ovmf_vars"; then
            menu_path_line "Found: VARS: $ovmf_vars" "$(menu_found_colour VARS)"
        else
            menu_path_line "Not found: VARS" "$c_error"
        fi
    fi

    sel=0; [ "$ovmf_bin" = skip ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Do not install firmware" skip "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Leave firmware handling to the host or domain XML."

    if [ "$ovmf_bin" = compile ]; then
        menu_subsection "Patches ($(menu_count "$ovmf_groups")/2)" "--ovmf:patch"
        sel=0; menu_list_has "$ovmf_groups" logo && sel=1
        menu_row '[B]' "Blank TianoCore splash" nosplash "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Replace the logo with a blank 193x58 image."
        sel=0; menu_list_has "$ovmf_groups" bds && sel=1
        menu_row '[C]' "Failure-only BdsDxe messages" nomessage "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Print boot messages only when something fails."
    fi
}

menu_render_vm() {
    local sel
    menu_section "BUILD ITEMS | VIRT-MGR"
    menu_subsection "Binaries" "--virtmgr:bin"

    sel=0; [ "$vm_bin" = compile ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Compile from upstream" compile "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Build the fork with the selected UI patches."

    sel=0; [ "$vm_bin" = link ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Link existing binary" link "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Reuse an installed virt-manager; no patches are applied."
    if [ "$vm_bin" = link ]; then
        if menu_path_ok "$vm_link"; then
            menu_path_line "Found: $vm_link" "$(menu_found_colour virt-manager)"
        else
            menu_path_line "Not found: ${vm_link:-virt-manager}" "$c_error"
        fi
    fi

    sel=0; [ "$vm_bin" = skip ] && sel=1
    menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
        "Do not compile" skip "$(menu_radio_mark "$sel")" "$sel"
    menu_note "$sel" "Install no virt-manager; use the host application instead."

    if [ "$vm_bin" = compile ]; then
        menu_subsection "Patches ($(menu_count "$vm_groups")/4)" "--virtmgr:patch"
        sel=0; menu_list_has "$vm_groups" reparent && sel=1
        menu_row '[B]' "X11/XWayland reparenting" reparent "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Embed the QEMU GTK window inside the virt-manager console."
        sel=0; menu_list_has "$vm_groups" pci-menu && sel=1
        menu_row '[C]' "PCIe hotplug submenu" pcimenu "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Curated PCI redirect submenu and device picker."
        sel=0; menu_list_has "$vm_groups" usb-menu && sel=1
        menu_row '[D]' "USB hotplug submenu" usbmenu "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "USB redirect submenu; pulls in the device cache."
        sel=0; menu_list_has "$vm_groups" usb-cache && sel=1
        menu_row '[E]' "USB device cache" usbcache "$(menu_check_mark "$sel")" "$sel"
        menu_note "$sel" "Work around the spice-gtk GI ownership bug."
    fi
}

menu_render_host() {
    local sel pend
    menu_section "HOST / OUTPUT"
    pend=0
    [ "$menu_mode" = sudo ] && [ "$menu_sudo_pending" = host ] && pend=1
    sel="$host_deps"
    menu_row '[A]' "Install build + runtime dependencies (host-global)" --deps "$(menu_check_mark "$sel")" "$sel" "$pend"
    menu_note "$sel" "Compiler/meson/ninja + GTK3, libvirt (daemon+client), spice, Vulkan; needs sudo."
    pend=0
    [ "$menu_mode" = sudo ] && [ "$menu_sudo_pending" = vfio ] && pend=1
    sel="$session_vfio"
    menu_row '[B]' "Session VFIO helper (host-global)" --sessionvfio "$(menu_check_mark "$sel")" "$sel" "$pend"
    menu_note "$sel" "Install /usr/local/sbin/vmm-vfio-ctl, a udev rule and sudoers entry."
    sel="$emit_domains"
    menu_row '[C]' "Write domain XML examples" --writexml "$(menu_check_mark "$sel")" "$sel"
    menu_note "$sel" "Render cachyos.xml and windows.xml into prefix/share/examples."
}

menu_sudo_ok() {
    [ "$(id -u)" = 0 ] && return 0
    sudo -n true 2>/dev/null
}

menu_render_after() {
    local sel pend
    menu_section "AFTER BUILD"
    menu_subsection "Cleanup" "--after:clean"
    pend=0
    [ "$menu_mode" = sudo ] && [ "$menu_sudo_pending" = deps ] && pend=1
    sel="$menu_clean_deps"
    menu_row '[A]' "Remove build dependencies" deps "$(menu_check_mark "$sel")" "$sel" "$pend"
    menu_note "$sel" "Runtime dependencies are always kept; only build-only packages are removed."
    sel="$menu_clean_sources"
    menu_row '[B]' "Remove sources and downloads" sources "$(menu_check_mark "$sel")" "$sel"
    menu_note "$sel" "Delete src/ and build/ after a successful build; safe to rebuild later."

    menu_subsection "Miscellany" "--after:misc"
    sel="$verify"
    menu_row '[C]' "Verify installation" verify "$(menu_check_mark "$sel")" "$sel"
    menu_note "$sel" "Check the launcher, QEMU and firmware paths after install."
    sel="$launchitem"
    menu_row '[D]' "Create .desktop launcher item" launchitem "$(menu_check_mark "$sel")" "$sel"
    menu_note "$sel" "Write vmm.desktop so the app appears in the desktop menu."
}

menu_summary() {
    local label="$1" colour="$2" value="$3"
    local indent='       ' avail line part first=1
    local -a parts
    avail=$((MENU_COLS - 22))
    [ "$avail" -lt 12 ] && avail=12
    if [ "${#value}" -le "$avail" ]; then
        printf '%s%-14s %s%s%s\n' "$indent" "$label" "$colour" "$value" "$c_reset"
        return
    fi
    IFS=',' read -r -a parts <<< "$value"
    if [ "${#parts[@]}" -le 1 ]; then
        while [ "${#value}" -gt "$avail" ]; do
            printf '%s%-14s %s%s%s\n' "$indent" "$label" "$colour" "${value:0:avail}" "$c_reset"
            label=""
            value="${value:avail}"
        done
        printf '%s%-14s %s%s%s\n' "$indent" "$label" "$colour" "$value" "$c_reset"
        return
    fi
    line="${parts[0]}"
    for part in "${parts[@]:1}"; do
        if [ $(( ${#line} + 1 + ${#part} )) -gt "$avail" ]; then
            if [ "$first" = 1 ]; then
                printf '%s%-14s %s%s%s\n' "$indent" "$label" "$colour" "$line" "$c_reset"
                first=0
            else
                printf '%s               %s%s%s\n' "$indent" "$colour" "$line" "$c_reset"
            fi
            line="$part"
        else
            line="$line,$part"
        fi
    done
    if [ "$first" = 1 ]; then
        printf '%s%-14s %s%s%s\n' "$indent" "$label" "$colour" "$line" "$c_reset"
    else
        printf '%s               %s%s%s\n' "$indent" "$colour" "$line" "$c_reset"
    fi
}

menu_render_command() {
    local args=() a clean="" misc="" flag value i=0 n tail
    case "$qemu_bin" in
        compile) args+=("--qemu:bin=compile" \
            "--qemu:patch=$(menu_qemu_display "$qemu_groups")") ;;
        link) args+=("--qemu:bin=link:$qemu_link") ;;
        skip) args+=("--qemu:bin=skip") ;;
    esac
    case "$ovmf_bin" in
        pull) args+=("--ovmf:bin=pull") ;;
        link) args+=("--ovmf:bin=link" "--ovmf:code=$ovmf_code" \
            "--ovmf:vars=$ovmf_vars") ;;
        compile) args+=("--ovmf:bin=compile" \
            "--ovmf:patch=$(menu_ovmf_display "$ovmf_groups")") ;;
        skip) args+=("--ovmf:bin=skip") ;;
    esac
    case "$vm_bin" in
        compile) args+=("--virtmgr:bin=compile" \
            "--virtmgr:patch=$(menu_vm_display "$vm_groups")") ;;
        link) args+=("--virtmgr:bin=link:$vm_link") ;;
        skip) args+=("--virtmgr:bin=skip") ;;
    esac
    [ "$host_deps" = 1 ] && args+=("--deps:install" "--deps:runtime")
    if [ "$menu_clean_sources" = 1 ] && [ "$menu_clean_deps" = 1 ]; then
        clean=all
    elif [ "$menu_clean_sources" = 1 ]; then
        clean=sources
    elif [ "$menu_clean_deps" = 1 ]; then
        clean=deps
    fi
    args+=("--after:clean=${clean:-none}")
    [ "$verify" = 1 ] && misc=verify
    [ "$launchitem" = 1 ] && misc="${misc:+$misc,}launchitem"
    [ -n "$misc" ] && args+=("--after:misc=$misc")
    [ "$session_vfio" = 1 ] && args+=("--sessionvfio")
    [ "$emit_domains" = 1 ] && args+=("--writexml")

    printf '       %s%s./install.sh%s %s\\%s\n' \
        "$c_bold" "$c_primary" "$c_reset" "$c_border" "$c_reset"
    n=${#args[@]}
    for a in "${args[@]}"; do
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then tail=' \'; else tail=''; fi
        case "$a" in
            *[!A-Za-z0-9_./:=+@%,-]*)
                printf "         '%s'%s\n" "${a//\'/\'\\\'\'}" "$tail" ;;
            --*=*)
                flag=${a%%=*}; value=${a#*=}
                printf '         %s%s%s=%s%s%s%s\n' \
                    "$c_info" "$flag" "$c_reset" \
                    "$c_success" "$value" "$c_reset" "$tail" ;;
            *)
                printf '         %s%s%s%s\n' "$c_info" "$a" "$c_reset" "$tail" ;;
        esac
    done
}

menu_render_review() {
    local q o v clean="" misc="" c_deps host="" nbuild nrun depstr
    menu_section "REVIEW & RUN"
    case "$qemu_bin" in
        compile) q="compile ($(menu_qemu_display "$qemu_groups"))" ;;
        link) q="link $qemu_link" ;;
        skip) q="skip" ;;
    esac
    case "$ovmf_bin" in
        compile) o="compile ($(menu_ovmf_display "$ovmf_groups"))" ;;
        link) o="link $ovmf_code + $ovmf_vars" ;;
        pull) o="bundled images" ;;
        skip) o="skip" ;;
    esac
    case "$vm_bin" in
        compile) v="compile ($(menu_vm_display "$vm_groups"))" ;;
        link) v="link $vm_link" ;;
        skip) v="skip" ;;
    esac
    [ "$menu_clean_sources" = 1 ] && clean=sources
    [ "$menu_clean_deps" = 1 ] && clean="${clean:+$clean,}deps"
    [ "$verify" = 1 ] && misc=verify
    [ "$launchitem" = 1 ] && misc="${misc:+$misc,}launchitem"
    [ "$host_deps" = 1 ] && host="${host:+$host,}deps"
    [ "$session_vfio" = 1 ] && host="${host:+$host,}sessionvfio"
    [ "$emit_domains" = 1 ] && host="${host:+$host,}writexml"
    nbuild=$(menu_deps_missing)
    nrun=$(runtime_deps_missing)
    if [ "$nbuild" -gt 0 ] || [ "$nrun" -gt 0 ]; then c_deps="$c_error"; else c_deps="$c_success"; fi
    if [ "$host_deps" = 1 ]; then
        depstr="install (build+runtime)"
    elif [ "$nbuild" -gt 0 ] || [ "$nrun" -gt 0 ]; then
        depstr="missing"
    else
        depstr="ok"
    fi

    menu_subsection "Selected"
    menu_summary QEMU "$c_primary" "$q"
    menu_summary OVMF "$c_accent" "$o"
    menu_summary virt-manager "$c_secondary" "$v"
    menu_summary deps "$c_deps" "$depstr"
    menu_summary cleanup "$c_warning" "${clean:-none}"
    menu_summary misc "$c_warning" "${misc:-none}"
    [ -n "$host" ] && menu_summary host "$c_warning" "$host"
    menu_summary prefix "$c_text" "$prefix"

    menu_subsection "Command"
    menu_render_command
}

# Page-level warnings live in the standard warning area at the bottom, not
# in the page body, so they line up with the QEMU/OVMF notices.
menu_page_warning() {
    local n nbuild nrun
    MENU_PAGE_WARN=""
    case "$menu_page" in
        4)
            if [ "$host_deps" = 0 ]; then
                n=$(runtime_deps_missing)
                [ "$n" -gt 0 ] && MENU_PAGE_WARN="  [!]  WARNING: $n missing dependencies required to run virt-manager"
                n=$(menu_deps_missing)
                if [ "$n" -gt 0 ]; then
                    MENU_PAGE_WARN="${MENU_PAGE_WARN:+$MENU_PAGE_WARN
}  [X]  ERROR: $n missing build dependencies. Grant sudo or remove build items"
                fi
            fi ;;
        5)
            if [ "$host_deps" = 0 ]; then
                n=$(menu_deps_missing)
                [ "$n" -gt 0 ] && MENU_PAGE_WARN="  [!]  WARNING: $n build dependencies missing; install them with [A] on HOST"
            fi ;;
        6)
            if [ "$host_deps" = 0 ]; then
                nrun=$(runtime_deps_missing)
                nbuild=$(menu_deps_missing)
                if [ "$nrun" -gt 0 ]; then
                    MENU_PAGE_WARN="  [!]  WARNING: $nrun runtime dependencies missing; the app may not start"
                fi
                if [ "$nbuild" -gt 0 ]; then
                    MENU_PAGE_WARN="${MENU_PAGE_WARN:+$MENU_PAGE_WARN
}  [X]  ERROR: $nbuild missing build dependencies. Grant sudo or remove build items"
                fi
            fi ;;
    esac
}

menu_render() {
    menu_calc_width
    [ -t 1 ] && { clear 2>/dev/null || printf '\033[H\033[2J'; }
    menu_frame
    menu_tabs
    case "$menu_page" in
        1) menu_render_qemu ;;
        2) menu_render_ovmf ;;
        3) menu_render_vm ;;
        4) menu_render_host ;;
        5) menu_render_after ;;
        6) menu_render_review ;;
    esac
    menu_page_warning
    if [ -n "$MENU_PAGE_WARN" ] || [ -n "$menu_warn" ] || [ -n "$menu_error" ]; then
        local line nc prefix rest
        printf '\n'
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "${line#"${line%%[! ]*}"}" in
                '[!]'*) nc="$c_warning" ;;
                *) nc="$c_error" ;;
            esac
            prefix=${line%%:*}
            if [ "$prefix" != "$line" ]; then
                prefix="$prefix:"
                rest=${line#"$prefix"}
            else
                rest=""
            fi
            # The notice strings carry their own leading space.
            printf '%s%s%s%s%s\n' \
                "$c_bold$nc" "$prefix" "$c_reset$nc" "$rest" "$c_reset"
        done <<EOF
$MENU_PAGE_WARN
$menu_warn
$menu_error
EOF
    fi
    menu_status
    printf ' %s%s%s\n' "$c_border" "$(menu_rule "$((MENU_COLS - 1))")" "$c_reset"
    menu_keys
    printf ' %s%sSelect:%s ' "$c_bold" "$c_info" "$c_reset"
}

menu_term_cooked() {
    [ -n "$menu_stty" ] && stty "$menu_stty" 2>/dev/null
    menu_raw=0
}

menu_term_raw() {
    if [ -n "$menu_stty" ]; then
        stty -echo -icanon min 1 time 0 2>/dev/null && menu_raw=1
    fi
}

menu_term_done() {
    [ -n "$menu_stty" ] && stty "$menu_stty" 2>/dev/null
    menu_raw=0
}

# A plain key read must not exit inside the trap: bash's read reasserts the
# raw settings on the way out and leaves the terminal with echo off.  Set a
# flag instead and let the render loop restore.  Readline (`read -e`) and
# sudo handle the signal themselves, so those states exit immediately.
menu_on_int() {
    if [ "$menu_text_active" = 1 ]; then
        menu_term_done
        printf '\n'
        exit 130
    fi
    menu_signal=1
}

menu_term_init() {
    menu_stty=$(stty -g 2>/dev/null || true)
    menu_term_raw
}

# While a link option is selected, a missing path is a persistent blocking
# error: it stays visible (and hides the page keys) until the path is fixed
# or the user returns to the selector with A.
menu_link_state() {
    local missing=""
    case "$menu_page" in
        1) menu_path_ok "$qemu_link" || missing=QEMU ;;
        2)
            if ! menu_path_ok "$ovmf_code"; then
                missing=CODE
            elif ! menu_path_ok "$ovmf_vars"; then
                missing=VARS
            fi ;;
        3) menu_path_ok "$vm_link" || missing=virt-manager ;;
    esac
    if [ -n "$missing" ]; then
        menu_error="  [X]  ERROR: Cannot proceed, fix path to $missing binary or select another option"
        menu_blocked=1
        return 1
    fi
    menu_error=""
    menu_blocked=0
    return 0
}

# Jumping to a page restores its link editor when that mode is selected, so
# a blocking path error cannot be lost by navigating away and back.
menu_page_mode() {
    menu_revert_label=""
    menu_warn=""
    menu_error=""
    MENU_PAGE_WARN=""
    case "$menu_page" in
        1)
            if [ "$qemu_bin" = link ]; then
                [ -n "$qemu_link" ] ||
                    qemu_link=$(command -v qemu-system-x86_64 2>/dev/null || true)
                menu_mode=link
                menu_link_state || true
                return
            fi ;;
        2)
            if [ "$ovmf_bin" = link ]; then
                [ -n "$ovmf_code" ] || ovmf_code=$(ovmf_find_code)
                [ -n "$ovmf_vars" ] || ovmf_vars=$(ovmf_find_vars)
                menu_mode=link
                menu_link_state || true
                return
            fi ;;
        3)
            if [ "$vm_bin" = link ]; then
                [ -n "$vm_link" ] ||
                    vm_link=$(command -v virt-manager 2>/dev/null || true)
                menu_mode=link
                menu_link_state || true
                return
            fi ;;
    esac
    menu_mode=normal
    menu_warn=""
    menu_error=""
    menu_blocked=0
}

menu_cycle_qemu() {
    case "$qemu_bin" in
        compile) qemu_bin=link ;;
        link) qemu_bin=skip ;;
        skip) qemu_bin=compile ;;
    esac
    menu_warn=""
    menu_error=""
    menu_revert_label=""
    if [ "$qemu_bin" = link ]; then
        [ -n "$qemu_link" ] || qemu_link=$(command -v qemu-system-x86_64 2>/dev/null || true)
        menu_mode=link
        menu_link_state || true
    else
        menu_mode=normal
    fi
}

menu_cycle_ovmf() {
    case "$ovmf_bin" in
        pull) ovmf_bin=compile ;;
        compile) ovmf_bin=link ;;
        link) ovmf_bin=skip ;;
        skip) ovmf_bin=pull ;;
    esac
    menu_warn=""
    menu_error=""
    menu_revert_label=""
    if [ "$ovmf_bin" = link ]; then
        [ -n "$ovmf_code" ] || ovmf_code=$(ovmf_find_code)
        [ -n "$ovmf_vars" ] || ovmf_vars=$(ovmf_find_vars)
        menu_mode=link
        menu_link_state || true
    else
        menu_mode=normal
    fi
}

menu_cycle_vm() {
    case "$vm_bin" in
        compile) vm_bin=link ;;
        link) vm_bin=skip ;;
        skip) vm_bin=compile ;;
    esac
    menu_warn=""
    menu_error=""
    menu_revert_label=""
    if [ "$vm_bin" = link ]; then
        [ -n "$vm_link" ] || vm_link=$(command -v virt-manager 2>/dev/null || true)
        menu_mode=link
        menu_link_state || true
    else
        menu_mode=normal
    fi
}

menu_prompt_path() {
    local label="$1" current="$2" out prompt
    printf '\n %s[Enter]%s Confirm %s path\n' "$c_bold$c_info" "$c_reset" "$label"
    # Let readline draw the prompt so backspace stops at the start of the
    # input instead of erasing the label.  \001/\002 mark the colour
    # escapes as zero-width.
    printf -v prompt ' \001%s%s\002Text:\001%s\002 ' \
        "$c_bold" "$c_info" "$c_reset"
    menu_text_active=1
    menu_term_cooked
    if ! IFS= read -r -e -i "$current" -p "$prompt" out; then
        menu_term_raw
        menu_text_active=0
        printf '\n'
        return 1
    fi
    menu_term_raw
    menu_text_active=0
    out=${out#"${out%%[![:space:]]*}"}
    out=${out%"${out##*[![:space:]]}"}
    case "$out" in
        "~") out=$HOME ;;
        "~/"*) out="$HOME/${out#\~/}" ;;
    esac
    MENU_TEXT=$out
    return 0
}

menu_edit_qemu_path() {
    local old="$qemu_link"
    menu_prompt_path "QEMU" "$old" || return
    menu_warn=""
    if menu_path_ok "$MENU_TEXT"; then
        qemu_link=$MENU_TEXT
        menu_revert_label=""
        menu_link_state || true
    elif menu_path_ok "$old"; then
        menu_revert_label=QEMU
        menu_warn="  [!]  WARNING: Invalid path, reverting to found QEMU binary"
        menu_error=""
        menu_blocked=0
    else
        menu_revert_label=""
        menu_link_state || true
    fi
}

menu_edit_vm_path() {
    local old="$vm_link"
    menu_prompt_path "virt-manager" "$old" || return
    menu_warn=""
    if menu_path_ok "$MENU_TEXT"; then
        vm_link=$MENU_TEXT
        menu_revert_label=""
        menu_link_state || true
    elif menu_path_ok "$old"; then
        menu_revert_label=virt-manager
        menu_warn="  [!]  WARNING: Invalid path, reverting to found virt-manager binary"
        menu_error=""
        menu_blocked=0
    else
        menu_revert_label=""
        menu_link_state || true
    fi
}

menu_edit_ovmf_path() {
    local old
    # A successful pass shows both entry blocks in series: CODE stays on
    # screen while VARS is open.  If either field is invalid, stop there and
    # return to the selector with the warning/error instead of continuing.
    menu_warn=""
    old=$ovmf_code
    menu_prompt_path "CODE" "$old" || { menu_link_state || true; return; }
    if menu_path_ok "$MENU_TEXT"; then
        ovmf_code=$MENU_TEXT
        menu_revert_label=""
    else
        if menu_path_ok "$old"; then
            menu_revert_label=CODE
            menu_warn="  [!]  WARNING: Invalid path, reverting to found CODE binary"
        else
            menu_revert_label=""
        fi
        menu_link_state || true
        return
    fi

    old=$ovmf_vars
    menu_prompt_path "VARS" "$old" || { menu_link_state || true; return; }
    if menu_path_ok "$MENU_TEXT"; then
        ovmf_vars=$MENU_TEXT
        menu_revert_label=""
    else
        if menu_path_ok "$old"; then
            menu_revert_label=VARS
            menu_warn="  [!]  WARNING: Invalid path, reverting to found VARS binary"
        else
            menu_revert_label=""
        fi
    fi
    menu_link_state || true
}

menu_link_key() {
    case "$1" in
        a) case "$menu_page" in
               1) menu_cycle_qemu ;;
               2) menu_cycle_ovmf ;;
               3) menu_cycle_vm ;;
           esac ;;
        /) case "$menu_page" in
               1) menu_edit_qemu_path ;;
               2) menu_edit_ovmf_path ;;
               3) menu_edit_vm_path ;;
           esac ;;
        [1-6])
            if [ "$menu_blocked" = 0 ]; then
                menu_page=$1
                menu_page_mode
            fi ;;
    esac
}

menu_sudo_key() {
    case "$1" in
        /)
            printf '\n'
            menu_text_active=1
            menu_term_cooked
            if sudo -v; then
                case "$menu_sudo_pending" in
                    deps) menu_clean_deps=1 ;;
                    vfio) session_vfio=1 ;;
                    host) host_deps=1 ;;
                esac
                menu_sudo_pending=""
                menu_mode=normal
                menu_warn=""
                menu_error=""
            else
                menu_error="  [X]  SUDO ACCESS DENIED: Cannot proceed; fix access or select another option"
                menu_mode=sudo
            fi
            menu_term_raw
            menu_text_active=0 ;;
    esac
}

menu_handle() {
    local k="$1" lk pending
    lk=${k,,}
    case "$menu_mode" in
        link) menu_link_key "$lk"; return ;;
        sudo)
            if [ "$lk" = / ]; then
                menu_sudo_key /
                return
            fi
            # Page keys are hidden while an option waits for the password.
            case "$lk" in
                [1-6]) return ;;
            esac
            # Pressing the pending option again simply deselects it.  Any
            # other option key abandons the prompt and selects that option.
            pending="$menu_sudo_pending"
            menu_sudo_pending=""
            menu_mode=normal
            case "$pending:$menu_page:$lk" in
                host:4:a|vfio:4:b|deps:5:a)
                    menu_warn=""
                    menu_error=""
                    return ;;
            esac
            ;;
    esac
    if [ "$k" = $'\n' ] || [ "$k" = $'\r' ]; then
        [ "$menu_page" = 6 ] && MENU_DONE=1
        return
    fi
    case "$lk" in
        [1-6]) menu_page=$lk; menu_page_mode; return ;;
    esac
    menu_warn=""
    menu_error=""
    case "$menu_page" in
        1)
            case "$lk" in
                a) menu_cycle_qemu ;;
                b) [ "$qemu_bin" = compile ] && menu_toggle_qemu_group vmvga ;;
                c) [ "$qemu_bin" = compile ] && menu_toggle_qemu_group spice-virgl ;;
                d) [ "$qemu_bin" = compile ] && menu_toggle_qemu_group gtk-egl ;;
                e) [ "$qemu_bin" = compile ] && menu_toggle_qemu_group resolution ;;
            esac ;;
        2)
            case "$lk" in
                a) menu_cycle_ovmf ;;
                b) [ "$ovmf_bin" = compile ] && menu_toggle_ovmf_group logo ;;
                c) [ "$ovmf_bin" = compile ] && menu_toggle_ovmf_group bds ;;
            esac ;;
        3)
            case "$lk" in
                a) menu_cycle_vm ;;
                b) [ "$vm_bin" = compile ] && menu_toggle_vm_group reparent ;;
                c) [ "$vm_bin" = compile ] && menu_toggle_vm_group pci-menu ;;
                d) [ "$vm_bin" = compile ] && menu_toggle_vm_group usb-menu ;;
                e) [ "$vm_bin" = compile ] && menu_toggle_vm_group usb-cache ;;
            esac ;;
        4)
            case "$lk" in
                a)
                    if [ "$host_deps" = 0 ] && ! menu_sudo_ok; then
                        menu_sudo_pending=host
                        menu_mode=sudo
                    else
                        host_deps=$((1 - host_deps))
                    fi ;;
                b)
                    if [ "$session_vfio" = 0 ] && ! menu_sudo_ok; then
                        menu_sudo_pending=vfio
                        menu_mode=sudo
                    else
                        session_vfio=$((1 - session_vfio))
                    fi ;;
                c) emit_domains=$((1 - emit_domains)) ;;
            esac ;;
        5)
            case "$lk" in
                a)
                    if [ "$menu_clean_deps" = 0 ] && ! menu_sudo_ok; then
                        menu_sudo_pending=deps
                        menu_mode=sudo
                    else
                        menu_clean_deps=$((1 - menu_clean_deps))
                    fi ;;
                b) menu_clean_sources=$((1 - menu_clean_sources)) ;;
                c) verify=$((1 - verify)) ;;
                d) launchitem=$((1 - launchitem)) ;;
            esac ;;
    esac
}

menu_prepare() {
    [ -n "$qemu_bin" ] || qemu_bin=compile
    [ -n "$vm_bin" ] || vm_bin=compile
    if [ -z "$ovmf_bin" ]; then
        if [ -f "$DIR/share/firmware/OVMF/OVMF_CODE_4M.fd" ]; then
            ovmf_bin=pull
        else
            ovmf_bin=compile
        fi
    fi
    [ "$qemu_bin" = compile ] && [ "$qemu_groups_given" = 0 ] &&
        qemu_groups=$(default_groups qemu)
    [ "$vm_bin" = compile ] && [ "$vm_groups_given" = 0 ] &&
        vm_groups=$(default_groups virt-manager)
    [ "$ovmf_bin" = compile ] && [ "$ovmf_groups_given" = 0 ] &&
        ovmf_groups=$(default_groups ovmf)
    qemu_groups=$(menu_order "$qemu_groups" vmvga spice-virgl gtk-egl resolution)
    vm_groups=$(menu_order "$vm_groups" reparent pci-menu usb-menu usb-cache)
    ovmf_groups=$(menu_order "$ovmf_groups" logo bds)
    [ -n "$qemu_link" ] ||
        qemu_link=$(command -v qemu-system-x86_64 2>/dev/null || true)
    [ -n "$vm_link" ] ||
        vm_link=$(command -v virt-manager 2>/dev/null || true)
    [ -n "$ovmf_code" ] || ovmf_code=$(ovmf_find_code)
    [ -n "$ovmf_vars" ] || ovmf_vars=$(ovmf_find_vars)
    if [ "$clean_given" = 0 ]; then
        clean_mode=sources
    fi
    case "$clean_mode" in
        sources) menu_clean_sources=1; menu_clean_deps=0 ;;
        deps) menu_clean_sources=0; menu_clean_deps=1 ;;
        all) menu_clean_sources=1; menu_clean_deps=1 ;;
        *) menu_clean_sources=0; menu_clean_deps=0 ;;
    esac
    if [ "$misc_given" = 0 ]; then
        verify=1
        launchitem=1
    fi
    menu_mode=normal
    menu_warn=""
    menu_error=""
    menu_sudo_pending=""
    menu_blocked=0
    menu_page_mode
}

menu_commit() {
    qemu_bin_given=1; vm_bin_given=1; ovmf_bin_given=1
    qemu_groups_given=1; vm_groups_given=1; ovmf_groups_given=1
    clean_given=1; misc_given=1
    if [ "$menu_clean_sources" = 1 ] && [ "$menu_clean_deps" = 1 ]; then
        clean_mode=all
    elif [ "$menu_clean_sources" = 1 ]; then
        clean_mode=sources
    elif [ "$menu_clean_deps" = 1 ]; then
        clean_mode=deps
    else
        clean_mode=""
        no_clean=1
    fi
    if [ "$host_deps" = 1 ]; then
        install_deps=1
        runtime_deps=1
    fi
}

menu_read_key() {
    local k line rc
    if [ "$menu_raw" = 1 ]; then
        # A timeout lets a trap-installed SIGINT flag break out promptly;
        # otherwise the interrupted read can be restarted and swallow the
        # next character the user types after quitting.
        while :; do
            IFS= read -rsN1 -t 0.2 k
            rc=$?
            [ "$rc" = 0 ] && break
            [ "$menu_signal" = 1 ] && return 1
            [ "$rc" -gt 128 ] && continue
            return 1
        done
        # Swallow an escape sequence (arrows, function keys) instead of
        # treating its tail as commands.
        if [ "$k" = $'\033' ]; then
            IFS= read -rsn1 -t 0.01 _ 2>/dev/null || true
            IFS= read -rsn1 -t 0.01 _ 2>/dev/null || true
            MENU_KEY=""
            printf '\n'
            return 0
        fi
        MENU_KEY=$k
    else
        IFS= read -r line || return 1
        if [ -z "$line" ]; then
            MENU_KEY=$'\n'
        else
            MENU_KEY=${line:0:1}
        fi
    fi
    printf '\n'
    return 0
}

menu_run() {
    menu_prepare
    MENU_DONE=0
    menu_signal=0
    menu_term_init
    trap 'menu_on_int' INT
    trap 'menu_signal=1' TERM
    trap 'menu_term_done' EXIT
    while [ "$MENU_DONE" = 0 ]; do
        menu_render
        if ! menu_read_key; then
            break
        fi
        [ "$menu_signal" = 1 ] && break
        [ -n "$MENU_KEY" ] && menu_handle "$MENU_KEY"
        [ "$menu_signal" = 1 ] && break
    done
    menu_term_done
    trap - INT TERM EXIT
    if [ "$menu_signal" = 1 ]; then
        printf '\n'
        exit 130
    fi
    menu_commit
    printf '\n'
}

deps_install() {
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
        *)
            die "unknown distro for --deps:install; install meson, gtk3, spice, virgl and python-gi manually"
            ;;
    esac
    after=$(pkg_snapshot)
    record_new_deps "$before" "$after"
}

# Runtime-only check: the deployed prefix loads these at run time, so test
# sonames (ldconfig) and the GI typelibs rather than -dev pkg-config files.

# ldconfig lives in sbin, which is not on a normal user's PATH on Debian or
# Arch. Resolve it explicitly; otherwise every soname looks absent.
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

runtime_deps_check() {
    pkg_missing=()
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

runtime_deps_missing() {
    runtime_deps_check
    printf '%s' "${#pkg_missing[@]}"
}

runtime_deps_install() {
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
        *)
            die "unknown distro for --deps:runtime; install GTK3, python3-gi, libvirt and Vulkan manually"
            ;;
    esac
    after=$(pkg_snapshot)
    record_new_deps "$before" "$after" "$RUNTIME_STATE" "--deps:runtime"
}

menu_needed=0
if [ -t 0 ] && [ "$dry_run" = 0 ] && [ "$update" = 0 ] && [ "$list" = 0 ] &&
   [ -z "$clean_mode" ] &&
   [ "$qemu_bin_given$vm_bin_given$ovmf_bin_given" != 111 ]; then
    if [ "$component_given" = 1 ] || [ "$other_action" = 0 ]; then
        menu_needed=1
    fi
fi
if [ "$menu_needed" = 1 ]; then
    menu_run
fi

# Bundled firmware remains the default for a component run.
if [ -z "$ovmf_bin" ] && [ -n "$qemu_bin$vm_bin" ]; then
    if [ -f "$DIR/share/firmware/OVMF/OVMF_CODE_4M.fd" ]; then
        ovmf_bin=pull
    else
        ovmf_bin=compile
    fi
fi

finalize_modes
validate_paths

if [ -z "$qemu_bin$vm_bin$ovmf_bin" ] && \
   [ "$install_deps" = 0 ] && [ "$runtime_deps" = 0 ] && [ "$session_vfio" = 0 ] && \
   [ "$emit_domains" = 0 ] && [ "$update" = 0 ] && \
   [ "$verify" = 0 ] && [ "$launchitem" = 0 ] && \
   [ -z "$clean_mode" ]; then
    note "nothing selected (see --help)"
    exit 0
fi

if [ "$runtime_deps" = 1 ]; then
    note "installing runtime dependencies"
    runtime_deps_install
fi

if [ "$install_deps" = 1 ]; then
    note "installing build dependencies"
    deps_install
fi

if [ "$vm_bin" = compile ]; then
    pkg_missing=()
    vm_deps_check
    if [ ${#pkg_missing[@]} -gt 0 ]; then
        note "missing dependencies: ${pkg_missing[*]}"
        die "rerun with --deps:install or install the packages above"
    fi
fi

if [ "$qemu_bin" = compile ]; then
    pkg_missing=()
    deps_check
    if [ ${#pkg_missing[@]} -gt 0 ]; then
        note "missing dependencies: ${pkg_missing[*]}"
        die "rerun with --deps:install or install the packages above"
    fi
fi

if [ "$ovmf_mode" = build ]; then
    pkg_missing=()
    ovmf_deps_check
    if [ ${#pkg_missing[@]} -gt 0 ]; then
        note "missing OVMF dependencies: ${pkg_missing[*]}"
        die "install nasm/acpica-tools or rerun with --deps:install"
    fi
fi

mkdir -p "$BUILD" "$DL" "$SRC"

# --------------------------------------------------------------------- sources

fetch() {
    local url="$1" dest="$2"
    [ -f "$dest" ] && return 0
    note "fetch $url"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" || die "fetch failed: $url"
    mv "$dest.part" "$dest"
}

source_ok() {
    local dir="$1" ref="$2"
    [ -f "$dir/.vmm-ref" ] && [ "$(cat "$dir/.vmm-ref")" = "$ref" ]
}

mark_source() { printf '%s\n' "$2" > "$1/.vmm-ref"; }

fetch_vm() {
    local dir="$SRC/virt-manager-$vm_lock" ref="$vm_lock+$enable_vm"
    if source_ok "$dir" "$ref"; then return 0; fi
    rm -rf "$dir" "$BUILD/vm-build"
    local tb="$DL/virt-manager-$vm_lock.tar.gz"
    fetch "$(conf_get virt-manager file)" "$tb"
    mkdir -p "$dir"
    tar -xzf "$tb" -C "$dir" --strip-components=1
    mark_source "$dir" "$ref"
    note "virt-manager $vm_lock extracted"
}

fetch_qemu() {
    local dir="$SRC/qemu-$qemu_lock" ref="$qemu_lock+$enable_qemu" url
    if source_ok "$dir" "$ref"; then return 0; fi
    rm -rf "$dir" "$BUILD/qemu-build"
    local tb="$DL/$qemu_file"
    url="$(conf_get qemu url)/$qemu_file"
    fetch "$url" "$tb"
    mkdir -p "$dir"
    tar -xf "$tb" -C "$dir" --strip-components=1
    mark_source "$dir" "$ref"
    note "qemu $qemu_lock extracted"
}

git_checkout() {
    local name="$1" url="$2" ref="$3" dir="$4" groups="$5"
    local want="$ref+$groups"
    if source_ok "$dir" "$want" && [ -d "$dir/.git" ]; then return 0; fi
    rm -rf "$dir"
    note "clone $name"
    git clone --quiet "$url" "$dir" || die "clone failed: $url"
    git -C "$dir" checkout --quiet "$ref" || die "$name: no ref $ref (use --update)"
    mark_source "$dir" "$want"
}

fetch_vmvga() {
    git_checkout vmvga "$(conf_get vmvga url)" "$vmvga_lock" "$SRC/qemu-vmvga" "overlay"
}

fetch_virgl() {
    local dir="$SRC/virglrenderer"
    git_checkout virglrenderer "$(conf_get virglrenderer url)" "$virgl_lock" "$dir" "venus"
    if [ ! -d "$dir/subprojects/venus-protocol-1.1.3" ]; then
        note "venus-protocol subproject downloads during meson setup"
    fi
}

# ---------------------------------------------------------------- builds

build_qemu() {
    [ -d "$SRC/qemu-$qemu_lock" ] || die "missing qemu source"
    DXVK_TARBALL="$("$DIR/tools/build-dxvk.sh" "$SRC/dxvk" "$dxvk_lock" \
        "$BUILD" "$DL/dxvk-native-${dxvk_lock#v}.tar.gz" \
        "${DXVK_URL:-}")" || die "dxvk-native build failed"
    export VMM_CFLAGS VMM_CXXFLAGS
    local log="$BUILD/logs/qemu-build.log"
    mkdir -p "$(dirname "$log")"
    # shellcheck disable=SC2086
    QEMU_GROUPS="$qemu_groups" \
        "$DIR/tools/build-qemu.sh" "$prefix/qemu" "$SRC/qemu-$qemu_lock" "$SRC/qemu-vmvga" \
        "$SRC/virglrenderer" "$DXVK_TARBALL" 2>&1 | tee "$log" | filter_output
    note "qemu profile at $prefix/qemu"
}

build_ovmf() {
    local edk2="$SRC/qemu-$qemu_lock/roms/edk2"
    section "firmware"
    [ -d "$edk2/OvmfPkg" ] || die "edk2 snapshot missing from the QEMU tarball"
    export VMM_CFLAGS VMM_CXXFLAGS
    local log="$BUILD/logs/ovmf-build.log"
    mkdir -p "$(dirname "$log")"
    OVMF_GROUPS="$ovmf_groups" \
        "$DIR/tools/build-ovmf.sh" "$edk2" "$BUILD/ovmf" 2>&1 | tee "$log" | filter_output || die "OVMF build failed"
}

# ------------------------------------------------------------------- launchers

install_firmware() {
    case "$ovmf_mode" in
        build)
            [ -d "$BUILD/ovmf" ] || die "built OVMF images missing from $BUILD/ovmf"
            note "installing built OVMF"
            mkdir -p "$prefix/firmware/OVMF"
            cp -a "$BUILD/ovmf/." "$prefix/firmware/OVMF/"
            ln -sfn OVMF_CODE_4M.secboot.fd "$prefix/firmware/OVMF/OVMF_CODE_4M.ms.fd"
            ;;
        bundle)
            if [ -d "$DIR/share/firmware" ]; then
                mkdir -p "$prefix/firmware"
                cp -a "$DIR/share/firmware/." "$prefix/firmware/"
            else
                warn "bundled firmware missing from $DIR/share/firmware"
            fi
            ;;
        link)
            note "linking OVMF from $ovmf_code and $ovmf_vars"
            mkdir -p "$prefix/firmware/OVMF"
            ln -sfn "$ovmf_code" "$prefix/firmware/OVMF/OVMF_CODE_4M.fd"
            ln -sfn "$ovmf_vars" "$prefix/firmware/OVMF/OVMF_VARS_4M.fd"
            ;;
        skip|"") ;;
    esac
}

build_embed_shim() {
    local src="$DIR/share/vendor/qemu-embed-shim.c"
    local out="$prefix/libexec/qemu-embed-shim.so"
    local cc=${CC:-cc} flags=""
    [ -f "$src" ] || { warn "embed shim source missing: $src"; return; }
    if ! command -v "$cc" >/dev/null 2>&1; then
        warn "embed shim skipped: no C compiler ($cc)"
        return
    fi
    if command -v pkg-config >/dev/null 2>&1; then
        flags=$(pkg-config --cflags --libs x11 2>/dev/null || true)
    fi
    [ -n "$flags" ] || flags=-lX11
    # flags intentionally split: pkg-config yields a list.
    # shellcheck disable=SC2086
    if "$cc" -O2 -fPIC -shared -o "$out" "$src" $flags -pthread; then
        note "embed shim: $out"
    else
        rm -f "$out"
        warn "embed shim build failed; X11 embedding may be unavailable"
    fi
}

install_launchers() {
    mkdir -p "$prefix/bin" "$prefix/libexec" "$prefix/state" "$prefix/run"
    # Generate the launcher into the prefix.  It is not shipped as a source
    # file: a single installed launcher avoids the duplicate root/prefix copies.
    cat > "$prefix/launch.sh" <<'LAUNCH'
#!/bin/bash
# Launch the VMM virt-manager fork from this prefix.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DIR"
# When launch.sh is copied to the install root (filesystems without symlink
# support), the real prefix lives alongside it; cd into it so relative
# profile/config paths and the desktop Exec= rewrite resolve correctly.
if [ -d "$DIR/prefix" ]; then
    cd "$DIR/prefix" || exit 1
    PREFIX="$(pwd)"
fi
QEMU="$PREFIX/qemu"

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

export GSETTINGS_SCHEMA_DIR="$PREFIX/share/glib-2.0/schemas${GSETTINGS_SCHEMA_DIR:+:$GSETTINGS_SCHEMA_DIR}"
export PYTHONPATH="$PREFIX/share/virt-manager${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$QEMU/lib:$QEMU/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -x "$QEMU/libexec/virgl_render_server" ] &&
    export RENDER_SERVER_EXEC_PATH="$QEMU/libexec/virgl_render_server"

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

if [ ! -x "$PREFIX/qemu/bin/qemu-system-x86_64" ] &&
   [ ! -x "$PREFIX/state/qemu" ] &&
   ! command -v qemu-system-x86_64 >/dev/null; then
    echo "launch: no QEMU configured; run ./install.sh --qemu:bin=compile" >&2
fi

# Render and define the domains from profile.conf before virt-manager starts.
# The renderer absolutises relative disks each run, fills a missing UUID once
# and resolves name/uuid collisions; set VMM_NO_DEFINE=1 to skip.
if [ -z "${VMM_NO_DEFINE:-}" ] && [ -x "$PREFIX/bin/vmm-render" ] &&
   [ -f "$PREFIX/profile.conf" ] && command -v virsh >/dev/null 2>&1; then
    "$PREFIX/bin/vmm-render" --define ||
        echo "launch: domain define failed; continuing" >&2
fi

exec "$PREFIX/bin/virt-manager" "$@"
LAUNCH
    chmod 0755 "$prefix/launch.sh"
    ensure_front_links
    install -m 0755 "$DIR/tools/vmm-qemu-launcher.sh" "$prefix/bin/vmm-qemu"
    install -m 0755 "$DIR/tools/vmm-profile-render.sh" "$prefix/bin/vmm-render"
    build_embed_shim
    if [ "$vm_bin" = link ]; then
        note "linking virt-manager from $vm_link"
        cat > "$prefix/bin/virt-manager" <<EOF
#!/bin/bash
# VMM linked virt-manager; do not rewrite
exec "$vm_link" "\$@"
EOF
        chmod 0755 "$prefix/bin/virt-manager"
    fi
    install_firmware
    install_examples
    if [ ! -f "$prefix/profile.conf" ]; then
        if [ -f "$DIR/share/examples/profile.conf.in" ]; then
            install -m 0644 "$DIR/share/examples/profile.conf.in" "$prefix/profile.conf"
        else
            cat > "$prefix/profile.conf" <<'EOF'
# Sourced by launch.sh and bin/vmm-qemu.  Keep to KEY=value lines.
QEMU_GTK_REFRESH_RATE=60
# VK_DRIVER_FILES=/usr/share/vulkan/icd.d/your_driver.json
EOF
        fi
    fi
}

# Domain XML templates and the profile template travel with the prefix; the
# launcher renders from these copies, never from the source tree.
install_examples() {
    [ -d "$DIR/share/examples" ] || return 0
    mkdir -p "$prefix/share/examples" || {
        warn "cannot create $prefix/share/examples"
        return 0
    }
    cp -f "$DIR/share/examples/"*.xml.in "$prefix/share/examples/" 2>/dev/null || true
    [ -f "$DIR/share/examples/profile.conf.in" ] &&
        cp -f "$DIR/share/examples/profile.conf.in" "$prefix/share/examples/profile.conf.in"
    return 0
}

# Front scripts live at the install root and point into the tree. The copy
# branch covers filesystems without symlink support (NTFS, SMB2).
front_link() {
    local rel=$1 dst=$2
    rm -f "$dst" 2>/dev/null || true
    if ln -s "$rel" "$dst" 2>/dev/null; then
        return 0
    elif cp -f "$ROOT/$rel" "$dst" 2>/dev/null && chmod 0755 "$dst"; then
        return 0
    fi
    warn "cannot link or copy $dst"
    return 1
}

ensure_front_links() {
    [ "$ROOT" = "$DIR" ] && return 0
    [ -x "$prefix/launch.sh" ] || return 0
    front_link "$prefix/launch.sh" "$ROOT/launch.sh"
}

install_desktop_item() {
    [ -x "$prefix/launch.sh" ] || {
        warn "no launcher at $prefix/launch.sh; skipping desktop item"
        return 0
    }
    local dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$dir" || { warn "cannot create $dir"; return 0; }
    cat > "$dir/vmm.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Virtual Machine Manager (VMM)
Comment=Launch the VMM QEMU/virt-manager profile
Exec=$prefix/launch.sh
Icon=virt-manager
Terminal=false
Categories=System;Emulator;
EOF
    note "wrote $dir/vmm.desktop"
}

verify_install() {
    local rc=0
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
    case "$ovmf_mode" in
        skip|"") ;;
        *)
            for f in OVMF_CODE_4M.fd OVMF_VARS_4M.fd; do
                [ -e "$prefix/firmware/OVMF/$f" ] ||
                    { warn "firmware missing: $prefix/firmware/OVMF/$f"; rc=1; }
            done
            ;;
    esac
    if [ -e "$prefix/state/qemu" ] || [ -d "$prefix/qemu" ]; then
        note "qemu: $prefix/state/qemu"
    fi
    [ "$rc" = 0 ] && note "verify: ok" || warn "verify: issues above"
    return 0
}

# -------------------------------------------------------------------- cleanup

cleanup_sources() {
    local found=0
    if [ -d "$SRC" ]; then
        note "removing source cache: $SRC"
        rm -rf "$SRC" || warn "could not remove $SRC"
        found=1
    fi
    if [ -d "$BUILD" ]; then
        note "removing build outputs and downloads: $BUILD"
        rm -rf "$BUILD" || warn "could not remove $BUILD"
        found=1
    fi
    [ "$found" = 0 ] && note "no sources or build outputs to remove"
}

installed_new_deps() {
    local id pkg
    id=$(distro_id)
    [ -f "$DEPS_STATE" ] || return 0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        case "$id" in
            *arch*)
                pacman -Qq "$pkg" >/dev/null 2>&1 && printf '%s\n' "$pkg" ;;
            *debian*|*ubuntu*)
                dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
                    grep -q 'install ok installed' && printf '%s\n' "$pkg" ;;
            *fedora*|*rhel*|*centos*)
                rpm -q "$pkg" >/dev/null 2>&1 && printf '%s\n' "$pkg" ;;
        esac
    done < "$DEPS_STATE"
}

cleanup_deps() {
    [ -f "$DEPS_STATE" ] ||
        { note "no build packages recorded from --deps:install"; return 0; }
    local id rc=0
    local -a pkgs=()
    local -A keep=()
    local pkg
    # Runtime dependencies are never removed; they are needed to run the
    # prefix long after the build.  Build dependencies that doubled as
    # runtime deps are therefore excluded here too.
    if [ -f "$RUNTIME_STATE" ]; then
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && keep["$pkg"]=1
        done < "$RUNTIME_STATE"
    fi
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        [ -n "${keep[$pkg]:-}" ] && continue
        pkgs+=("$pkg")
    done < <(installed_new_deps)
    if [ ${#pkgs[@]} -eq 0 ]; then
        note "no build-only packages to remove (runtime dependencies kept)"
        rm -f "$DEPS_STATE"
        return 0
    fi
    note "removing ${#pkgs[@]} build package(s) added by --deps:install"
    note "runtime dependencies are kept"
    id=$(distro_id)
    case "$id" in
        *arch*)
            as_root pacman -Rns --noconfirm "${pkgs[@]}" || rc=$? ;;
        *debian*|*ubuntu*)
            as_root apt-get remove --purge -y "${pkgs[@]}" || rc=$? ;;
        *fedora*|*rhel*|*centos*)
            as_root dnf remove -y "${pkgs[@]}" || rc=$? ;;
        *)
            warn "unknown distro; remove manually: ${pkgs[*]}"
            return 1 ;;
    esac
    if [ "$rc" = 0 ]; then
        rm -f "$DEPS_STATE"
    else
        warn "package cleanup incomplete; $DEPS_STATE kept for a retry"
    fi
    return "$rc"
}

offer_cleanup() {
    local ans
    if [ "$no_clean" = 1 ]; then
        note "build sources kept at $BUILD"
        return 0
    fi
    if [ ! -t 0 ]; then
        note "build sources kept at $BUILD"
        [ -s "$DEPS_STATE" ] &&
            note "new packages recorded in $DEPS_STATE; remove with --after:clean=deps"
        return 0
    fi
    printf '\n'
    if [ -d "$BUILD" ]; then
        read -r -p "Remove build sources and downloads now? [y/N] " ans
        case "$ans" in [yY]*) cleanup_sources ;; esac
    fi
    if [ -s "$DEPS_STATE" ]; then
        printf 'Packages added by --deps:install:\n%s\n' "$(sed 's/^/  /' "$DEPS_STATE")"
        read -r -p "Remove them too? The installed prefix may need them at runtime. [y/N] " ans
        case "$ans" in [yY]*) cleanup_deps ;; esac
    fi
}

# -------------------------------------------------------------------- optional

install_vfio() {
    [ -f "$DIR/tools/vmm-vfio-ctl" ] ||
        die "--sessionvfio: tools/vmm-vfio-ctl is not present"
    note "installing vfio helper (host-global, opt-in)"
    install -d /usr/local/sbin
    install -m 0755 "$DIR/tools/vmm-vfio-ctl" /usr/local/sbin/vmm-vfio-ctl
    cat > /etc/sudoers.d/vmm-vfio <<'EOF'
# Installed by VMM-git --sessionvfio. Grants device bind/unbind only.
%libvirt ALL=(root) NOPASSWD: /usr/local/sbin/vmm-vfio-ctl
EOF
    chmod 0440 /etc/sudoers.d/vmm-vfio
    cat > /etc/udev/rules.d/60-vmm-vfio.rules <<'EOF'
SUBSYSTEM=="vfio", MODE="0666"
EOF
    udevadm control --reload-rules 2>/dev/null || true
    note "vfio helper installed; this grants libvirt-group users device control"
}

emit_domains() {
    local render="$prefix/bin/vmm-render"
    install_examples || return 0

    if [ ! -x "$render" ] && [ -f "$DIR/tools/vmm-profile-render.sh" ]; then
        mkdir -p "$prefix/bin"
        install -m 0755 "$DIR/tools/vmm-profile-render.sh" "$render" ||
            { warn "cannot install vmm-render"; return 0; }
    fi
    [ -x "$render" ] || {
        warn "vmm-render missing; cannot emit domain examples"
        return 0
    }
    if [ ! -f "$prefix/profile.conf" ] && [ -f "$prefix/share/examples/profile.conf.in" ]; then
        install -m 0644 "$prefix/share/examples/profile.conf.in" "$prefix/profile.conf" ||
            warn "cannot create $prefix/profile.conf"
    fi
    [ -f "$prefix/profile.conf" ] || {
        warn "no profile at $prefix/profile.conf; nothing emitted"
        return 0
    }

    note "rendering domain examples from $prefix/profile.conf"
    "$render" --profile "$prefix/profile.conf" --prefix "$prefix" \
        --write "$prefix/share/examples" ||
        warn "some domain examples failed to render"

    grep -l '@[A-Z_][A-Z0-9_]*@' "$prefix/share/examples"/*.xml 2>/dev/null |
        while read -r tmpl; do warn "unsubstituted placeholders in $tmpl"; done
    note "domain examples are under $prefix/share/examples; launch.sh defines them"
}

# ----------------------------------------------------------------------- main

update_locks() {
    python3 - "$CONF" <<'PY'
import json, re, subprocess, sys

path = sys.argv[1]
text = open(path).read().splitlines()
loc = {}
sec = None
for i, line in enumerate(text):
    m = re.match(r'^\[([^\]]+)\]$', line.strip())
    if m:
        sec = m.group(1)
        continue
    m = re.match(r'^\s*([A-Za-z0-9_-]+)\s*=', line)
    if m and sec:
        loc[(sec, m.group(1))] = i

def get(s, k):
    return text[loc[(s, k)]].split('=', 1)[1].strip()

def put(s, k, v):
    i = loc[(s, k)]
    key = text[i].split('=', 1)[0]
    text[i] = key + '= ' + v

def sh(*cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)

def curl(url):
    return sh('curl', '-fsSL', '--max-time', '30', url)

def vkey(v):
    return tuple(int(x) for x in re.findall(r'\d+', v)[:3])

def git_ref(url, ref):
    for line in sh('git', 'ls-remote', url, ref).splitlines():
        if line.endswith(ref + '^{}') or line.endswith(ref):
            return line.split()[0]
    raise SystemExit('cannot resolve %s %s' % (url, ref))

# virt-manager: newest vX.Y.Z tag
tags = json.loads(curl('https://api.github.com/repos/virt-manager/virt-manager/tags?per_page=100'))
tag = max((t['name'] for t in tags if re.match(r'^v\d+\.\d+\.\d+$', t['name'])), key=vkey)
if tag != get('virt-manager', 'lock'):
    put('virt-manager', 'lock', tag)
    put('virt-manager', 'file',
        'https://github.com/virt-manager/virt-manager/archive/refs/tags/%s.tar.gz' % tag)
put('virt-manager', 'lock_commit',
    git_ref(get('virt-manager', 'url'), 'refs/tags/%s^{}' % tag))

# qemu: newest stable release tarball
listing = curl('https://download.qemu.org/')
vers = sorted({m.group(1) for m in re.finditer(r'qemu-(\d+\.\d+\.\d+)\.tar\.xz', listing)}, key=vkey)
if vers:
    put('qemu', 'lock', vers[-1])
    put('qemu', 'lock_file', 'qemu-%s.tar.xz' % vers[-1])

# git heads
put('vmvga', 'lock', git_ref(get('vmvga', 'url'), 'refs/heads/' + get('vmvga', 'ref')))
put('virglrenderer', 'lock', git_ref(get('virglrenderer', 'url'), 'HEAD'))

# dxvk: latest release tag, annotated tag dereferenced
rel = json.loads(curl('https://api.github.com/repos/doitsujin/dxvk/releases/latest'))
dtag = rel['tag_name']
put('dxvk-native', 'lock', dtag)
put('dxvk-native', 'lock_commit', git_ref(get('dxvk-native', 'url'), 'refs/tags/%s^{}' % dtag))

open(path, 'w').write('\n'.join(text) + '\n')
print('updated ' + path)
PY
}

if [ "$update" = 1 ]; then
    note "resolving latest upstreams"
    update_locks || die "--update failed (network or upstream layout changed)"
    vm_lock=$(conf_get virt-manager lock)
    qemu_lock=$(conf_get qemu lock)
    qemu_file=$(conf_get qemu lock_file)
    vmvga_lock=$(conf_get vmvga lock)
    virgl_lock=$(conf_get virglrenderer lock)
    dxvk_lock=$(conf_get dxvk-native lock)
    note "now: virt-manager $vm_lock, qemu $qemu_lock, virgl ${virgl_lock%????????????????????????}, dxvk $dxvk_lock"
    if [ -z "$qemu_bin$vm_bin$ovmf_bin" ]; then
        exit 0
    fi
fi

if [ "$vm_bin" = compile ]; then
    fetch_vm
    vm_groups_args=()
    vm_ifs="$IFS"
    IFS=','
    for g in $enable_vm; do
        [ -n "$g" ] && vm_groups_args+=("$g")
    done
    IFS="$vm_ifs"
    "$DIR/tools/build-vm.sh" "$SRC/virt-manager-$vm_lock" "$BUILD/vm-build" \
        "$prefix" "$jobs" "${vm_groups_args[@]}" ||
        die "virt-manager build failed"
fi

# QEMU sources also carry roms/edk2, so OVMF compilation can run without a
# QEMU build (for example when QEMU is linked or skipped).
if [ "$qemu_bin" = compile ] || [ "$ovmf_mode" = build ]; then
    fetch_qemu
fi

if [ "$ovmf_mode" = build ]; then
    build_ovmf
fi

if [ "$qemu_bin" = link ]; then
    mkdir -p "$prefix/state"
    note "reusing $qemu_link; profile and virgl are not built"
    ln -sfn "$qemu_link" "$prefix/state/qemu"
fi

if [ "$qemu_bin" = compile ]; then
    rm -f "$prefix/state/qemu"
    if menu_list_has "$qemu_groups" vmvga; then
        fetch_vmvga
    fi
    fetch_virgl
    build_qemu || die "qemu build failed"
fi

if [ "$qemu_bin" = compile ] || [ "$qemu_bin" = link ] ||
   [ "$vm_bin" = compile ] || [ "$vm_bin" = link ]; then
    install_launchers || die "launcher install failed"
    "$DIR/tools/relocate-prefix.sh" "$prefix" || die "prefix relocation failed"
elif [ -n "$ovmf_mode" ]; then
    mkdir -p "$prefix"
    install_firmware
fi
[ "$session_vfio" = 1 ] && install_vfio
ensure_front_links
[ "$emit_domains" = 1 ] && emit_domains
[ "$verify" = 1 ] && verify_install
[ "$launchitem" = 1 ] && install_desktop_item

if [ -n "$clean_mode" ]; then
    case "$clean_mode" in
        sources) cleanup_sources ;;
        deps) cleanup_deps ;;
        all) cleanup_sources; cleanup_deps ;;
    esac
elif [ -n "$qemu_bin$vm_bin$ovmf_bin" ]; then
    offer_cleanup
fi

note "done"
