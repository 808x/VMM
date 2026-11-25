#!/bin/bash
# No -e: actions are checked explicitly with || die.
set -u
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$SELF_DIR"
# install.sh (no symlink support) is detected by the sibling src/tools.
if [ -L "$SELF" ] && command -v readlink >/dev/null 2>&1; then
    DIR="$(cd "$(dirname "$(readlink -f "$SELF")")" && pwd)"
elif [ -d "$SELF_DIR/src/tools" ] && [ ! -d "$SELF_DIR/tools" ]; then
    DIR="$SELF_DIR/src"
else
    DIR="$SELF_DIR"
fi
CONF="$DIR/tools/upstreams.conf"
[ -f "$DIR/tools/lib.sh" ] && . "$DIR/tools/lib.sh"
BUILD="${VMM_BUILD_DIR:-$DIR/build}"
STATE="${VMM_STATE_DIR:-$DIR/state}"
DEPS_STATE="$STATE/new-deps"
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
install_deps=0
session_vfio=0
libvirt_access=1
libvirt_access_given=0
emit_domains=0
verify=0
launchitem=0
update=0
dry_run=0
list=0
clean_sources=0
clean_deps=0
clean_given=0
misc_given=0
prefix="$ROOT/prefix"
# tree was copied (no symlinks) the prefix may instead be under src/.  All path
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


PAGES=(
    "1|QEMU|qemu"
    "2|OVMF|ovmf"
    "3|VIRT-MGR|virt-manager"
    "4|HOST|host"
    "5|AFTER|after"
    "6|REVIEW|review"
)

declare -A ENGINE_CLI=([qemu]=qemu [virt-manager]=virtmgr [ovmf]=ovmf)
declare -A ENGINE_VAR=([qemu]=qemu [virt-manager]=vm [ovmf]=ovmf)
declare -A ENGINE_LABEL=([qemu]=QEMU [ovmf]=OVMF [virt-manager]=VIRT-MGR)
declare -A ENGINE_LINK_VAR1=([qemu]=qemu_link [ovmf]=ovmf_code [virt-manager]=vm_link)
declare -A ENGINE_LINK_VAR2=([ovmf]=ovmf_vars)



ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

ENGINES=()
declare -A U_KIND=() U_NAME=() U_DESC=() U_DEPS=() U_PATH=() U_SUDO=() U_TICK=() U_ON=()
declare -A U_VAR=() U_PHASE=() U_ARGS=()
declare -A PAGE_UNITS=() PAGE_KIND=()
PAGE_ORDER=()
declare -A BUILD_MODES=()

engine_cache_init() {
    local page f modes
    record_load
    ENGINES=()
    for page in "${PAGE_ORDER[@]}"; do
        [ "${PAGE_KIND[$page]:-}" = engine ] || continue
        ENGINES+=("$page")
        modes=""
        for f in ${PAGE_UNITS[$page]:-}; do
            [ "$(u_kind "$page" "$f")" = bin ] && modes="${modes:+$modes }$f"
        done
        BUILD_MODES[$page]=$modes
    done
    [ "${#ENGINES[@]}" -gt 0 ] || die "no engines reported by tools/build.sh"
}

unit_field() {
    local page="$1" flag="$2" field="$3"
    case "$field" in
        name) printf '%s' "${U_NAME["$page|$flag"]:-}" ;;
        desc) printf '%s' "${U_DESC["$page|$flag"]:-}" ;;
        deps) printf '%s' "${U_DEPS["$page|$flag"]:-}" ;;
        tick) printf '%s' "${U_TICK["$page|$flag"]:-}" ;;
        path) printf '%s' "${U_PATH["$page|$flag"]:-}" ;;
    esac
}

patch_flags() {
    local page="$1" f
    for f in ${PAGE_UNITS[$page]:-}; do
        [ "$(u_kind "$page" "$f")" = patch ] && printf '%s\n' "$f"
    done
}

default_groups() {
    local page="$1" f out=""
    for f in $(patch_flags "$page"); do
        [ "$(unit_field "$page" "$f" tick)" = yes ] && out="${out:+$out,}$f"
    done
    printf '%s' "$out"
}

list_patches() {
    local engine f deps
    printf '%-14s %-12s %-10s %-9s %-6s %s\n' ENGINE FLAG DEPENDS TICK NAME DESCRIPTION
    for engine in "${ENGINES[@]}"; do
        for f in $(patch_flags "$engine"); do
            deps=$(unit_field "$engine" "$f" deps)
            printf '%-14s %-12s %-10s %-9s %-6s %s\n' "$engine" "$f" \
                "${deps:--}" "$(unit_field "$engine" "$f" tick)" \
                "$(unit_field "$engine" "$f" name)" "$(unit_field "$engine" "$f" desc)"
        done
    done
}

validate_selection() {
    local engine="$1" sel="$2" g d deps
    for g in $(printf '%s' "$sel" | tr ',' ' '); do
        [ -n "$g" ] || continue
        case " $(patch_flags "$engine" | tr '\n' ' ') " in
            *" $g "*) ;;
            *) die "unknown $engine flag '$g' (see --list-patches)" ;;
        esac
        deps=$(unit_field "$engine" "$g" deps)
        for d in $(printf '%s' "$deps" | tr ',' ' '); do
            [ -n "$d" ] || continue
            case " $(printf '%s' "$sel" | tr ',' ' ') " in
                *" $d "*) ;;
                *) die "$engine/$g requires $engine/$d" ;;
            esac
        done
    done
}

map_group() {
    local engine="$1" flag="$2"
    REPLY=""
    case " $(patch_flags "$engine" | tr '\n' ' ') " in
        *" $flag "*) REPLY=$flag ;;
        *) die "unknown $engine patch flag '$flag' (see --list-patches)" ;;
    esac
}

assign_groups() {
    local eng="$1" list="$2" var="$3" out="" g
    for g in $(printf '%s' "$list" | tr ',' ' '); do
        [ -n "$g" ] || continue
        map_group "$eng" "$g"
        case ",$out," in *",$REPLY,"*) continue ;; esac
        out="${out:+$out,}$REPLY"
    done
    printf -v "$var" '%s' "$out"
}

record_load() {
    local kind="" page="" flag="" name="" desc="" deps="" path="" tick="" post="" sudo=""
    PAGE_ORDER=(); PAGE_UNITS=(); PAGE_KIND=()
    U_KIND=(); U_NAME=(); U_DESC=(); U_DEPS=(); U_PATH=(); U_SUDO=(); U_TICK=(); U_ON=()
    U_VAR=(); U_PHASE=(); U_ARGS=()
    while IFS='|' read -r kind page flag name desc deps path tick post sudo; do
        [ -n "$flag" ] || continue
        U_KIND["$page|$flag"]=$kind
        U_NAME["$page|$flag"]=$name
        U_DESC["$page|$flag"]=$desc
        U_DEPS["$page|$flag"]=$deps
        U_PATH["$page|$flag"]=$path
        U_SUDO["$page|$flag"]=$sudo
        U_TICK["$page|$flag"]=$tick
        U_ON["$page|$flag"]=0
        if [ "$kind" = tool ]; then
            local src="$DIR/$path"
            U_VAR["$page|$flag"]=$(header_field "$src" VMM_VAR)
            U_PHASE["$page|$flag"]=$(header_field "$src" VMM_PHASE)
            U_ARGS["$page|$flag"]=$(header_field "$src" VMM_ARGS)
            [ -n "${U_VAR["$page|$flag"]:-}" ] ||
                U_VAR["$page|$flag"]=$(printf '%s' "$flag" | tr '-' '_')
            [ -n "${U_PHASE["$page|$flag"]:-}" ] || U_PHASE["$page|$flag"]=post
        fi
        case " ${PAGE_UNITS[$page]:-} " in
            *" $flag "*) ;;
            *) PAGE_UNITS[$page]="${PAGE_UNITS[$page]:+${PAGE_UNITS[$page]} }$flag" ;;
        esac
        case "$kind" in
            bin) PAGE_KIND[$page]=engine ;;
            tool) PAGE_KIND[$page]=tool ;;
        esac
        case " ${PAGE_ORDER[*]:-} " in
            *" $page "*) ;;
            *) PAGE_ORDER+=("$page") ;;
        esac
    done < <("$DIR/tools/build.sh" --list) ||
        die "cannot read the unit record from tools/build.sh"
}


