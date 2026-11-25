#!/bin/bash
# VMM_PAGE: after
# VMM_FLAG: clean-deps
# VMM_NAME: Remove build dependencies
# VMM_VAR: clean_deps
# VMM_PHASE: final
# VMM_DESC: Runtime dependencies are always kept; only build-only packages are removed.
# VMM_SUDO: yes
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

: "${VMM_STATE:?VMM_STATE is not set}"
deps_state="$VMM_STATE/new-deps"
runtime_state="$VMM_STATE/new-runtime-deps"

installed_new_deps() {
    local id pkg
    id=$(distro_id)
    [ -f "$deps_state" ] || return 0
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
    done < "$deps_state"
}

[ -f "$deps_state" ] || {
    note "no build packages recorded from the deps tool"
    exit 0
}

id=$(distro_id)
rc=0
pkgs=()
declare -A keep=()

# Runtime dependencies are never removed; they are needed to run the prefix
# long after the build, so build packages that doubled as runtime deps stay.
if [ -f "$runtime_state" ]; then
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && keep["$pkg"]=1
    done < "$runtime_state"
fi
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    [ -n "${keep[$pkg]:-}" ] && continue
    pkgs+=("$pkg")
done < <(installed_new_deps)

if [ "${#pkgs[@]}" -eq 0 ]; then
    note "no build-only packages to remove (runtime dependencies kept)"
    rm -f "$deps_state"
    exit 0
fi

note "removing ${#pkgs[@]} build package(s) added by the deps tool"
note "runtime dependencies are kept"
case "$id" in
    *arch*)                as_root pacman -Rns --noconfirm "${pkgs[@]}" || rc=$? ;;
    *debian*|*ubuntu*)     as_root apt-get remove --purge -y "${pkgs[@]}" || rc=$? ;;
    *fedora*|*rhel*|*centos*) as_root dnf remove -y "${pkgs[@]}" || rc=$? ;;
    *)
        warn "unknown distro; remove manually: ${pkgs[*]}"
        exit 1
        ;;
esac
if [ "$rc" = 0 ]; then
    rm -f "$deps_state"
else
    warn "package cleanup incomplete; $deps_state kept for a retry"
fi
exit "$rc"
