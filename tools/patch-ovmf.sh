#!/bin/bash
# Apply silent-boot changes to an edk2/OVMF source tree.
#
# usage: tools/patch-ovmf.sh EDK2_SRC [FLAG...]
#
# Flags: nosplash, nomessage
# With no flags all patches flagged VMM_TICK=yes are applied;
# pass "none" to apply nothing.
# Each patches/ovmf/*.patch or *.sh file carries VMM_FLAG/VMM_NAME/
# VMM_DESC/VMM_DEPS metadata comments at the top.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$DIR/patches/ovmf"
TREE="${1:?usage: patch-ovmf.sh EDK2_SRC [FLAG...]}"
shift

# Discover available patches by scanning for *.patch and *.sh files
# and reading their VMM_* metadata comments.
declare -A PFLAG PNAME PDESC PDEPS PFILE PTICK
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

STATUS="$TREE/OvmfPkg/Library/PlatformBmPrintScLib/StatusCodeHandler.c"
LOGO="$TREE/MdeModulePkg/Logo/Logo.bmp"

if has nomessage; then
    [ -f "$P/nomessage.patch" ] ||
        { echo "patch-ovmf: missing patches/ovmf/nomessage.patch" >&2; exit 1; }
    if grep -q 'Value == mLoadPrep ? "loading"' "$STATUS"; then
        patch -p1 -d "$TREE" --forward < "$P/nomessage.patch"
    else
        echo "ovmf status patch already applied"
    fi
fi

if has nosplash; then
    [ -x "$P/nosplash.sh" ] ||
        { echo "patch-ovmf: missing patches/ovmf/nosplash.sh" >&2; exit 1; }
    "$P/nosplash.sh" "$TREE"
fi