u_kind() { printf '%s' "${U_KIND["$1|$2"]:-}"; }
u_on() { printf '%s' "${U_ON["$1|$2"]:-0}"; }
u_set() { U_ON["$1|$2"]=$3; }
u_toggle() {
    if [ "$(u_on "$1" "$2")" = 1 ]; then u_set "$1" "$2" 0; else u_set "$1" "$2" 1; fi
}

u_path_get() {
    local page="$1" flag="$2" want="$3" oldifs="$IFS" pair
    IFS=';'
    for pair in ${U_PATH["$page|$flag"]:-}; do
        IFS="$oldifs"
        [ "${pair%%=*}" = "$want" ] && { printf '%s' "${pair#*=}"; return 0; }
        IFS=';'
    done
    IFS="$oldifs"
    return 0
}

u_path_set() {
    local page="$1" flag="$2" want="$3" value="$4"
    local oldifs="$IFS" pair out="" seen=0
    IFS=';'
    for pair in ${U_PATH["$page|$flag"]:-}; do
        IFS="$oldifs"
        if [ "${pair%%=*}" = "$want" ]; then
            pair="$want=$value"; seen=1
        fi
        out="${out:+$out;}$pair"
        IFS=';'
    done
    IFS="$oldifs"
    [ "$seen" = 1 ] || out="${out:+$out;}$want=$value"
    U_PATH["$page|$flag"]=$out
}

u_path_tags() {
    local page="$1" flag="$2" oldifs="$IFS" pair
    IFS=';'
    for pair in ${U_PATH["$page|$flag"]:-}; do
        IFS="$oldifs"
        printf '%s\n' "${pair%%=*}"
        IFS=';'
    done
    IFS="$oldifs"
}

menu_page_info() {
    local want="$1" p id tab key
    for p in "${PAGES[@]}"; do
        IFS='|' read -r id tab key <<< "$p"
        [ "$id" = "$menu_page" ] || continue
        case "$want" in
            tab) printf '%s' "$tab" ;;
            key)
                case "$id" in
                    1|2|3) printf 'build' ;;
                    *) printf '%s' "$key" ;;
                esac ;;
            engine) [ "${PAGE_KIND[$key]:-}" = engine ] && printf '%s' "$key" ;;
        esac
        return 0
    done
}

menu_units() {
    local op="$1" page="$2" kind="$3" arg="${4:-}" f out="" n=0
    for f in ${PAGE_UNITS[$page]:-}; do
        [ "$(u_kind "$page" "$f")" = "$kind" ] || continue
        n=$((n + 1))
        case "$op" in
            get)  [ "$(u_on "$page" "$f")" = 1 ] &&
                      { out="${out:+$out,}$f"; [ "$kind" = bin ] && break; } ;;
            set)  if [ "$kind" = bin ]; then
                      if [ "$f" = "$arg" ]; then u_set "$page" "$f" 1
                      else u_set "$page" "$f" 0; fi
                  else
                      case ",$arg," in *",$f,"*) u_set "$page" "$f" 1 ;;
                          *) u_set "$page" "$f" 0 ;; esac
                  fi ;;
        esac
    done
    case "$op" in
        get)  printf '%s' "$out" ;;
        count) printf '%s' "$n" ;;
    esac
}

menu_link() {
    local op="$1" eng="$2" idx="${3:-1}" value="${4:-}" f tags tag n=0
    f=$(menu_units get "$eng" bin)
    tags=$(u_path_tags "$eng" "$f")
    for tag in $tags; do
        n=$((n + 1))
        [ "$n" = "$idx" ] || continue
        case "$op" in
            tag)   printf '%s' "$tag" ;;
            get)   u_path_get "$eng" "$f" "$tag" ;;
            set)   u_path_set "$eng" "$f" "$tag" "$value" ;;
            count) printf '%s' "$n" ;;
        esac
        return 0
    done
    [ "$op" = count ] && printf '%s' "$n"
}

engine_link_var() {
    local eng="$1" want="$2" tags tag n=0
    tags=$(u_path_tags "$eng" link)
    for tag in $tags; do
        n=$((n + 1))
        [ "$tag" = "$want" ] || continue
        [ "$n" = 1 ] && { printf '%s' "${ENGINE_LINK_VAR1[$eng]:-}"; return 0; }
        [ "$n" = 2 ] && { printf '%s' "${ENGINE_LINK_VAR2[$eng]:-}"; return 0; }
    done
    return 1
}

assign_link() {
    local eng="$1" cell="$2" pair tag var oldifs="$IFS"
    IFS=';'
    for pair in $cell; do
        IFS="$oldifs"
        [ -n "$pair" ] || continue
        tag="${pair%%=*}"
        case "$pair" in *=*) ;; *)
            tag=$(u_path_tags "$eng" link | head -1)
            pair="$tag=$pair" ;;
        esac
        var=$(engine_link_var "$eng" "$tag") ||
            die "--${ENGINE_CLI[$eng]}:bin=link: unknown tag '$tag'"
        printf -v "$var" '%s' "${pair#*=}"
        IFS=';'
    done
    IFS="$oldifs"
}

declare -A TOOL_PATH=() TOOL_SUDO=()
tools_cache_init() {
    local page flag
    for page in "${PAGE_ORDER[@]}"; do
        [ "${PAGE_KIND[$page]:-}" = tool ] || continue
        for flag in ${PAGE_UNITS[$page]:-}; do
            [ "$(u_kind "$page" "$flag")" = tool ] || continue
            TOOL_PATH["$flag"]="${U_PATH["$page|$flag"]}"
            TOOL_SUDO["$flag"]="${U_SUDO["$page|$flag"]}"
        done
    done
}

# elevate=yes honours SUDO; elevate=no never asks for a password.
_tool_exec() {
    local elevate="$1" flag="${2:-}"
    shift 2 || true
    local path="${TOOL_PATH[$flag]:-}" sudo="${TOOL_SUDO[$flag]:-no}"
    [ -n "$flag" ] || die "_tool_exec: empty flag"
    [ -n "$path" ] || die "unknown tool '$flag'"
    [ -f "$DIR/$path" ] || die "tool script missing: $path"
    local -a env=(VMM_ROOT="$DIR" VMM_PREFIX="$prefix" VMM_SRC="$SRC"
                  VMM_BUILD="$BUILD" VMM_STATE="$STATE" VMM_USER="${SUDO_USER:-$(id -un)}")
    if [ "$elevate" = yes ] && [ "$sudo" = yes ]; then
        as_root env "${env[@]}" bash "$DIR/$path" "$@"
    else
        env "${env[@]}" bash "$DIR/$path" "$@"
    fi
}

run_tool() { _tool_exec yes "$@"; }

