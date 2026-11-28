#!/bin/bash
# VMM engine tool: engines, build modes, patch discovery, patch application
# and the actual builds.  install.sh is the only caller and is the only file
# that knows about hosts, prefixes, launchers and the TUI; this file knows
# nothing about any of that.
#
# Queries (read-only, no side effects):
#   tools/build.sh --list-engines
#       CLI_PREFIX|ENGINE|VAR
#   tools/build.sh --list-builds ENGINE
#       MODE|LABEL|DESCRIPTION|PATHKIND      (PATHKIND: -, path, path2)
#   tools/build.sh --list-patches ENGINE
#       FLAG|NAME|DESC|DEPS|TICK|RELATIVE_PATH
#   tools/build.sh --query FIELD ENGINE FLAG[,FLAG...]
#       FIELD: path|name|desc|deps|tick
#
# Actions:
#   tools/build.sh build ENGINE --patch=FLAG[,FLAG...]
#   tools/build.sh dxvk                 (prints the tarball path)
#
# Environment (exported by install.sh):
#   VMM_SRC      source cache root
#   VMM_BUILD    build output root
#   VMM_PREFIX   install prefix
#   VMM_JOBS     parallel jobs
#   VMM_CFLAGS, VMM_CXXFLAGS
#   VMM_OFFLINE  1 = never touch the network
# Optional overrides (derived from upstreams.conf otherwise):
#   VMM_QEMU_SRC VMM_VM_SRC VMM_VIRGL_SRC VMM_EDK2_SRC VMM_OVMF_OUT
#   VMM_DXVK_SRC VMM_DXVK_LOCK VMM_DXVK_URL VMM_DXVK_TARBALL
#
# Patch metadata lives in the leading comment block of each file under
# patches/<engine>/.  Recognised keys:
#   VMM_FLAG    required, the value passed on --patch=
#   VMM_NAME    required, TUI label
#   VMM_DESC    TUI description
#   VMM_DEPS    comma separated flags enabled together ("-" for none)
#   VMM_TICK    yes = ticked by default
#   VMM_SOURCE  upstreams.conf key to check out before running a .sh
#   VMM_INSTALL SRC:DEST — extra file to install after a virt-manager build
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
CONF="$SELF_DIR/upstreams.conf"
PATCH_ROOT="$ROOT/patches"
TOOL_ROOT="$ROOT/tools"
[ -f "$SELF_DIR/lib.sh" ] && . "$SELF_DIR/lib.sh"

# Link targets per engine.  Only OVMF has a second (CODE + VARS) pair.
declare -A ENG_LINK_TAG1=([qemu]=QEMU [ovmf]=CODE [virt-manager]=virt-manager)
declare -A ENG_LINK_TAG2=([ovmf]=VARS)

OVMF_CODE_PATHS=(
    "/usr/share/OVMF/OVMF_CODE_4M.fd"
    "/usr/share/ovmf/OVMF_CODE_4M.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd"
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
    "/usr/share/ovmf/x64/OVMF_CODE.4m.fd"
)
OVMF_VARS_PATHS=(
    "/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/ovmf/OVMF_VARS_4M.fd"
    "/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
    "/usr/share/ovmf/x64/OVMF_VARS.4m.fd"
)

# ---------------------------------------------------------------- metadata

# Print every value of KEY from the leading comment block of FILE.
patch_list_field() {
    local file="$1" key="$2" line val
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            "# $key:"*) val="${line#*"$key":}"; printf '%s\n' "${val# }" ;;
            "#"*|"") ;;
            *) return 0 ;;
        esac
    done < "$file"
    return 0
}

# ---------------------------------------------------------------- units

# The record shared by patches, tools and build modes:
#   KIND|PAGE|FLAG|NAME|DESC|DEPS|PATH|TICK|POST|SUDO
# Strings first, booleans last, SUDO last so every row ends in a fixed word.
# KIND and PATH are derived; the rest come from the leading header block.

unit_emit() {
    local kind="$1" page="$2" flag="$3" name="$4" desc="$5"
    local deps="$6" path="$7" tick="$8" post="$9" sudo="${10}"
    local f
    for f in "$kind" "$page" "$flag" "$name" "$desc" "$deps" "$path" \
             "$tick" "$post" "$sudo"; do
        case "$f" in *"|"*) die "record field contains '|': $f" ;; esac
    done
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$kind" "$page" "$flag" "$name" "$desc" "$deps" "$path" \
        "$tick" "$post" "$sudo"
}

