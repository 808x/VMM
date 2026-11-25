#!/bin/bash
# Helpers shared by the tool scripts under tools/<page>/.
# Sourced, never executed.  The caller exports:
#
#   VMM_ROOT    program tree (install.sh's DIR)
#   VMM_PREFIX  install prefix
#   VMM_SRC     source cache
#   VMM_BUILD   build/download root
#   VMM_STATE   state directory
#
# Tool scripts are plain programs: no TUI, no colours, no prompts.  Anything
# that must be root is run through the installer, which is why the record
# carries SUDO.

# Logging is shared but not rigid: install.sh sets the c_* colours before it
# renders the TUI, while tool scripts and build.sh leave them unset and get
# plain output.  One implementation, two presentations.
note() { printf '%s--%s %s\n' "${c_bold:-}${c_cyan:-}" "${c_reset:-}" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "${c_yellow:-}" "${c_reset:-}" "$*" >&2; }
die() { printf '%sERROR:%s %s\n' "${c_red:-}" "${c_reset:-}" "$*" >&2; exit 1; }
section() {
    printf '\n%s==>%s %s%s%s\n' \
        "${c_bold:-}${c_cyan:-}" "${c_reset:-}" "${c_bold:-}" "$*" "${c_reset:-}"
}

header_field() {
    local file="$1" key="$2" line val
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            "# $key:"*) val="${line#*"$key":}"; printf '%s\n' "${val# }"; return 0 ;;
            "#"*|"") ;;
            *) return 0 ;;
        esac
    done < "$file"
    return 0
}

# Read a key from a section of tools/upstreams.conf.  Both the installer and
# tools/build.sh use this, so the parser lives here instead of twice.
conf_get() {
    awk -v s="[$1]" -v k="$2" '
        $0 == s { in_s = 1; next }
        /^\[/ { in_s = 0 }
        in_s && $1 == k {
            sub(/^[^=]*=[ \t]*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit
        }' "$CONF"
}

vmm_root() {
    : "${VMM_ROOT:?VMM_ROOT is not set}"
    printf '%s' "$VMM_ROOT"
}

vmm_prefix() {
    : "${VMM_PREFIX:?VMM_PREFIX is not set}"
    printf '%s' "$VMM_PREFIX"
}

# "id like" from os-release; empty when unknown.
distro_id() { (. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}"); }

# Tool scripts are normally already elevated by the installer, but stay
# usable when run directly.
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

install_usage() {
    local page flag desc
    record_load
    cat <<EOF
usage: ./install.sh [actions]

  With no component flags on a terminal, opens the build menu.  Missing
  choices are asked there; fully specified flags run unattended.

 Components
   --qemu:bin=compile|skip|link:PATH     QEMU binary source
   --qemu:patch=LIST                    QEMU patch groups (empty = none)
   --ovmf:bin=pull|compile|link|skip    firmware source
   --ovmf:code=PATH --ovmf:vars=PATH    firmware files to link
   --ovmf:patch=LIST                    OVMF patch groups (empty = none)
   --virtmgr:bin=compile|skip|link:PATH virt-manager binary source
   --virtmgr:patch=LIST                 virt-manager patch groups

 After the build
   --tool=LIST                    one or more, comma separated:
EOF
    for page in "${PAGE_ORDER[@]}"; do
        [ "${PAGE_KIND[$page]:-}" = tool ] || continue
        for flag in ${PAGE_UNITS[$page]:-}; do
            [ "$(u_kind "$page" "$flag")" = tool ] || continue
            desc=${U_DESC["$page|$flag"]}
            printf '                                   %-14s %s\n' "$flag" "$desc"
        done
    done
    cat <<EOF

 Other
   --update                       resolve latest upstreams and rewrite the lock
   --list-patches                 list discovered patches
   --prefix=DIR                   install prefix (default: ./prefix)
   --jobs=N                       parallel build jobs (default: nproc)
   --dxvk-tarball=FILE            use this dxvk-native tarball instead of building
   --dry-run                      resolve and report, change nothing
   -h, --help

 Patch values are the flag names shown in the TUI; run --list-patches to
 list them.
EOF
}

build_usage() {
    cat <<EOF
usage: tools/build.sh COMMAND

  --list-engines                 CLI_PREFIX|ENGINE|VAR
  --list                         KIND|PAGE|FLAG|NAME|DESC|DEPS|PATH|TICK|POST|SUDO
  --list-builds ENGINE           MODE|LABEL|DESCRIPTION|PATHKIND
  --list-patches ENGINE          FLAG|NAME|DESC|DEPS|TICK|PATH
  --query FIELD ENGINE FLAGS     FIELD: path|name|desc|deps|tick
  build ENGINE --patch=FLAGS     apply patches and build
  dxvk                           build the dxvk-native tarball

The record emitted by --list is the single source of truth for the TUI:
KIND is patch, tool or bin; PAGE is the engine for patches and bins and
host/after for tools.  DEPS is a comma list and empty for "none".
PATH is a repo-relative file for patches/tools and TAG=value;TAG=value
for link modes.  Booleans are yes/no and are always present.

Paths and flags come from the environment (VMM_SRC, VMM_BUILD, VMM_PREFIX,
VMM_JOBS, VMM_CFLAGS, VMM_CXXFLAGS) plus the upstreams.conf locks.
EOF
}