tool_var() {
    local p
    for p in host after; do
        [ -n "${U_VAR[$p|$1]:-}" ] && { printf '%s' "${U_VAR[$p|$1]}"; return 0; }
    done
}
probe_tool() { _tool_exec no "$@"; }

# Run all selected tools in one phase.  Order comes from NNNN-name in each
# page; VMM_PHASE and VMM_VAR/VMM_ARGS come from the tool headers.
run_tools_phase() {
    local phase="$1" page f v args
    for page in host after; do
        for f in ${PAGE_UNITS[$page]:-}; do
            [ "$(u_kind "$page" "$f")" = tool ] || continue
            [ "${U_PHASE[$page|$f]:-post}" = "$phase" ] || continue
            v=$(tool_var "$f")
            [ -n "$v" ] || continue
            [ "${!v:-0}" = 1 ] || continue
            args=${U_ARGS[$page|$f]:-}
            run_tool "$f" $args
        done
    done
}

engine_cache_init
tools_cache_init

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) install_usage; exit 0 ;;
        --list-patches) list=1; shift ;;
        --*:bin=*|--*:patch=*)
            arg="${1#--}"
            cli="${arg%%:*}"
            kind="${arg#*:}"; kind="${kind%%=*}"
            value="${arg#*=}"
            eng=""
            for e in "${ENGINES[@]}"; do
                [ "${ENGINE_CLI[$e]}" = "$cli" ] && { eng="$e"; break; }
            done
            [ -n "$eng" ] || die "unknown component '$cli'"
            var="${ENGINE_VAR[$eng]}"
            if [ "$kind" = bin ]; then
                mode="$value"; extra=""
                case "$mode" in
                    *:*) extra="${mode#*:}"; mode="${mode%%:*}" ;;
                esac
                case " ${BUILD_MODES[$eng]} " in
                    *" $mode "*) ;;
                    *) die "--$cli:bin expects one of: ${BUILD_MODES[$eng]}" ;;
                esac
                printf -v "${var}_bin" '%s' "$mode"
                printf -v "${var}_bin_given" '%s' 1
                [ -n "$extra" ] && assign_link "$eng" "$extra"
            elif [ "$kind" = patch ]; then
                assign_groups "$eng" "$value" "${var}_groups"
                printf -v "${var}_groups_given" '%s' 1
            else
                die "unknown option --$cli:$kind"
            fi
            shift ;;
        --tool=*)
            for t in $(printf '%s' "${1#*=}" | tr ',' ' '); do
                [ -z "$t" ] && continue
                v=$(tool_var "$t")
                [ -n "$v" ] || die "--tool: unknown item '$t' (see --help)"
                printf -v "$v" '%s' 1
                [ "$t" = libvirt-access ] && libvirt_access_given=1
            done
            shift ;;
        --update) update=1; shift ;;
        --prefix=*) prefix="${1#*=}"; shift ;;
        --jobs=*) jobs="${1#*=}"; shift ;;
        --dxvk-tarball=*) dxvk_tarball="${1#*=}"; shift ;;
        --dry-run) dry_run=1; shift ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

[ "$list" = 1 ] && { list_patches; exit 0; }
[ -f "$CONF" ] || die "missing $CONF"

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

# single-tag row is a program (must be executable) while a two-tag row is a
# data pair such as OVMF CODE/VARS (must exist as a file).
links_for() {
    local eng="$1" cell="${2:-}" check="${3:-no}" pair tag var path n=0
    local tags count oldifs="$IFS"
    tags=$(u_path_tags "$eng" link)
    count=$(printf '%s\n' "$tags" | grep -c .)
    IFS=';'
    for pair in $cell; do
        IFS="$oldifs"
        [ -n "$pair" ] || continue
        n=$((n + 1))
        tag="${pair%%=*}"
        case "$pair" in *=*) ;; *)
            tag=$(printf '%s\n' "$tags" | sed -n "${n}p")
            pair="$tag=$pair" ;;
        esac
        var=$(engine_link_var "$eng" "$tag") ||
            die "--${ENGINE_CLI[$eng]}:bin=link: unknown tag '$tag'"
        path=${pair#*=}
        if [ "$check" = yes ]; then
            [ -n "$path" ] || die "--${ENGINE_CLI[$eng]}:bin=link:$tag is empty"
            if [ "$count" -eq 1 ]; then
                [ -x "$path" ] || die "not executable: $path"
            else
                [ -f "$path" ] || die "no such file: $path"
            fi
            path=$(readlink -f "$path")
        fi
        printf -v "$var" '%s' "$path"
        IFS=';'
    done
    IFS="$oldifs"
}

validate_paths() {
    local eng var cell
    for eng in "${ENGINES[@]}"; do
        var="${ENGINE_VAR[$eng]}_bin"
        case "${!var}" in
            link) ;;
            compile|pull|skip|"") continue ;;
            *) die "--${ENGINE_CLI[$eng]}:bin expects ${BUILD_MODES[$eng]// /, }" ;;
        esac
        cell=""
        for var in ${ENGINE_LINK_VAR1[$eng]:-} ${ENGINE_LINK_VAR2[$eng]:-}; do
            cell="${cell:+$cell;}${!var:-}"
        done
        links_for "$eng" "$cell" yes
    done
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
if [ "$install_deps" = 1 ] ||
   [ "$session_vfio" = 1 ] ||
   [ "$emit_domains" = 1 ] || [ "$update" = 1 ] ||
   [ "$clean_sources" = 1 ] || [ "$clean_deps" = 1 ]; then
    other_action=1
fi

if [ "$dry_run" = 1 ]; then
    validate_paths
    if [ "$clean_sources" = 1 ] || [ "$clean_deps" = 1 ]; then
        note "dry run: would clean sources=$clean_sources deps=$clean_deps after any build"
    fi
    [ -n "$qemu_file" ] || die "qemu lock_file missing (use --update)"
    note "dry run: sources, patches and locks resolve; no changes made"
    exit 0
fi

if [ -z "$qemu_bin$vm_bin$ovmf_bin" ] && \
   [ "$install_deps" = 0 ] && [ "$session_vfio" = 0 ] && \
   [ "$emit_domains" = 0 ] && [ "$update" = 0 ] && \
   [ "$verify" = 0 ] && [ "$launchitem" = 0 ] && \
   [ "$clean_sources" = 0 ] && [ "$clean_deps" = 0 ] && [ ! -t 0 ]; then
    note "nothing to do (see --help)"
    exit 0
fi




menu_list_has() {
    case ",$1," in *",$2,"*) return 0 ;; esac
    return 1
}

# occurrence.  Order is otherwise irrelevant; nothing hardcodes it.
menu_dedupe() {
    local list="$1" out="" g
    for g in $(printf '%s' "$list" | tr ',' ' '); do
        [ -n "$g" ] || continue
        case " $out " in *" $g "*) ;; *) out="${out:+$out,}$g" ;; esac
    done
    printf '%s' "$out"
}

menu_page=1
menu_pages=6
menu_mode=normal          # normal | link | sudo
menu_raw=0
menu_stty=""
MENU_COLS=100
MENU_KEY=""
MENU_LETTERS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
declare -A MENU_ACTION=()
MENU_DONE=0
MENU_TEXT=""
menu_signal=0
menu_subfirst=1
menu_sudo_pending=""
menu_sudo_page=""
menu_sudo_letter=""
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