unit_bool() {
    case "${2:-}" in
        "") printf '%s' "$1" ;;
        yes|no) printf '%s' "$2" ;;
        *) die "${3:-metadata}: expected yes or no, got '$2'" ;;
    esac
}

# Emit one page of file-backed units.  ROOT is patches/ or tools/.
unit_scan_page() {
    local kind="$1" page="$2" root="$3"
    local dir="$root/$page" f flag name desc hpage deps tick post sudo rel
    local -A seen=()
    [ -n "$page" ] || die "unit_scan_page: empty page"
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        flag=$(header_field "$f" VMM_FLAG)
        name=$(header_field "$f" VMM_NAME)
        desc=$(header_field "$f" VMM_DESC)
        # A file missing the mandatory fields is skipped, not fatal.
        [ -n "$flag" ] && [ -n "$name" ] && [ -n "$desc" ] || continue
        hpage=$(header_field "$f" VMM_PAGE)
        rel="${f#"$ROOT"/}"
        [ -n "$hpage" ] || die "$rel: VMM_PAGE is required"
        [ "$hpage" = "$page" ] ||
            die "$rel: VMM_PAGE '$hpage' does not match directory '$page'"
        [ -n "${seen[$flag]:-}" ] &&
            die "duplicate $kind flag '$flag' in $page (${seen[$flag]} and $rel)"
        seen[$flag]="$rel"
        deps=""; post=no; sudo=no
        [ "$kind" = patch ] && {
            deps=$(header_field "$f" VMM_DEPS)
            [ "$deps" = "-" ] && deps=""
        }
        tick=$(unit_bool no "$(header_field "$f" VMM_TICK)" "$rel")
        if [ "$kind" = tool ]; then
            post=$(unit_bool yes "$(header_field "$f" VMM_POST)" "$rel")
            sudo=$(unit_bool no "$(header_field "$f" VMM_SUDO)" "$rel")
        fi
        unit_emit "$kind" "$page" "$flag" "$name" "$desc" \
            "$deps" "$rel" "$tick" "$post" "$sudo"
    done < <(find "$dir" -maxdepth 1 -type f \
        \( -name '*.patch' -o -name '*.sh' \) -print | LC_ALL=C sort)
}

# Link targets are engine data, resolved here so the UI never names a tag.
ovmf_find_code() {
    local f
    for f in "${OVMF_CODE_PATHS[@]}"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
}

ovmf_find_vars() {
    local f
    for f in "${OVMF_VARS_PATHS[@]}"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
}

link_default() {
    case "$1:${2:-1}" in
        qemu:1) command -v qemu-system-x86_64 2>/dev/null || true ;;
        virt-manager:1) command -v virt-manager 2>/dev/null || true ;;
        ovmf:1) ovmf_find_code ;;
        ovmf:2) ovmf_find_vars ;;
    esac
}

# TAG=value;TAG=value for a mode, or empty when it takes no input.
bin_inputs() {
    local page="$1" pathkind="$2" out tag
    case "$pathkind" in
        -|"") printf ''; return 0 ;;
        path|path2) ;;
        *) die "$page: unknown path kind '$pathkind'" ;;
    esac
    tag=${ENG_LINK_TAG1[$page]:-}
    [ -n "$tag" ] || die "$page: no link tag declared"
    out="$tag=$(link_default "$page" 1)"
    if [ "$pathkind" = path2 ]; then
        tag=${ENG_LINK_TAG2[$page]:-}
        [ -n "$tag" ] || die "$page: no second link tag declared"
        out="$out;$tag=$(link_default "$page" 2)"
    fi
    printf '%s' "$out"
}

bin_scan() {
    local page="$1" flag name desc pathkind
    [ -n "$page" ] || die "bin_scan: empty page"
    while IFS='|' read -r flag name desc pathkind; do
        [ -n "$flag" ] || continue
        unit_emit bin "$page" "$flag" "$name" "$desc" "" \
            "$(bin_inputs "$page" "$pathkind")" no no no
    done < <(list_builds "$page")
}

# Every unit, grouped by page: engine bins then patches, then host, then after.
unit_list() {
    local cli page var
    while IFS='|' read -r cli page var; do
        [ -n "$page" ] || continue
        bin_scan "$page"
        unit_scan_page patch "$page" "$PATCH_ROOT"
    done < <(list_engines)
    unit_scan_page tool host "$TOOL_ROOT"
    unit_scan_page tool after "$TOOL_ROOT"
}

# ---------------------------------------------------------------- compat views

