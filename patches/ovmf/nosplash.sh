#!/bin/bash
# Blank the OVMF logo BMP in place.
#
# usage: patches/ovmf/nosplash.patch EDK2_SRC
#
# Truncates the palette and pixel data while keeping the BMP headers, so
# every index maps to black and the TianoCore splash stays blank regardless
# of the upstream image or palette.
#
# VMM_FLAG: nosplash
# VMM_NAME: Blank TianoCore splash
# VMM_DESC: Replace the logo with a blank image.
# VMM_DEPS: -
# VMM_TICK: yes
set -eu
TREE="${1:?usage: nosplash.patch EDK2_SRC}"
LOGO="$TREE/MdeModulePkg/Logo/Logo.bmp"
[ -f "$LOGO" ] || { echo "nosplash.patch: $LOGO not found" >&2; exit 1; }
size=$(stat -c %s "$LOGO")
dib=$(od -An -tu4 -j14 -N4 "$LOGO" | tr -d '[:space:]')
case "$dib" in
    ''|*[!0-9]*) echo "nosplash.patch: $LOGO has no BMP header" >&2
                 exit 1 ;;
esac
start=$((14 + dib))
[ "$start" -lt 54 ] || [ "$start" -ge "$size" ] && {
    echo "nosplash.patch: $LOGO has an invalid pixel offset" >&2
    exit 1
}
truncate -s "$start" "$LOGO"
truncate -s "$size" "$LOGO"
echo "ovmf logo blanked in place"
