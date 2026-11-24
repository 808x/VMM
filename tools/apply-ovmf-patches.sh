#!/bin/bash
# Apply the silent-boot changes to an edk2/OVMF source tree.
#
# usage: tools/apply-ovmf-patches.sh EDK2_SRC [GROUP...]
#
# Groups: logo (blank splash), bds (failure-only BdsDxe messages).
# With no groups both are applied; pass "none" to apply nothing.
#
# Idempotent: safe to run on an already patched tree.  The status-code
# patch keeps the upstream CRLF line endings; the logo is blanked in place.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: apply-ovmf-patches.sh EDK2_SRC [GROUP...]}"
shift
P="$DIR/patches/ovmf"
STATUS="$TREE/OvmfPkg/Library/PlatformBmPrintScLib/StatusCodeHandler.c"
LOGO="$TREE/MdeModulePkg/Logo/Logo.bmp"

groups=("$@")
if [ ${#groups[@]} -eq 0 ]; then
    groups=(logo bds)
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

if has bds; then
    [ -f "$STATUS" ] ||
        { echo "apply-ovmf-patches: $STATUS not found" >&2; exit 1; }
    if grep -q 'Value == mLoadPrep ? "loading"' "$STATUS"; then
        patch -p1 -d "$TREE" --forward < "$P/0001-failure-only.patch"
    else
        echo "ovmf status patch already applied"
    fi
fi

if has logo; then
    [ -f "$LOGO" ] ||
        { echo "apply-ovmf-patches: $LOGO not found" >&2; exit 1; }
    size=$(stat -c %s "$LOGO")
    dib=$(od -An -tu4 -j14 -N4 "$LOGO" | tr -d '[:space:]')
    case "$dib" in
        ''|*[!0-9]*) echo "apply-ovmf-patches: $LOGO has no BMP header" >&2
                     exit 1 ;;
    esac
    start=$((14 + dib))
    if [ "$start" -lt 54 ] || [ "$start" -ge "$size" ]; then
        echo "apply-ovmf-patches: $LOGO has an invalid pixel offset" >&2
        exit 1
    fi
    # Zero the palette and pixel data while keeping the BMP headers.  Every
    # index then maps to black, so the TianoCore splash is blank regardless
    # of the upstream image or palette.
    truncate -s "$start" "$LOGO"
    truncate -s "$size" "$LOGO"
    echo "ovmf logo blanked in place"
fi
