#!/bin/bash
# Apply virt-manager patches to a source tree.
#
# usage: tools/patch-vmgr.sh TREE [FLAG...]
#
# Flags: reparent, pcimenu, usbmenu, usbcache
# With no flags all present are applied; pass "none" to apply nothing.
# Each patches/virt-manager/*.patch file carries VMM_FLAG/VMM_NAME/
# VMM_DESC/VMM_DEPS metadata comments at the top.
# New modules live in patches/virt-manager/modules and are copied.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$DIR/patches/virt-manager"
MODULES="$PATCH_DIR/modules"
TREE="${1:?usage: patch-vmgr.sh TREE [FLAG...]}"
shift

# Discover available patches by scanning for *.patch files and reading
# their VMM_* metadata comments.
declare -A PFLAG PNAME PDESC PDEPS PFILE PTICK
for f in "$PATCH_DIR"/*.patch; do
    [ -e "$f" ] || continue
    flag=""; name=""; desc=""; deps="-"; tick="no"
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
    [ -n "${PFLAG[$g]:-}" ] || { echo "patch-vmgr: unknown flag '$g'" >&2; exit 1; }
    resolved+=("$g")
    if [ "${PDEPS[$g]:--}" != "-" ]; then
        oldifs="$IFS"; IFS=','
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
    f="${PFILE[$g]}"
    [ -f "$f" ] || { echo "patch-vmgr: missing patch for $g: $f" >&2; exit 1; }
    case "$g" in
        pcimenu)   cp "$MODULES/pci_redirect.py"   "$TREE/virtManager/" ;;
        usbcache)  cp "$MODULES/usb_redirect.py"   "$TREE/virtManager/" ;;
        usbmenu)   cp "$MODULES/usb_redirect.py"   "$TREE/virtManager/" ;;
        reparent)  cp "$MODULES/gtk_embed.py"      "$TREE/virtManager/details/" ;;
    esac
    if grep -qx "$g" "$TREE/.vmm-groups" 2>/dev/null; then
        echo "$g already applied"
        continue
    fi
    ( cd "$TREE" && git apply --whitespace=nowarn "$f" )
    printf '%s\n' "$g" >> "$TREE/.vmm-groups"
    echo "applied $g"
done
