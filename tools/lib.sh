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

note() { printf -- '-- %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n==> %s\n' "$*"; }

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
