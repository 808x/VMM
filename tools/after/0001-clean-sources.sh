#!/bin/bash
# VMM_PAGE: after
# VMM_FLAG: clean-sources
# VMM_NAME: Remove sources and downloads
# VMM_VAR: clean_sources
# VMM_TICK: yes
# VMM_PHASE: final
# VMM_DESC: Delete the source cache and build outputs; safe to rebuild later.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

found=0
if [ -n "${VMM_SRC:-}" ] && [ -d "$VMM_SRC" ]; then
    note "removing source cache: $VMM_SRC"
    rm -rf "$VMM_SRC" || warn "could not remove $VMM_SRC"
    found=1
fi
if [ -n "${VMM_BUILD:-}" ] && [ -d "$VMM_BUILD" ]; then
    note "removing build outputs and downloads: $VMM_BUILD"
    rm -rf "$VMM_BUILD" || warn "could not remove $VMM_BUILD"
    found=1
fi
if [ "$found" = 0 ]; then
    note "no sources or build outputs to remove"
fi
exit 0