patch_scan() {
    local eng="${1:-}" out kind page flag name desc deps path tick post sudo
    [ -n "$eng" ] || die "--list-patches needs an engine"
    out=$(unit_scan_page patch "$eng" "$PATCH_ROOT") || exit 1
    [ -n "$out" ] || return 0
    while IFS='|' read -r kind page flag name desc deps path tick post sudo; do
        [ -n "$kind" ] || continue
        printf '%s|%s|%s|%s|%s|%s\n' \
            "$flag" "$name" "$desc" "${deps:--}" "$tick" "$path"
    done <<< "$out"
}

# One field lookup for any record kind/page/flag.  patch_rel, patch_deps and
# --query used to each rescan the whole page and re-parse it with awk.
unit_row() {
    local kind="$1" page="$2" want="$3" field="$4"
    local root="$PATCH_ROOT" out k pg flag name desc deps path tick post sudo
    [ "$kind" = tool ] && root="$TOOL_ROOT"
    out=$(unit_scan_page "$kind" "$page" "$root") || exit 1
    [ -n "$out" ] || return 0
    while IFS='|' read -r k pg flag name desc deps path tick post sudo; do
        [ "$flag" = "$want" ] || continue
        case "$field" in
            kind|page|flag|name|desc|deps|path|tick|post|sudo)
                printf '%s\n' "${!field}" ;;
            *) die "unknown record field '$field'" ;;
        esac
        return 0
    done <<< "$out"
    return 0
}

patch_rel()  { unit_row patch "${1:-}" "${2:-}" path; }
patch_deps() { unit_row patch "${1:-}" "${2:-}" deps; }

# Resolve FLAGS plus everything they list in VMM_DEPS.  One flag per line.
patch_resolve() {
    local eng="${1:-}"; shift || true
    local -A seen=() emitted=()
    local -a queue=() out=()
    local g d deps oldifs x i=0
    for g in "$@"; do
        oldifs="$IFS"; IFS=','
        for x in $g; do [ -n "$x" ] && queue+=("$x"); done
        IFS="$oldifs"
    done
    while [ "$i" -lt "${#queue[@]}" ]; do
        g="${queue[$i]}"; i=$((i + 1))
        [ -n "$g" ] || continue
        [ -n "${seen[$g]:-}" ] && continue
        [ -n "$(patch_rel "$eng" "$g")" ] || die "unknown $eng patch flag '$g'"
        deps=$(patch_deps "$eng" "$g")
        # Emit dependencies first: overlays must land before patches that
        # edit overlay files (e.g. flexresize needs the vmvga overlay).
        local ready=1 d
        oldifs="$IFS"; IFS=','
        for d in $deps; do
            [ -n "$d" ] || continue
            [ -n "${emitted[$d]:-}" ] || ready=0
            [ -n "${seen[$d]:-}" ] || queue+=("$d")
        done
        IFS="$oldifs"
        if [ "$ready" = 0 ]; then
            queue+=("$g")
            continue
        fi
        seen[$g]=1; emitted[$g]=1
        out+=("$g")
    done
    [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
}

# ---------------------------------------------------------------- sources

# Check out the upstreams.conf entry KEY under $VMM_SRC and print its path.
source_checkout() {
    local key="${1:-}" url lock dir want
    : "${VMM_SRC:?VMM_SRC is not set}"
    url=$(conf_get "$key" url)
    lock=$(conf_get "$key" lock)
    [ -n "$url" ] && [ -n "$lock" ] ||
        die "upstreams.conf [$key] needs both url and lock"
    dir="$VMM_SRC/$key"
    want="$lock+overlay"
    if [ -f "$dir/.vmm-ref" ] && [ "$(cat "$dir/.vmm-ref")" = "$want" ] &&
       [ -d "$dir/.git" ]; then
        printf '%s\n' "$dir"
        return 0
    fi
    [ "${VMM_OFFLINE:-0}" = 1 ] &&
        die "$key source missing at $dir (offline)"
    rm -rf "$dir"
    mkdir -p "$VMM_SRC"
    printf -- "-- fetch %s (%s)\n" "$key" "$lock" >&2
    git clone --quiet "$url" "$dir" || die "clone failed: $url"
    git -C "$dir" checkout --quiet "$lock" ||
        die "$key: no ref $lock (use --update)"
    printf '%s\n' "$want" > "$dir/.vmm-ref"
    printf '%s\n' "$dir"
}

# ---------------------------------------------------------------- patches

patch_already_applied() {
    local tree="$1" file="$2"
    # Both checks must run with the patched tree as cwd.  git apply cannot
    # read the context-style hunks used by several of our patches, so the
    # patch(1) reverse dry-run is the authoritative check for those.
    ( cd "$tree" && git apply --reverse --check "$file" ) >/dev/null 2>&1 && return 0
    ( cd "$tree" && sed '/^--- a\//,$!d' "$file" |
        patch -p1 -R --dry-run --forward ) >/dev/null 2>&1
}

patch_apply_file() {
    local tree="$1" file="$2"
    # git apply ignores the VMM_* metadata lines; patch(1) needs them removed.
    # Both must run with the QEMU tree as cwd.
    ( cd "$tree" && git apply --whitespace=nowarn "$file" ) 2>/dev/null ||
        ( cd "$tree" && sed '/^--- a\//,$!d' "$file" | patch -p1 --forward )
}

# Apply every patch flag in FLAGS (plus dependencies) to TREE.
patch_apply() {
    local eng="${1:-}" tree="${2:-}"; shift 2 || true
    local -a flags=()
    local g rel file skey src
    while IFS= read -r g; do
        [ -n "$g" ] && flags+=("$g")
    done < <(patch_resolve "$eng" "$@")
    [ "${#flags[@]}" -gt 0 ] || return 0
    local stamp="$tree/.vmm-patched" wanted
    wanted=$(for g in "${flags[@]}"; do
        rel=$(patch_rel "$eng" "$g")
        printf '%s %s\n' "$g" "$(md5sum "$ROOT/$rel" | cut -d" " -f1)"
    done | LC_ALL=C sort | md5sum | cut -d" " -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        note "$eng patches already applied"
        return 0
    fi
    for g in "${flags[@]}"; do
        rel=$(patch_rel "$eng" "$g")
        file="$ROOT/$rel"
        [ -f "$file" ] || die "$eng/$g: missing $rel"
        case "$file" in
            *.patch)
                if patch_already_applied "$tree" "$file"; then
                    note "$eng/$g already applied"
                else
                    patch_apply_file "$tree" "$file" ||
                        die "$eng/$g: failed to apply $rel"
                    note "applied $eng/$g"
                fi
                ;;
            *.sh)
                skey=$(header_field "$file" VMM_SOURCE)
                src=""
                if [ -n "$skey" ]; then
                    src=$(source_checkout "$skey")
                fi
                VMM_ENGINE="$eng" VMM_FLAG="$g" VMM_SRC="$tree" \
                VMM_BUILD="${VMM_BUILD:-}" VMM_SOURCE_DIR="$src" \
                    bash "$file" "$tree" || die "$eng/$g: script failed"
                note "applied $eng/$g"
                ;;
            *) die "$eng/$g: unknown patch file type: $rel" ;;
        esac
    done
    printf '%s\n' "$wanted" > "$stamp"
}

