#!/bin/bash
# Apply QEMU patches and overlays to a source tree.
#
# usage: tools/patch-qemu.sh TREE [VMVGA_SRC] [FLAG...]
#
# Flags: vmvga, spicevirgl, gtkegl, flexresize
# With no flags all present are applied; pass "none" to apply nothing.
# Each patches/qemu/*.patch or *.sh file carries VMM_FLAG/VMM_NAME/
# VMM_DESC/VMM_DEPS metadata comments at the top.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$DIR/patches/qemu"
TREE="${1:?usage: patch-qemu.sh TREE [VMVGA_SRC] [FLAG...]}"
shift
VMVGA_SRC="${1:-$DIR/src/qemu-vmvga}"
case "$VMVGA_SRC" in
    -*|"") VMVGA_SRC="$DIR/src/qemu-vmvga" ;;
    *) shift ;;
esac

# Discover available patches by scanning the directory for .patch/.sh
# files and reading their VMM_* metadata comments.
declare -A PFLAG PNAME PDESC PDEPS PTYPE PFILE PTICK
for f in "$PATCH_DIR"/*.patch "$PATCH_DIR"/*.sh; do
    [ -e "$f" ] || continue
    flag=""; name=""; desc=""; deps="-"; ftype="patch"; tick="no"
    case "$f" in *.sh) ftype="script" ;; esac
    while IFS= read -r line; do
        case "$line" in
            "# VMM_FLAG:"*) flag="${line#*VMM_FLAG:}"; flag="${flag# }" ;;
            "# VMM_NAME:"*) name="${line#*VMM_NAME:}"; name="${name# }" ;;
            "# VMM_DESC:"*) desc="${line#*VMM_DESC:}"; desc="${desc# }" ;;
            "# VMM_DEPS:"*) deps="${line#*VMM_DEPS:}"; deps="${deps# }" ;;
            "# VMM_TICK:"*) tick="${line#*VMM_TICK:}"; tick="${tick# }" ;;
        esac
    done < "$f"
    [ -n "$flag" ] || continue
    PFLAG[$flag]=1
    PNAME[$flag]="$name"
    PDESC[$flag]="$desc"
    PDEPS[$flag]="$deps"
    PTYPE[$flag]="$ftype"
    PTICK[$flag]="$tick"
    PFILE[$flag]="$f"
done

groups=("$@")
if [ ${#groups[@]} -eq 0 ]; then
    # Auto-select patches flagged VMM_TICK=yes
    for g in "${!PFLAG[@]}"; do
        [ "${PTICK[$g]}" = "yes" ] && groups+=("$g")
    done
fi

has() {
    local g
    for g in "${groups[@]}"; do
        case "$g" in
            no|none|-) return 1 ;;
        esac
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

# Resolve DEPS: auto-enable any listed dependency flags.
resolved=()
for g in "${groups[@]}"; do
    [ -n "${PFLAG[$g]:-}" ] || { echo "patch-qemu: unknown flag '$g'" >&2; exit 1; }
    resolved+=("$g")
    if [ "${PDEPS[$g]:--}" != "-" ]; then
        oldifs="$IFS"
        IFS=','
        for d in ${PDEPS[$g]}; do
            [ -n "$d" ] || continue
            case " ${resolved[*]} " in *" $d "*) ;; esac
            resolved+=("$d")
        done
        IFS="$oldifs"
    fi
done

# Deduplicate while preserving order.
uniq=()
for g in "${resolved[@]}"; do
    case " ${uniq[*]} " in *" $g "*) ;; *) uniq+=("$g") ;; esac
done
groups=("${uniq[@]}")

for g in "${groups[@]}"; do
    case "${PTYPE[$g]}" in
        script)
            f="${PFILE[$g]}"
            [ -x "$f" ] || { echo "patch-qemu: not executable: $f" >&2; exit 1; }
            "$f" "$TREE" "$VMVGA_SRC"
            ;;
        patch)
            f="${PFILE[$g]}"
            [ -f "$f" ] || { echo "patch-qemu: missing patch for $g: $f" >&2; exit 1; }
            if ( cd "$TREE" && git apply --reverse --check "$f" ) >/dev/null 2>&1; then
                echo "qemu/$g already applied"
            else
                ( cd "$TREE" && git apply --whitespace=nowarn "$f" )
                echo "applied qemu/$g"
            fi
            ;;
    esac
done