menu_frame() {
    local right="page $menu_page/$menu_pages" gap
    menu_calc_width
    gap=$(( MENU_COLS - 12 - ${#right} ))
    [ "$gap" -lt 1 ] && gap=1
    printf '\n'
    printf ' %s%sVMM BUILDER%s%*s%s%s%s\n' \
        "$c_bold" "$c_primary" "$c_reset" "$gap" "" \
        "$c_border" "$right" "$c_reset"
    printf ' %s%s%s\n' "$c_border" "$(printf '%*s' $((MENU_COLS - 1)) '' | tr ' ' '-')" "$c_reset"
}

menu_tabs() {
    local i=1
    for p in "${PAGES[@]}"; do
        IFS='|' read -r id tab _ <<< "$p"
        local n="$tab"
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
        [ "$i" -le "${#PAGES[@]}" ] &&
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

menu_row() {
    local key="$1" label="$2" value="$3" mark="$4" sel="$5" pending="${6:-0}"
    local keycol labelcol valuecol markcol right avail lab pad
    if [ "$sel" = 1 ]; then
        keycol="$c_bold$c_success"; labelcol="$c_bold$c_success"
        valuecol="$c_success"; markcol="$c_success"
    elif [ "$pending" = 1 ]; then
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

menu_path_line() {
    local text="$1" colour="${2:-$c_muted}"
    printf '           %s%s%s\n' "$colour" "$text" "$c_reset"
}

# Fold text into width w, using prefix p for the first line and rest for
menu_folded() {
    local first="$1" rest="$2" width="$3" colour="$4" text="$5" line flag=1
    [ "$width" -lt 12 ] && width=12
    { [ -n "$text" ] && printf '%s\n' "$text" || printf '\n'; } |
        fold -s -w "$width" | while IFS= read -r line; do
            if [ "$flag" = 1 ]; then
                printf '%s%s%s%s\n' "$first" "$colour" "$line" "$c_reset"
                flag=0
            else
                printf '%s%s%s%s\n' "$rest" "$colour" "$line" "$c_reset"
            fi
        done
}

menu_note() {
    local sel="${1:-0}" colour
    if [ "$sel" = 1 ]; then colour="$c_success"; else colour="$c_muted"; fi
    menu_folded '         ' '         ' "$((MENU_COLS - 9))" "$colour" "$2"
}

menu_path_ok() { [ -n "$1" ] && [ -e "$1" ]; }

menu_deps_missing() {
    local n=0
    [ "$(menu_units get qemu bin)" = compile ] && n=$((n + DEP_MISSING_QEMU))
    [ "$(menu_units get ovmf bin)" = compile ] && n=$((n + DEP_MISSING_OVMF))
    [ "$(menu_units get virt-manager bin)" = compile ] && n=$((n + DEP_MISSING_VM))
    printf '%s' "$n"
}

DEP_MISSING_QEMU=0
DEP_MISSING_VM=0
DEP_MISSING_OVMF=0
DEP_MISSING_RUNTIME=0
DEPS_SCANNED=0
deps_scan() {
    [ "$DEPS_SCANNED" = 1 ] && return 0
    local target count
    while IFS='|' read -r target count; do
        case "$target" in
            qemu)         DEP_MISSING_QEMU=$count ;;
            virt-manager) DEP_MISSING_VM=$count ;;
            ovmf)         DEP_MISSING_OVMF=$count ;;
            runtime)      DEP_MISSING_RUNTIME=$count ;;
        esac
    done < <(probe_tool deps --missing)
    DEPS_SCANNED=1
}

# not installed and the user has not chosen to install them.  menu_deps_missing
menu_build_blocked() {
    [ "$(u_on host deps)" = 1 ] && return 1
    [ "$(menu_deps_missing)" -gt 0 ]
}

menu_toggle_patch_group() {
    local engine="$1" flag="$2" f new=""
    if [ "$(u_on "$engine" "$flag")" = 1 ]; then
        for f in $(patch_flags "$engine"); do
            [ "$(u_on "$engine" "$f")" = 1 ] || continue
            [ "$f" = "$flag" ] && continue
            menu_list_has "$(unit_field "$engine" "$f" deps)" "$flag" ||
                new="${new:+$new,}$f"
        done
    else
        new=$(menu_units get "$engine" patch)
        for f in $flag $(printf '%s' "$(unit_field "$engine" "$flag" deps)" | tr ',' ' '); do
            [ -n "$f" ] || continue
            case ",$new," in *",$f,"*) ;; *) new="${new:+$new,}$f" ;; esac
        done
    fi
    menu_units set "$engine" patch "$(menu_dedupe "$new")"
}

menu_status() {
    local eng val out="" short plain=""
    for eng in "${ENGINES[@]}"; do
        val=$(menu_units get "$eng" bin)
        if [ "$val" = compile ]; then
            val="compile ($(menu_units count "$eng" patch)/$(menu_units count "$eng" patch))"
            short="c$(menu_units count "$eng" patch)/$(menu_units count "$eng" patch)"
        elif [ "$val" = pull ]; then
            val=bundled; short=bundled
        else
            short=$val
        fi
        plain="${plain:+$plain  |  }${ENGINE_LABEL[$eng]} $val"
        out="${out:+$out
}$eng|$val|$short"
    done
    [ $(( ${#plain} + 2 )) -gt "$MENU_COLS" ] && short=1 || short=0
    printf '\n '
    local first=1 e v
    while IFS='|' read -r e v val; do
        [ "$first" = 1 ] || printf '%s | %s' "$c_border" "$c_reset"
        first=0
        [ "$short" = 1 ] && v=$val
        case "$e" in
            qemu)         val=$c_primary ;;
            ovmf)         val=$c_accent ;;
            virt-manager) val=$c_secondary ;;
        esac
        printf '%s%s%s %s%s%s' "$c_bold$val" "${ENGINE_LABEL[$e]}" \
            "$c_reset" "$c_muted" "$v" "$c_reset"
    done <<< "$out"
    printf '\n'
}