# Install files declared with VMM_INSTALL after a virt-manager build.
patch_install_extra() {
    local eng="${1:-}"; shift || true
    local -a flags=()
    local g rel file line src dest destroot
    destroot="${VMM_PREFIX:?}/share/virt-manager"
    local -A installed=()
    while IFS= read -r g; do
        [ -n "$g" ] && flags+=("$g")
    done < <(patch_resolve "$eng" "$@")
    for g in "${flags[@]}"; do
        rel=$(patch_rel "$eng" "$g")
        file="$ROOT/$rel"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            src="${line%%:*}"
            dest="${line#*:}"
            # Two patches can ship the same helper module.
            [ -n "${installed["$src|$dest"]:-}" ] && continue
            installed["$src|$dest"]=1
            [ -d "$destroot/$dest" ] ||
                die "missing install directory: $destroot/$dest"
            install -m 0644 "$(dirname "$file")/$src" "$destroot/$dest/" ||
                die "$eng/$g: cannot install $src into $dest"
            note "installed $src -> $dest"
        done < <(patch_list_field "$file" VMM_INSTALL)
    done
}

# ---------------------------------------------------------------- queries

list_engines() {
    printf 'qemu|qemu|qemu\n'
    printf 'virtmgr|virt-manager|vm\n'
    printf 'ovmf|ovmf|ovmf\n'
}

