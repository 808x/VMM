#!/bin/bash
# VMM_PAGE: host
# VMM_FLAG: write-xml
# VMM_NAME: Write domain XML examples
# VMM_DESC: Render cachyos.xml and windows.xml into prefix/share/examples.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

root=$(vmm_root)
prefix=$(vmm_prefix)
render="$prefix/bin/vmm-render"

# Standalone calls may not have a prefix yet; seed it from the tree copies.
if [ -d "$root/share/examples" ]; then
    mkdir -p "$prefix/share/examples"
    cp -f "$root/share/examples/"*.xml.in "$prefix/share/examples/" \
        2>/dev/null || true
    if [ -f "$root/share/examples/profile.conf.in" ]; then
        cp -f "$root/share/examples/profile.conf.in" \
            "$prefix/share/examples/profile.conf.in"
    fi
fi

if [ ! -x "$render" ] && [ -f "$root/share/bin/vmm-render" ]; then
    mkdir -p "$prefix/bin"
    install -m 0755 "$root/share/bin/vmm-render" "$render" ||
        die "cannot install vmm-render"
fi
[ -x "$render" ] || die "vmm-render missing; cannot emit domain examples"

if [ ! -f "$prefix/profile.conf" ] &&
   [ -f "$prefix/share/examples/profile.conf.in" ]; then
    install -m 0644 "$prefix/share/examples/profile.conf.in" \
        "$prefix/profile.conf" || warn "cannot create $prefix/profile.conf"
fi
[ -f "$prefix/profile.conf" ] ||
    die "no profile at $prefix/profile.conf; run the installer first"

note "rendering domain examples from $prefix/profile.conf"
"$render" --profile "$prefix/profile.conf" --prefix "$prefix" \
    --write "$prefix/share/examples" ||
    warn "some domain examples failed to render"

grep -l '@[A-Z_][A-Z0-9_]*@' "$prefix/share/examples"/*.xml 2>/dev/null |
    while read -r tmpl; do warn "unsubstituted placeholders in $tmpl"; done
note "domain examples are under $prefix/share/examples; launch.sh defines them"