menu_keys() {
    local key eng n last tags label range letters=ABCDEFGHIJKLMNOPQRSTUVWXYZ
    key=$(menu_page_info key)
    eng=$(menu_page_info engine)
    if [ -n "$eng" ]; then
        n=1
        [ "$(menu_units get "$eng" bin)" = compile ] &&
            n=$((1 + $(menu_units count "$eng" patch)))
    else
        n=$(menu_units count "$key" tool)
    fi
    if menu_build_blocked; then last=4; else last=${#PAGES[@]}; fi
    [ "$n" -lt 1 ] && n=1
    range=${letters:$((n - 1)):1}
    [ "$n" -gt 1 ] && range="A-$range"
    printf ' '
    if [ "$key" != review ]; then
        if [ "$key" = host ] && menu_build_blocked; then range=A; fi
        printf '%s[%s]%s%s%s' "$c_bold$c_info" "$range" "$c_reset" \
            "$c_muted" ' Select option'
        printf '    '
    fi
    if [ "$menu_mode" = link ]; then
        tags=$(u_path_tags "$eng" "$(menu_units get "$eng" bin)")
        label=$(printf '%s\n' "$tags" | tr '\n' '/'); label=${label%/}
        [ -n "$label" ] && printf '%s[/]%s Set %s path%s    ' \
            "$c_bold$c_info" "$c_reset" "$label" "$c_muted"
        [ "$menu_blocked" = 1 ] && last=$menu_page
    fi
    if [ "$key" = review ]; then
        printf '%s[Enter]%s Build    ' "$c_bold$c_info" "$c_reset"
    fi
    if [ "$menu_mode" = sudo ]; then
        printf '%s[/]%s Enter sudo password%s' \
            "$c_bold$c_warning" "$c_warning" "$c_reset"
    else
        printf '%s[1-%s]%s Select page%s' \
            "$c_bold$c_info" "$last" "$c_reset" "$c_muted"
    fi
    printf '%s\n' "$c_reset"
}

menu_render_page() {
    local page eng cli title idx=0 letter kind last="" sel pend bin
    eng=$(menu_page_info engine)
    if [ -n "$eng" ]; then page=$eng
    else page=$(menu_page_info key); fi
    [ "$page" = review ] && page=after
    [ -n "$page" ] || return 0
    if [ -n "$eng" ]; then
        cli=${ENGINE_CLI[$eng]}
        title="BUILD ITEMS | ${ENGINE_LABEL[$eng]}"
        bin=$(menu_units get "$eng" bin)
        idx=1
    else
        title=$(menu_page_info tab)
    fi
    menu_section "$title"
    MENU_ACTION=()
    [ -n "$eng" ] && menu_subsection "Binaries" "--$cli:bin"
    for f in ${PAGE_UNITS[$page]:-}; do
        kind=$(u_kind "$page" "$f")
        case "$kind" in
            bin)
                [ -n "$eng" ] || continue
                sel=$([ "$bin" = "$f" ] && echo 1 || echo 0)
                menu_row "$([ "$sel" = 1 ] && echo '[A]' || echo '   ')" \
                    "${U_NAME["$page|$f"]}" "$f" "$([ "$sel" = 1 ] && printf '(*)' || printf '( )')" "$sel"
                menu_note "$sel" "${U_DESC["$page|$f"]}"
                [ "$sel" = 1 ] && [ -n "$(u_path_tags "$page" "$f")" ] &&
                    menu_render_paths "$page" "$f"
                ;;
            patch)
                [ -n "$eng" ] && [ "$bin" = compile ] || continue
                if [ "$last" != patch ]; then
                    menu_subsection \
                        "Patches ($(menu_units count "$eng" patch)/$(menu_units count "$eng" patch))" \
                        "--$cli:patch"
                    last=patch
                fi
                letter="${MENU_LETTERS:$idx:1}"; idx=$((idx + 1))
                MENU_ACTION["${letter,,}"]="$page|$f|patch"
                sel=$(u_on "$page" "$f")
                menu_row "[$letter]" "${U_NAME["$page|$f"]}" "$f" \
                    "$([ "$sel" = 1 ] && printf '[*]' || printf '[ ]')" "$sel"
                menu_note "$sel" "${U_DESC["$page|$f"]}"
                ;;
            tool)
                letter="${MENU_LETTERS:$idx:1}"; idx=$((idx + 1))
                MENU_ACTION["${letter,,}"]="$page|$f|tool"
                sel=$(u_on "$page" "$f")
                pend=0
                [ "$menu_mode" = sudo ] && [ "$menu_sudo_pending" = "$f" ] && pend=1
                menu_row "[$letter]" "${U_NAME["$page|$f"]}" "$f" \
                    "$([ "$sel" = 1 ] && printf '[*]' || printf '[ ]')" "$sel" "$pend"
                menu_note "$sel" "${U_DESC["$page|$f"]}"
                ;;
        esac
    done
}

menu_render_paths() {
    local eng="$1" flag="$2" tags tag val n=0 count
    tags=$(u_path_tags "$eng" "$flag")
    count=$(printf '%s\n' "$tags" | grep -c .)
    for tag in $tags; do
        n=$((n + 1))
        val=$(u_path_get "$eng" "$flag" "$tag")
        if menu_path_ok "$val"; then
            if [ "$count" -gt 1 ]; then
                menu_path_line "Found: $tag: $val" "$([ "$menu_revert_label" = "$tag" ] && printf '%s' "$c_warning" || printf '%s' "$c_success")"
            else
                menu_path_line "Found: $val" "$([ "$menu_revert_label" = "$tag" ] && printf '%s' "$c_warning" || printf '%s' "$c_success")"
            fi
        elif [ "$count" -gt 1 ]; then
            menu_path_line "Not found: $tag" "$c_error"
        else
            menu_path_line "Not found: ${val:-$tag}" "$c_error"
        fi
    done
}

menu_sudo_ok() {
    [ "$(id -u)" = 0 ] && return 0
    sudo -n true 2>/dev/null
}


menu_render_review() {
    local eng clean="" misc="" host="" c_deps nbuild nrun depstr
    for eng in ${PAGE_UNITS[after]:-}; do
        [ "$(u_kind after "$eng")$(u_on after "$eng")" = tool1 ] || continue
        case "$eng" in *clean*) clean="${clean:+$clean,}$eng" ;;
            *) misc="${misc:+$misc,}$eng" ;; esac
    done
    for eng in ${PAGE_UNITS[host]:-}; do
        [ "$(u_kind host "$eng")$(u_on host "$eng")" = tool1 ] &&
            host="${host:+$host,}$eng"
    done
    nbuild=$(menu_deps_missing); nrun=$DEP_MISSING_RUNTIME
    if [ "$nbuild" -gt 0 ] || [ "$nrun" -gt 0 ]; then c_deps=$c_error; else c_deps=$c_success; fi
    if [ "$install_deps" = 1 ]; then depstr="install (build+runtime)"
    elif [ "$nbuild" -gt 0 ] || [ "$nrun" -gt 0 ]; then depstr=missing
    else depstr=ok; fi

    menu_section "REVIEW & RUN"
    menu_subsection "Selected"
    local l v
    for l in deps cleanup misc prefix; do
        case "$l" in
            deps) v=$depstr; colour=$c_deps ;;
            cleanup) v=${clean:-none}; colour=$c_warning ;;
            misc) v=${misc:-none}; colour=$c_warning ;;
            prefix) v=$prefix; colour=$c_text ;;
        esac
        menu_folded "       $(printf '%-14s ' "$l")" '                       ' \
            "$((MENU_COLS - 22))" "$colour" "$v"
    done
    [ -n "$host" ] && menu_folded "       $(printf '%-14s ' host)" \
        '                       ' "$((MENU_COLS - 22))" "$c_warning" "$host"

    menu_subsection "Command"
    local args=() a flag value i=0 n tail bin groups tools=() cell tag
    for eng in "${ENGINES[@]}"; do
        bin=$(menu_units get "$eng" bin); groups=$(menu_units get "$eng" patch)
        cli=${ENGINE_CLI[$eng]}
        case "$bin" in
            compile) args+=("--$cli:bin=compile" "--$cli:patch=$groups") ;;
            link)
                cell=""
                for tag in $(u_path_tags "$eng" link); do
                    cell="${cell:+$cell;}$tag=$(u_path_get "$eng" link "$tag")"
                done
                args+=("--$cli:bin=link:$cell") ;;
            pull) args+=("--$cli:bin=pull") ;;
            skip) args+=("--$cli:bin=skip") ;;
        esac
    done
    for a in host after; do
        for flag in ${PAGE_UNITS[$a]:-}; do
            [ "$(u_kind "$a" "$flag")$(u_on "$a" "$flag")" = tool1 ] &&
                tools+=("$flag")
        done
    done
    [ ${#tools[@]} -gt 0 ] && args+=("--tool=$(IFS=,; printf '%s' "${tools[*]}")")
    printf '       %s%s./install.sh%s %s\%s\n' \
        "$c_bold" "$c_primary" "$c_reset" "$c_border" "$c_reset"
    n=${#args[@]}
    for a in "${args[@]}"; do
        i=$((i + 1)); [ "$i" -lt "$n" ] && tail=' \' || tail=''
        case "$a" in
            *[!A-Za-z0-9_./:=+@%,-]*)
                printf "         '%s'%s\n" "${a//\'/\'\\\'\'}" "$tail" ;;
            --*=*)
                flag=${a%%=*}; value=${a#*=}
                printf '         %s%s%s=%s%s%s%s\n' "$c_info" "$flag" \
                    "$c_reset" "$c_success" "$value" "$c_reset" "$tail" ;;
            *)
                printf '         %s%s%s%s\n' "$c_info" "$a" "$c_reset" "$tail" ;;
        esac
    done
}