list_builds() {
    case "${1:-}" in
        qemu)
            printf 'compile|Compile from upstream|(Recommended) Builds a self-contained QEMU with the selected patches.|-\n'
            printf 'link|Link existing binary|Reuse a system QEMU; no patches, virgl profile or vmvga.|path\n'
            printf 'skip|Do not compile|Install no QEMU; the launcher falls back to PATH.|-\n'
            ;;
        virt-manager)
            printf 'compile|Compile from upstream|Build the fork with the selected UI patches.|-\n'
            printf 'link|Link existing binary|Reuse an installed virt-manager; no patches are applied.|path\n'
            printf 'skip|Do not compile|Install no virt-manager; use the host application instead.|-\n'
            ;;
        ovmf)
            printf 'pull|Pull pre-patched binaries|Use the silent images bundled with this repository.|-\n'
            printf 'compile|Compile from upstream|Build edk2 from the QEMU tarball; works without a QEMU build.|-\n'
            printf 'link|Link existing CODE + VARS|Symlink a CODE/VARS pair already installed on the host.|path2\n'
            printf 'skip|Do not install firmware|Leave firmware handling to the host or domain XML.|-\n'
            ;;
        *) die "unknown engine '${1:-}'" ;;
    esac
}

query() {
    local field="${1:-}" eng="${2:-}" list="${3:-}" g val rel
    local oldifs="$IFS"
    IFS=','
    for g in $list; do
        [ -n "$g" ] || continue
        case "$field" in
            path)
                rel=$(patch_rel "$eng" "$g")
                [ -n "$rel" ] || die "unknown $eng patch flag '$g'"
                printf '%s\n' "$rel"
                ;;
            name|desc|deps|tick)
                val=$(unit_row patch "$eng" "$g" "$field")
                [ -n "$val" ] || die "unknown $eng patch flag '$g'"
                printf '%s\n' "$val"
                ;;
            *) die "unknown query field '$field'" ;;
        esac
    done
    IFS="$oldifs"
}

# ---------------------------------------------------------------- builds

sanitize_cflags() {
    VMM_CFLAGS="${VMM_CFLAGS:-}"
    VMM_CXXFLAGS="${VMM_CXXFLAGS:-}"
    VMM_CFLAGS=$(printf '%s' "$VMM_CFLAGS" |
        sed 's/-fno-diagnostics-show-caret//g; s/-fno-diagnostics-show-source-lines//g; s/-fno-diagnostics-show-event-links//g')
    VMM_CXXFLAGS=$(printf '%s' "$VMM_CXXFLAGS" |
        sed 's/-fno-diagnostics-show-caret//g; s/-fno-diagnostics-show-source-lines//g; s/-fno-diagnostics-show-event-links//g')
}