menu_render() {
    local nrun nbuild
    MENU_PAGE_WARN=""
    if [ "$install_deps" = 0 ]; then
        nrun=$DEP_MISSING_RUNTIME
        case "$menu_page" in
            4)
                nbuild=$(menu_deps_missing)
                [ "$nbuild" -gt 0 ] &&
                    MENU_PAGE_WARN="  [X]  ERROR: $nbuild missing build dependencies, install or remove compilation items" ;;
            5|6) ;;
            *) nrun=0 ;;
        esac
        [ "$nrun" -gt 0 ] &&
            MENU_PAGE_WARN="${MENU_PAGE_WARN:+$MENU_PAGE_WARN
}  [!]  WARNING: $nrun missing runtime dependencies"
    fi
    menu_calc_width
    [ -t 1 ] && { clear 2>/dev/null || printf '\033[H\033[2J'; }
    menu_frame
    menu_tabs
    if [ "$(menu_page_info key)" = review ]; then
        menu_render_review
    else
        menu_render_page
    fi
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
            printf '%s%s%s%s%s\n' \
                "$c_bold$nc" "$prefix" "$c_reset$nc" "$rest" "$c_reset"
        done <<EOF
$MENU_PAGE_WARN
$menu_warn
$menu_error
EOF
    fi
    menu_status
    printf ' %s%s%s\n' "$c_border" "$(printf '%*s' $((MENU_COLS - 1)) '' | tr ' ' '-')" "$c_reset"
    menu_keys
    printf ' %s%sSelect:%s ' "$c_bold" "$c_info" "$c_reset"
}

menu_term() {
    case "$1" in
        init)   menu_stty=$(stty -g 2>/dev/null || true); menu_term raw ;;
        cooked) [ -n "$menu_stty" ] && stty "$menu_stty" 2>/dev/null; menu_raw=0 ;;
        done)   menu_term cooked ;;
        raw)    if [ -n "$menu_stty" ]; then
                    stty -echo -icanon min 1 time 0 2>/dev/null && menu_raw=1
                fi ;;
    esac
}

# A plain key read must not exit inside the trap: bash's read reasserts the
menu_on_int() {
    if [ "$menu_text_active" = 1 ]; then
        menu_term done
        printf '\n'
        exit 130
    fi
    menu_signal=1
}

menu_link_state() {
    local eng missing=""
    eng=$(menu_page_info engine)
    if ! menu_path_ok "$(menu_link get "$eng" 1)"; then
        missing=$(menu_link tag "$eng" 1)
    elif [ "$(menu_link count "$eng")" -ge 2 ] &&
         ! menu_path_ok "$(menu_link get "$eng" 2)"; then
        missing=$(menu_link tag "$eng" 2)
    fi
    if [ -n "$missing" ]; then
        menu_error="  [X]  ERROR: Cannot proceed, fix path to $missing binary or select another option"
        menu_blocked=1
        return 1
    fi
    menu_error=""
    menu_blocked=0
    return 0
}

# a blocking path error cannot be lost by navigating away and back.
menu_page_mode() {
    local eng
    menu_revert_label=""
    menu_warn=""
    menu_error=""
    MENU_PAGE_WARN=""
    eng=$(menu_page_info engine)
    if [ -n "$eng" ] && [ "$(menu_units get "$eng" bin)" = link ]; then
        menu_mode=link
        menu_link_state || true
        return
    fi
    menu_mode=normal
    menu_warn=""
    menu_error=""
    menu_blocked=0
}

menu_cycle_build() {
    local eng="$1" modes cur m next="" found=0
    modes=${BUILD_MODES[$eng]:-}
    [ -n "$modes" ] || return 0
    cur=$(menu_units get "$eng" bin)
    for m in $modes; do
        if [ "$found" = 1 ]; then next=$m; break; fi
        [ "$m" = "$cur" ] && found=1
    done
    [ -n "$next" ] || next=${modes%% *}
    menu_units set "$eng" bin "$next"
    menu_warn=""
    menu_error=""
    menu_revert_label=""
    if [ "$next" = link ]; then
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
    printf -v prompt ' \001%s%s\002Text:\001%s\002 ' \
        "$c_bold" "$c_info" "$c_reset"
    menu_text_active=1
    menu_term cooked
    if ! IFS= read -r -e -i "$current" -p "$prompt" out; then
        menu_term raw
        menu_text_active=0
        printf '\n'
        return 1
    fi
    menu_term raw
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

menu_edit_build_path() {
    local eng="$1" idx=1 tag old
    menu_warn=""
    while :; do
        tag=$(menu_link tag "$eng" "$idx")
        [ -n "$tag" ] || break
        old=$(menu_link get "$eng" "$idx")
        menu_prompt_path "$tag" "$old" || { menu_link_state || true; return; }
        if menu_path_ok "$MENU_TEXT"; then
            menu_link set "$eng" "$idx" "$MENU_TEXT"
            menu_revert_label=""
        else
            if menu_path_ok "$old"; then
                menu_revert_label=$tag
                menu_warn="  [!]  WARNING: Invalid path, reverting to found $tag binary"
            else
                menu_revert_label=""
            fi
            menu_link_state || true
            return
        fi
        idx=$((idx + 1))
    done
    menu_link_state || true
}


tool_set() {
    local flag="$1" on="$2" v
    v=$(tool_var "$flag")
    [ -n "$v" ] && printf -v "$v" '%s' "$on"
}

menu_handle() {
    local k="$1" lk pending entry page flag kind eng
    lk=${k,,}

    if [ "$menu_mode" = link ]; then
        eng=$(menu_page_info engine)
        case "$lk" in
            a) [ -n "$eng" ] && menu_cycle_build "$eng" ;;
            /) [ -n "$eng" ] && menu_edit_build_path "$eng" ;;
            [1-6])
                [ "$menu_blocked" = 0 ] &&
                    { ! menu_build_blocked || [ "$lk" -le 4 ]; } &&
                    { menu_page=$lk; menu_page_mode; } ;;
        esac
        return
    fi

    if [ "$menu_mode" = sudo ]; then
        [ "$lk" = / ] || {
            case "$lk" in [1-6]) return ;; esac
            pending="$menu_sudo_letter"
            menu_sudo_pending=""; menu_sudo_page=""; menu_mode=normal
            [ "$lk" = "$pending" ] && return
            return
        }
        printf '\n'
        menu_text_active=1; menu_term cooked
        if sudo -v; then
            u_set "$menu_sudo_page" "$menu_sudo_pending" 1
            tool_set "$menu_sudo_pending" 1
            menu_sudo_pending=""; menu_sudo_page=""; menu_mode=normal
            menu_warn=""; menu_error=""
        else
            menu_error="  [X]  SUDO ACCESS DENIED: Cannot proceed; fix access or select another option"
            menu_mode=sudo
        fi
        menu_term raw; menu_text_active=0
        return
    fi

    if [ "$k" = $'\n' ] || [ "$k" = $'\r' ]; then
        [ "$menu_page" = 6 ] && MENU_DONE=1
        return
    fi
    case "$lk" in
        [1-6])
            if menu_build_blocked && [ "$lk" -ge 4 ]; then
                [ "$lk" = 4 ] && { menu_page=4; menu_page_mode; }
                return
            fi
            menu_page=$lk; menu_page_mode; return ;;
    esac
    menu_warn=""; menu_error=""
    entry="${MENU_ACTION[$lk]:-}"
    if [ -n "$entry" ]; then
        IFS='|' read -r page flag kind <<< "$entry"
        case "$kind" in
            patch) [ "$(menu_units get "$page" bin)" = compile ] &&
                       menu_toggle_patch_group "$page" "$flag" ;;
            tool)
                menu_build_blocked && [ "$flag" != deps ] && return
                if [ "$(u_on "$page" "$flag")" = 0 ] &&
                   [ "${U_SUDO["$page|$flag"]}" = yes ] && ! menu_sudo_ok; then
                    menu_sudo_pending=$flag; menu_sudo_page=$page
                    menu_sudo_letter=$lk; menu_mode=sudo
                else
                    u_toggle "$page" "$flag"
                    tool_set "$flag" "$(u_on "$page" "$flag")"
                fi ;;
        esac
    elif [ "$lk" = a ] && [ -n "$(menu_page_info engine)" ]; then
        menu_cycle_build "$(menu_page_info engine)"
    fi
}

menu_sync() {
    local dir="$1" eng v gv f page mode v1 v2
    [ "$dir" = import ] && record_load
    for eng in "${ENGINES[@]}"; do
        v=${ENGINE_VAR[$eng]}_bin; gv=${v}_given
        if [ "$dir" = import ]; then
            mode=${!v:-${BUILD_MODES[$eng]%% *}}
            [ "$eng" = ovmf ] && [ -z "${!v:-}" ] &&
                [ ! -f "$DIR/share/firmware/OVMF/OVMF_CODE_4M.fd" ] && mode=compile
            menu_units set "$eng" bin "$mode"
            v=${ENGINE_VAR[$eng]}_groups; gv=${v}_given
            menu_units set "$eng" patch "$([ "${!gv:-0}" = 1 ] &&
                printf '%s' "$(menu_dedupe "${!v:-}")" || default_groups "$eng")"
        else
            printf -v "$v" '%s' "$(menu_units get "$eng" bin)"
            printf -v "$gv" '%s' 1
            v=${ENGINE_VAR[$eng]}_groups; gv=${v}_given
            printf -v "$v" '%s' "$(menu_units get "$eng" patch)"
            printf -v "$gv" '%s' 1
            if [ "$(menu_units get "$eng" bin)" = link ]; then
                v1=${ENGINE_LINK_VAR1[$eng]:-}; v2=${ENGINE_LINK_VAR2[$eng]:-}
                [ -n "$v1" ] && printf -v "$v1" '%s' "$(menu_link get "$eng" 1)"
                [ -n "$v2" ] && printf -v "$v2" '%s' "$(menu_link get "$eng" 2)"
            fi
        fi
    done
    [ "$dir" = import ] && {
        [ "$clean_given" = 0 ] && { clean_sources=1; clean_deps=0; }
        [ "$misc_given" = 0 ] && { verify=1; launchitem=1; }
        [ "$libvirt_access_given" = 0 ] && libvirt_access=1
    }
    for page in host after; do
        for f in ${PAGE_UNITS[$page]:-}; do
            [ "$(u_kind "$page" "$f")" = tool ] || continue
            v=$(tool_var "$f"); [ -n "$v" ] || continue
            if [ "$dir" = import ]; then
                [ "${!v:-0}" = 1 ] && u_set "$page" "$f" 1
            else
                printf -v "$v" '%s' "$(u_on "$page" "$f")"
            fi
        done
    done
    if [ "$dir" = import ]; then
        menu_mode=normal; menu_warn=""; menu_error=""
        menu_sudo_pending=""; menu_sudo_page=""; menu_blocked=0
        menu_page_mode
    else
        clean_given=1; misc_given=1
        [ "$install_deps" = 1 ] && install_deps=1
    fi
}

menu_read_key() {
    local k line rc
    if [ "$menu_raw" = 1 ]; then
        while :; do
            IFS= read -rsN1 -t 0.2 k; rc=$?
            [ "$rc" = 0 ] && break
            [ "$menu_signal" = 1 ] && return 1
            [ "$rc" -gt 128 ] && continue
            return 1
        done
        if [ "$k" = $'\033' ]; then
            IFS= read -rsn1 -t 0.01 _ 2>/dev/null || true
            IFS= read -rsn1 -t 0.01 _ 2>/dev/null || true
            MENU_KEY=""
        else
            MENU_KEY=$k
        fi
    else
        IFS= read -r line || return 1
        MENU_KEY=${line:0:1}
        [ -z "$line" ] && MENU_KEY=$'\n'
    fi
    printf '\n'
}

menu_run() {
    deps_scan
    menu_sync import
    MENU_DONE=0; menu_signal=0
    menu_term init
    trap 'menu_on_int' INT
    trap 'menu_signal=1' TERM
    trap 'menu_term done' EXIT
    while [ "$MENU_DONE" = 0 ]; do
        menu_render
        menu_read_key || break
        [ "$menu_signal" = 1 ] && break
        [ -n "$MENU_KEY" ] && menu_handle "$MENU_KEY"
        [ "$menu_signal" = 1 ] && break
    done
    menu_term done
    trap - INT TERM EXIT
    [ "$menu_signal" = 1 ] && { printf '\n'; exit 130; }
    menu_sync export
    printf '\n'
}

menu_needed=0
if [ -t 0 ] && [ "$dry_run" = 0 ] && [ "$update" = 0 ] && [ "$list" = 0 ] &&
   [ "$clean_sources$clean_deps" = 00 ] &&
   [ "$qemu_bin_given$vm_bin_given$ovmf_bin_given" != 111 ]; then
    if [ "$component_given" = 1 ] || [ "$other_action" = 0 ]; then
        menu_needed=1
    fi
fi
if [ "$menu_needed" = 1 ]; then
    menu_run
fi

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
   [ "$install_deps" = 0 ] && [ "$session_vfio" = 0 ] && \
   [ "$emit_domains" = 0 ] && [ "$update" = 0 ] && \
   [ "$verify" = 0 ] && [ "$launchitem" = 0 ] && \
   [ "$clean_sources" = 0 ] && [ "$clean_deps" = 0 ]; then
    note "nothing selected (see --help)"
    exit 0
fi

run_tools_phase early
[ "$install_deps" = 1 ] && DEPS_SCANNED=0

deps_scan

if [ "$vm_bin" = compile ] && [ "$DEP_MISSING_VM" -gt 0 ]; then
    die "$DEP_MISSING_VM missing build dependencies for virt-manager; install them or rerun with the deps tool"
fi

if [ "$qemu_bin" = compile ] && [ "$DEP_MISSING_QEMU" -gt 0 ]; then
    die "$DEP_MISSING_QEMU missing build dependencies for qemu; install them or rerun with the deps tool"
fi

if [ "$ovmf_mode" = build ] && [ "$DEP_MISSING_OVMF" -gt 0 ]; then
    die "$DEP_MISSING_OVMF missing build dependencies for OVMF; install them or rerun with the deps tool"
fi

mkdir -p "$BUILD" "$DL" "$SRC"


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