do_dxvk() {
    local src lock build_dir out url ver
    : "${VMM_SRC:?VMM_SRC is not set}"
    src="${VMM_DXVK_SRC:-$VMM_SRC/dxvk}"
    lock="${VMM_DXVK_LOCK:-$(conf_get dxvk-native lock)}"
    build_dir="${VMM_BUILD:?VMM_BUILD is not set}"
    [ -n "$lock" ] || die "dxvk-native lock missing (use --update)"
    ver="${lock#v}"
    # Prefer the vendored prebuilt tarball: the locally built dxvk-native
    # has a different ABI/build and wedges vmvga's D3D9 path at boot.
    local vendor="$ROOT/share/vendor/dxvk-native-$ver.tar.gz"
    out="${VMM_DXVK_TARBALL:-${vendor}}"
    [ -f "$out" ] || out="$build_dir/downloads/dxvk-native-$ver.tar.gz"
    url="${VMM_DXVK_URL:-$(conf_get dxvk-native url)}"
    [ -n "$url" ] || die "no dxvk-native URL (set VMM_DXVK_URL or edit upstreams.conf)"

    if [ -n "${VMM_DXVK_TARBALL:-}" ]; then
        [ -f "$VMM_DXVK_TARBALL" ] ||
            die "no such tarball: $VMM_DXVK_TARBALL"
        printf '%s\n' "$VMM_DXVK_TARBALL"
        return 0
    fi
    if [ -f "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    if [ ! -d "$src/.git" ]; then
        [ "${VMM_OFFLINE:-0}" = 1 ] && die "dxvk source missing at $src (offline)"
        note "clone dxvk-native $lock"
        rm -rf "$src"
        mkdir -p "$(dirname "$src")"
        git clone --quiet --depth 1 --branch "$lock" \
            --recurse-submodules --shallow-submodules \
            "$url" "$src" || die "dxvk clone failed"
    fi
    note "build dxvk-native $lock"
    rm -rf "$build_dir/dxvk-out"
    ( cd "$src" && ./package-native.sh "$ver" "$build_dir/dxvk-out" --64-only ) ||
        die "dxvk-native build failed"
    mkdir -p "$(dirname "$out")"
    cp "$build_dir/dxvk-out/dxvk-native-$ver.tar.gz" "$out" ||
        die "dxvk package missing"
    rm -rf "$build_dir/dxvk-out"
    printf '%s\n' "$out"
}

do_qemu() {
    local patches="${1:-}" qsrc virgl dxvk ver
    : "${VMM_PREFIX:?VMM_PREFIX is not set}"
    : "${VMM_SRC:?VMM_SRC is not set}"
    : "${VMM_BUILD:?VMM_BUILD is not set}"
    qsrc="${VMM_QEMU_SRC:-$VMM_SRC/qemu-$(conf_get qemu lock)}"
    virgl="${VMM_VIRGL_SRC:-$VMM_SRC/virglrenderer}"
    ver="$(conf_get dxvk-native lock)"; ver="${ver#v}"
    local vendor="$ROOT/share/vendor/dxvk-native-$ver.tar.gz"
    dxvk="${VMM_DXVK_TARBALL:-${vendor}}"
    [ -f "$dxvk" ] || dxvk="$VMM_BUILD/downloads/dxvk-native-$ver.tar.gz"
    VMM_PREFIX="${VMM_PREFIX%/}"
    [ -d "$qsrc" ] || die "missing QEMU source: $qsrc"
    [ -d "$virgl" ] || die "missing virglrenderer source: $virgl"
    [ -f "$dxvk" ] || die "missing dxvk-native tarball: $dxvk (run: build.sh dxvk)"

    sanitize_cflags
    local jobs="${VMM_JOBS:-$(nproc 2>/dev/null || echo 4)}"
    local vprefix="$VMM_BUILD/virgl-prefix"
    local vbuild="$VMM_BUILD/virgl-build"
    local qbuild="$VMM_BUILD/qemu-build"
    local qreal vreal
    qreal="$(cd "$qsrc" && pwd)"
    vreal="$(cd "$virgl" && pwd)"

    mkdir -p "$VMM_BUILD" "$vprefix" "$VMM_PREFIX"

    # Patch before configure so the tree is complete when it is probed.
    patch_apply qemu "$qsrc" "$patches"

    note "virglrenderer"
    if [ ! -f "$vprefix/lib/x86_64-linux-gnu/pkgconfig/virglrenderer.pc" ] ||
       [ "$(cat "$vprefix/.vmm-source" 2>/dev/null)" != "$vreal" ] ||
       [ "$(cat "$vprefix/.vmm-prefix" 2>/dev/null)" != "$vprefix" ]; then
        rm -rf "$vbuild" "$vprefix"
        mkdir -p "$vprefix"
        CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
        meson setup "$vbuild" "$virgl" \
            --prefix="$vprefix" --buildtype=release -Dvenus=true
        CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
        ninja -C "$vbuild" -j "$jobs"
        CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
        ninja -C "$vbuild" install
        printf '%s\n' "$vreal" > "$vprefix/.vmm-source"
        printf '%s\n' "$vprefix" > "$vprefix/.vmm-prefix"
    fi
    export PKG_CONFIG_PATH="$vprefix/lib/x86_64-linux-gnu/pkgconfig:$vprefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LDFLAGS="-L$vprefix/lib/x86_64-linux-gnu -L$vprefix/lib ${LDFLAGS:-}"
    export CPPFLAGS="-I$vprefix/include ${CPPFLAGS:-}"

    note "qemu configure (-Dsdl=disabled)"
    if [ -f "$qbuild/build.ninja" ] &&
       { [ "$(cat "$qbuild/.vmm-prefix" 2>/dev/null)" != "$VMM_PREFIX" ] ||
         [ "$(cat "$qbuild/.vmm-source" 2>/dev/null)" != "$qreal" ]; }; then
        note "prefix or source moved; reconfiguring qemu build"
        rm -rf "$qbuild"
    fi
    if [ ! -f "$qbuild/build.ninja" ]; then
        mkdir -p "$qbuild"
        ( cd "$qbuild" && CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
            "$qsrc/configure" \
            --prefix="$VMM_PREFIX" \
            --target-list=x86_64-softmmu \
            --enable-gtk --enable-opengl --enable-virglrenderer --enable-spice \
            --disable-sdl --disable-docs --disable-werror )
        printf '%s\n' "$VMM_PREFIX" > "$qbuild/.vmm-prefix"
        printf '%s\n' "$qreal" > "$qbuild/.vmm-source"
    fi
    CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
    ninja -C "$qbuild" -j "$jobs"
    CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
    ninja -C "$qbuild" install

    note "dxvk-native"
    local stage="$VMM_BUILD/dxvk"
    # Always restage: a previous build may have left a different tarball's
    # libraries here (local GCC build vs the vendored prebuilt one).
    rm -rf "$stage"
    mkdir -p "$stage"
    vmm_extract_tar "$dxvk" "$stage" 0
    note "runtime libs"
    mkdir -p "$VMM_PREFIX/lib" "$VMM_PREFIX/libexec"
    cp -a "$vprefix"/lib/x86_64-linux-gnu/libvirglrenderer.so* "$VMM_PREFIX/lib/"
    cp -a "$vprefix"/libexec/. "$VMM_PREFIX/libexec/"
    cp -a "$stage"/usr/lib/libdxvk_*.so* "$VMM_PREFIX/lib/" 2>/dev/null ||
        cp -a "$stage"/usr/lib/libdxvk_*.so* "$VMM_PREFIX/lib64/"

    note "rpath"
    local bin
    for bin in "$VMM_PREFIX/bin/qemu-system-x86_64" \
               "$VMM_PREFIX/libexec/virgl_render_server"; do
        [ -f "$bin" ] || continue
        patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../lib/x86_64-linux-gnu' "$bin"
    done

    note "checks"
    "$VMM_PREFIX/bin/qemu-system-x86_64" -version
    "$VMM_PREFIX/bin/qemu-system-x86_64" -L "$VMM_PREFIX/share/qemu" \
        -device virtio-vga-gl,help | grep -q venus

    note "profile installed at $VMM_PREFIX"
}

do_vm() {
    local patches="${1:-}" src build_dir
    : "${VMM_PREFIX:?VMM_PREFIX is not set}"
    : "${VMM_SRC:?VMM_SRC is not set}"
    : "${VMM_BUILD:?VMM_BUILD is not set}"
    src="${VMM_VM_SRC:-$VMM_SRC/virt-manager-$(conf_get virt-manager lock)}"
    build_dir="$VMM_BUILD/vm-build"
    local jobs="${VMM_JOBS:-$(nproc 2>/dev/null || echo 4)}"
    [ -d "$src" ] || die "missing virt-manager source: $src"

    patch_apply virt-manager "$src" "$patches"

    if [ -f "$build_dir/build.ninja" ]; then
        if ! meson setup --reconfigure "$build_dir" "$src" \
                --prefix="$VMM_PREFIX" --buildtype=release >/dev/null; then
            note "stale virt-manager build dir; recreating"
            rm -rf "$build_dir"
        fi
    fi
    if [ ! -f "$build_dir/build.ninja" ]; then
        meson setup "$build_dir" "$src" \
            --prefix="$VMM_PREFIX" --buildtype=release ||
            die "meson setup failed"
    fi

    CFLAGS="${VMM_CFLAGS:-}" CXXFLAGS="${VMM_CXXFLAGS:-}" \
        ninja -C "$build_dir" -j "$jobs" || die "ninja build failed"
    CFLAGS="${VMM_CFLAGS:-}" CXXFLAGS="${VMM_CXXFLAGS:-}" \
        ninja -C "$build_dir" install || die "ninja install failed"

    patch_install_extra virt-manager "$patches"
    note "virt-manager installed to $VMM_PREFIX"
}

do_ovmf() {
    local patches="${1:-}" src out jobs
    : "${VMM_SRC:?VMM_SRC is not set}"
    : "${VMM_BUILD:?VMM_BUILD is not set}"
    src="${VMM_EDK2_SRC:-$VMM_SRC/qemu-$(conf_get qemu lock)/roms/edk2}"
    out="${VMM_OVMF_OUT:-$VMM_BUILD/ovmf}"
    jobs="${VMM_JOBS:-$(nproc 2>/dev/null || echo 4)}"
    [ -f "$src/OvmfPkg/OvmfPkgX64.dsc" ] ||
        die "not an edk2 tree: $src"
    [ -f "$src/MdeModulePkg/Logo/Logo.bmp" ] ||
        die "$src is missing MdeModulePkg/Logo/Logo.bmp"
    mkdir -p "$out"
    out="$(cd "$out" && pwd)"

    sanitize_cflags
    local tool
    for tool in gcc make python3 nasm; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done

    patch_apply ovmf "$src" "$patches"

    note "BaseTools"
    # GCC 15+ defaults to C23; the bundled Pccts tools need C11.  A stamp
    # stops an older, unpatched BaseTools from being reused.
    local bt="$src/BaseTools/Source/C"
    local stamp="$src/BaseTools/.vmm-gcc-compat"
    if [ ! -x "$bt/bin/GenFw" ] || [ ! -f "$stamp" ]; then
        local mf
        for mf in VfrCompile/Pccts/antlr/makefile VfrCompile/Pccts/dlg/makefile; do
            [ -f "$bt/$mf" ] || continue
            grep -q -- '-std=gnu11' "$bt/$mf" ||
                sed -i 's/^[[:space:]]*CFLAGS=/& -std=gnu11 /' "$bt/$mf"
        done
        EXTRA_OPTFLAGS="${EXTRA_OPTFLAGS:-} -Wno-error ${VMM_CFLAGS}"
        export EXTRA_OPTFLAGS
        make -C "$bt" clean >/dev/null 2>&1 || true
        CFLAGS="$VMM_CFLAGS" CXXFLAGS="$VMM_CXXFLAGS" \
            make -C "$bt" -j "$jobs"
        : > "$stamp"
    fi

    cd "$src"
    export WORKSPACE="$src"
    export EDK_TOOLS_PATH="$src/BaseTools"
    export PYTHON_COMMAND=python3
    set +u
    # shellcheck disable=SC1091
    source ./edksetup.sh BaseTools >/dev/null
    set -u
    local tools_def="$src/Conf/tools_def.txt"
    if [ ! -f "$tools_def" ]; then
        mkdir -p "$src/Conf"
        cp "$src/BaseTools/Conf/tools_def.template" "$tools_def"
    fi
    if ! grep -qE '^[[:space:]]*(DEBUG|RELEASE|NOOPT)_GCC5_[A-Z0-9_]*_CC_FLAGS *=.*-std=gnu17' "$tools_def"; then
        sed -i '/^[[:space:]]*\(DEBUG\|RELEASE\|NOOPT\)_GCC5_[A-Z0-9_]*_CC_FLAGS *=/ s/$/ -std=gnu17 -Wno-error/' "$tools_def"
    fi
    local build="$src/BaseTools/BinWrappers/PosixLike/build"
    local fv="$src/Build/OvmfX64/RELEASE_GCC5/FV"

    build_one() {
        local name="$1" code="$2" vars="$3"; shift 3
        note "$name"
        rm -rf "$src/Build/OvmfX64"
        ( cd "$src" && "$build" -a X64 -t GCC5 -b RELEASE \
            -p OvmfPkg/OvmfPkgX64.dsc -D FD_SIZE_4MB "$@" -n "$jobs" )
        mkdir -p "$out"
        cp "$fv/OVMF_CODE.fd" "$out/$code"
        cp "$fv/OVMF_VARS.fd" "$out/$vars"
    }

    build_one "plain" "OVMF_CODE_4M.fd" "OVMF_VARS_4M.fd"
    build_one "secure boot" "OVMF_CODE_4M.secboot.fd" "OVMF_VARS_4M.ms.fd" \
        -D SECURE_BOOT_ENABLE -D SMM_REQUIRE

    note "checks"
    ln -sfn OVMF_CODE_4M.secboot.fd "$out/OVMF_CODE_4M.ms.fd"
    sha256sum "$out"/OVMF_CODE_4M.fd "$out"/OVMF_CODE_4M.secboot.fd \
        "$out"/OVMF_VARS_4M.fd "$out"/OVMF_VARS_4M.ms.fd

    cat <<EOF
-- images in $out
   Install by copying them to share/firmware/OVMF and rerunning install.sh,
   or pass OUT_DIR=share/firmware/OVMF explicitly.
   Expected silence: a normal boot stays black; with no bootable device the
   firmware still prints "No bootable option or device was found."
EOF
}

build_engine() {
    local eng="${1:-}" patches="${2:-}"
    case "$eng" in
        qemu)         do_qemu "$patches" ;;
        virt-manager) do_vm "$patches" ;;
        ovmf)         do_ovmf "$patches" ;;
        *) die "unknown engine '$eng'" ;;
    esac
}


case "${1:-}" in
    --list-engines) list_engines ;;
    --list)         unit_list ;;
    --resolve)      patch_resolve "${2:-}" "${3:-}" ;;
    --list-builds)  list_builds "${2:-}" ;;
    --list-patches) patch_scan "${2:-}" ;;
    --query)        query "${2:-}" "${3:-}" "${4:-}" ;;
    build)
        eng="${2:-}"
        shift 2 || true
        patches=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --patch=*) patches="${1#*=}" ;;
                *) die "unknown argument: $1" ;;
            esac
            shift
        done
        build_engine "$eng" "$patches"
        ;;
    dxvk) do_dxvk ;;
    ""|-h|--help) build_usage ;;
    *) die "unknown command: $1" ;;
esac