fetch_source() {
    local name="$1" dir="$2" ref="$3" tb="$4" url="$5" builddir="$6"
    if source_ok "$dir" "$ref"; then return 0; fi
    rm -rf "$dir" "$BUILD/$builddir"
    fetch "$url" "$tb"
    mkdir -p "$dir"
    tar -xf "$tb" -C "$dir" --strip-components=1
    mark_source "$dir" "$ref"
    note "$name $ref extracted"
}

fetch_vm() {
    fetch_source virt-manager "$SRC/virt-manager-$vm_lock" \
        "$vm_lock+$enable_vm" "$DL/virt-manager-$vm_lock.tar.gz" \
        "$(conf_get virt-manager file)" vm-build
}

fetch_qemu() {
    fetch_source qemu "$SRC/qemu-$qemu_lock" "$qemu_lock+$enable_qemu" \
        "$DL/$qemu_file" "$(conf_get qemu url)/$qemu_file" qemu-build
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

fetch_virgl() {
    local dir="$SRC/virglrenderer"
    git_checkout virglrenderer "$(conf_get virglrenderer url)" "$virgl_lock" "$dir" "venus"
    if [ ! -d "$dir/subprojects/venus-protocol-1.1.3" ]; then
        note "venus-protocol subproject downloads during meson setup"
    fi
}


build_env() {
    export VMM_SRC="$SRC" VMM_BUILD="$BUILD" VMM_PREFIX="$prefix" \
           VMM_JOBS="$jobs"
}

build_component() {
    local eng="$1" groups label log rc=0
    case "$eng" in
        qemu)
            [ -d "$SRC/qemu-$qemu_lock" ] || die "missing qemu source"
            local dxvk
            if [ -n "$dxvk_tarball" ]; then
                dxvk=$dxvk_tarball
                [ -f "$dxvk" ] || die "no such tarball: $dxvk"
            else
                dxvk=$("$DIR/tools/build.sh" dxvk) || die "dxvk-native build failed"
            fi
            export VMM_DXVK_TARBALL="$dxvk"
            export VMM_PREFIX="$prefix/qemu"
            groups=$qemu_groups; label="qemu" ;;
        virt-manager) groups=$vm_groups; label="virt-manager" ;;
        ovmf)
            section "firmware"
            [ -d "$SRC/qemu-$qemu_lock/roms/edk2/OvmfPkg" ] ||
                die "edk2 snapshot missing from the QEMU tarball"
            groups=$ovmf_groups; label="OVMF" ;;
        *) die "unknown build component '$eng'" ;;
    esac
    build_env
    log="$BUILD/logs/$eng-build.log"
    mkdir -p "${log%/*}"
    env -i PATH="$PATH" HOME="${HOME:-/root}" \
        VMM_ROOT="$DIR" VMM_SRC="$SRC" VMM_BUILD="$BUILD" \
        VMM_PREFIX="$prefix" VMM_JOBS="$jobs" \
        "$DIR/tools/build.sh" build "$eng" --patch="$groups" >"$log" 2>&1 || rc=$?
    cat "$log"
    [ "${rc:-0}" = 0 ] || die "$label build failed"
    [ "$eng" = qemu ] && note "qemu profile at $prefix/qemu"
}


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
    install -m 0755 "$DIR/share/launch.sh" "$prefix/launch.sh" ||
        die "cannot install launcher"
    ensure_front_links
    install -m 0755 "$DIR/share/bin/vmm-qemu" "$prefix/bin/vmm-qemu"
    install -m 0755 "$DIR/share/bin/vmm-render" "$prefix/bin/vmm-render"
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
        install -m 0644 "$DIR/share/examples/profile.conf.in" "$prefix/profile.conf" ||
            die "missing $DIR/share/examples/profile.conf.in"
    fi
}

# launcher renders from these copies, never from the source tree.
install_examples() {
    local src="$DIR/share/examples" dst="$prefix/share/examples"
    [ -d "$src" ] || return 0
    mkdir -p "$dst" || { warn "cannot create $dst"; return 0; }
    cp -f "$src/"*.xml.in "$dst/" 2>/dev/null || true
    [ -f "$src/profile.conf.in" ] &&
        cp -f "$src/profile.conf.in" "$dst/profile.conf.in"
}

# Front scripts live at the install root and point into the tree. The copy
# branch covers filesystems without symlink support (NTFS, SMB2).
ensure_front_links() {
    local rel="$prefix/launch.sh" dst="$ROOT/launch.sh"
    [ "$ROOT" = "$DIR" ] && return 0
    [ -x "$rel" ] || return 0
    rm -f "$dst" 2>/dev/null || true
    ln -s "$rel" "$dst" 2>/dev/null && return 0
    cp -f "$DIR/$rel" "$dst" 2>/dev/null && chmod 0755 "$dst" && return 0
    warn "cannot link or copy $dst"
}



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

tags = json.loads(curl('https://api.github.com/repos/virt-manager/virt-manager/tags?per_page=100'))
tag = max((t['name'] for t in tags if re.match(r'^v\d+\.\d+\.\d+$', t['name'])), key=vkey)
if tag != get('virt-manager', 'lock'):
    put('virt-manager', 'lock', tag)
    put('virt-manager', 'file',
        'https://github.com/virt-manager/virt-manager/archive/refs/tags/%s.tar.gz' % tag)
put('virt-manager', 'lock_commit',
    git_ref(get('virt-manager', 'url'), 'refs/tags/%s^{}' % tag))

listing = curl('https://download.qemu.org/')
vers = sorted({m.group(1) for m in re.finditer(r'qemu-(\d+\.\d+\.\d+)\.tar\.xz', listing)}, key=vkey)
if vers:
    put('qemu', 'lock', vers[-1])
    put('qemu', 'lock_file', 'qemu-%s.tar.xz' % vers[-1])

put('vmvga', 'lock', git_ref(get('vmvga', 'url'), 'refs/heads/' + get('vmvga', 'ref')))
put('virglrenderer', 'lock', git_ref(get('virglrenderer', 'url'), 'HEAD'))

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
    build_component virt-manager
fi

if [ "$qemu_bin" = compile ] || [ "$ovmf_mode" = build ]; then
    fetch_qemu
fi

if [ "$ovmf_mode" = build ]; then
    build_component ovmf
fi

if [ "$qemu_bin" = link ]; then
    mkdir -p "$prefix/state"
    note "reusing $qemu_link; profile and virgl are not built"
    ln -sfn "$qemu_link" "$prefix/state/qemu"
fi

if [ "$qemu_bin" = compile ]; then
    rm -f "$prefix/state/qemu"
    fetch_virgl
    build_component qemu
fi

if [ "$qemu_bin" = compile ] || [ "$qemu_bin" = link ] ||
   [ "$vm_bin" = compile ] || [ "$vm_bin" = link ]; then
    install_launchers || die "launcher install failed"
    run_tools_phase define
    "$DIR/share/bin/vmm-relocate" "$prefix" || die "prefix relocation failed"
    if command -v virsh >/dev/null 2>&1 &&
       [ -x "$prefix/bin/vmm-render" ] && [ -f "$prefix/profile.conf" ]; then
        "$prefix/bin/vmm-render" --define ||
            warn "could not define domains; launch will retry"
    fi
elif [ -n "$ovmf_mode" ]; then
    mkdir -p "$prefix"
    install_firmware
fi
ensure_front_links
run_tools_phase post
run_tools_phase final
if [ "$clean_sources" = 0 ] && [ -d "$BUILD" ]; then
    note "build sources kept at $BUILD"
fi

note "done"
