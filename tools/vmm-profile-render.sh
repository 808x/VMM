#!/bin/bash
# Render domain XML from profile.conf and share/examples/*.xml.in.
#
# The profile is plain bash: VMS=(fn ...), one function per VM setting
# NAME/UUID/TEMPLATE/... globals.  Rules:
#   1. a key the function does not set leaves its @KEY@ token untouched;
#   2. a key set to an empty value is filled in here (UUID is generated and
#      remembered in $PREFIX/state/domains).
#
# Relative DISK values are resolved against the prefix on every run, so a
# moved tree keeps working.
#
# Usage:
#   vmm-render --profile FILE --prefix DIR [--write DIR] [--define] [--list]
#
#   --write DIR   also write each rendered domain as DIR/<template>.xml
#   --define      define each rendered domain with virsh, fixing name/uuid
#                 collisions on first define
#   --list        print one line per VM and exit
set -u

PREFIX=""
PROFILE=""
WRITE_DIR=""
DEFINE=0
LIST=0

die() { printf 'vmm-render: %s\n' "$*" >&2; exit 1; }
warn() { printf 'vmm-render: %s\n' "$*" >&2; }
note() { printf 'vmm-render: %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=${2:?--profile needs a value}; shift 2 ;;
        --prefix) PREFIX=${2:?--prefix needs a value}; shift 2 ;;
        --write) WRITE_DIR=${2:?--write needs a value}; shift 2 ;;
        --define) DEFINE=1; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ -z "$PREFIX" ]; then
    # Installed at $PREFIX/bin/vmm-render.
    PREFIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
[ -n "$PROFILE" ] || PROFILE="$PREFIX/profile.conf"
[ -f "$PROFILE" ] || die "no profile at $PROFILE"
[ -d "$PREFIX" ] || die "no prefix at $PREFIX"

export PREFIX
# shellcheck disable=SC1090
. "$PROFILE" || die "cannot source $PROFILE"
[ -n "${VMS+x}" ] || die "$PROFILE does not set VMS=()"
[ "${#VMS[@]}" -gt 0 ] || die "$PROFILE has an empty VMS=()"

STATE_DIR="$PREFIX/state"
STATE_FILE="$STATE_DIR/domains"
mkdir -p "$STATE_DIR" 2>/dev/null || warn "cannot create $STATE_DIR"

# Remembered identities: "fn=<uuid>" and "fn.name=<name>".
declare -A SAVED=()
if [ -f "$STATE_FILE" ]; then
    while IFS='=' read -r k v; do
        [ -n "$k" ] && SAVED[$k]=$v
    done < "$STATE_FILE"
fi
save_state() {
    local k=$1 v=$2
    [ "${SAVED[$k]:-}" = "$v" ] && return 0
    SAVED[$k]=$v
    printf '%s=%s\n' "$k" "$v" >> "$STATE_FILE" 2>/dev/null ||
        warn "cannot write $STATE_FILE"
}

new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        die "no uuidgen and no /proc uuid source"
    fi
}

abspath() {
    local p=$1
    case "$p" in
        /*) ;;
        *) p="$PREFIX/$p" ;;
    esac
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$p"
    else
        printf '%s\n' "$p"
    fi
}

virsh_ok() { command -v virsh >/dev/null 2>&1 && virsh list --name >/dev/null 2>&1; }

# Tokens present in a template, deduplicated.
template_tokens() {
    grep -o '@[A-Z_][A-Z0-9_]*@' "$1" 2>/dev/null | sort -u | tr -d '@'
}

render_one() {
    local fn=$1 tmpl=$2 out=$3
    local line tok val name
    local -a tokens=()

    # Rule 1 needs a clean slate: a stale global from the previous VM would
    # otherwise look like "set" and leak into this domain.
    mapfile -t tokens < <(template_tokens "$tmpl")
    if [ "${#tokens[@]}" -gt 0 ]; then
        for tok in "${tokens[@]}"; do unset "$tok"; done
    fi
    unset TEMPLATE

    "$fn" || die "profile function $fn failed"

    [ -n "${NAME:-}" ] || die "$fn sets no NAME"
    [ -n "${TEMPLATE:-}" ] || die "$fn sets no TEMPLATE"
    [ "$TEMPLATE" = "$(basename "$tmpl")" ] || die "$fn TEMPLATE=$TEMPLATE does not match $tmpl"

    # Name collisions and UUID reuse only matter when touching libvirt.
    if [ "$DEFINE" = 1 ] && virsh_ok; then
        if [ -n "${UUID:-}" ]; then
            name=$(virsh domname "$UUID" 2>/dev/null) || name=""
            if [ -n "$name" ] && [ "$name" != "$NAME" ]; then
                note "$fn: uuid $UUID is already domain '$name'; keeping that name"
                NAME=$name
            fi
        elif [ -n "${SAVED[$fn]:-}" ]; then
            # A stored identity exists; trust libvirt's current name if it has one.
            UUID=${SAVED[$fn]}
            name=$(virsh domname "$UUID" 2>/dev/null) || name=""
            if [ -n "$name" ]; then
                NAME=$name
            else
                NAME=${SAVED[$fn.name]:-$NAME}
            fi
        else
            UUID=$(new_uuid)
            if virsh dominfo "$NAME" >/dev/null 2>&1; then
                local base=$NAME n=2 existing
                existing=$(virsh dominfo "$base" 2>/dev/null | awk -F': *' '/^UUID:/ {print $2}')
                if [ "$existing" = "$UUID" ]; then
                    :
                else
                    while virsh dominfo "$base-$n" >/dev/null 2>&1; do n=$((n + 1)); done
                    NAME=$base-$n
                    note "$fn: name '$base' is used by another uuid; using '$NAME'"
                fi
            fi
            save_state "$fn" "$UUID"
            save_state "$fn.name" "$NAME"
        fi
    else
        if [ -z "${UUID:-}" ]; then
            if [ -n "${SAVED[$fn]:-}" ]; then
                UUID=${SAVED[$fn]}
            else
                UUID=$(new_uuid)
                save_state "$fn" "$UUID"
            fi
        fi
    fi

    # Host paths that travel between machines: DISK is resolved per host.
    if [ -n "${DISK:-}" ]; then
        case "$DISK" in
            /*) ;;
            *) DISK=$(abspath "$DISK") ;;
        esac
        [ -e "$DISK" ] || warn "$fn: disk does not exist yet: $DISK"
    fi

    # Resolve each token once; warn once for any empty value.
    local -A VALS=()
    if [ "${#tokens[@]}" -gt 0 ]; then
    for tok in "${tokens[@]}"; do
        case "$tok" in
            UUID) val=${UUID:-} ;;
            NAME) val=${NAME:-} ;;
            DISK) val=${DISK:-} ;;
            *) if [ -n "${!tok+x}" ]; then val=${!tok}; else continue; fi ;;
        esac
        if [ -z "$val" ]; then
            warn "$fn: @$tok@ is empty and has no filler; left in place"
        else
            VALS[$tok]=$val
        fi
    done
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        for tok in "${!VALS[@]}"; do
            line=${line//@$tok@/${VALS[$tok]}}
        done
        printf '%s\n' "$line"
    done < "$tmpl" > "$out"

    if grep -q '@[A-Z_][A-Z0-9_]*@' "$out" 2>/dev/null; then
        warn "$fn: unresolved tokens remain in $out"
    fi
    return 0
}

if [ "$LIST" = 1 ]; then
    for fn in "${VMS[@]}"; do
        unset TEMPLATE NAME UUID DISK
        "$fn"
        printf '%s\t%s\t%s\t%s\n' "$fn" "${NAME:-?}" "${UUID:-<generated>}" "${TEMPLATE:-?}"
    done
    exit 0
fi

if [ -n "$WRITE_DIR" ]; then
    mkdir -p "$WRITE_DIR" || die "cannot create $WRITE_DIR"
fi

rc=0
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/vmm-render.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

for fn in "${VMS[@]}"; do
    unset TEMPLATE NAME UUID DISK
    # Read TEMPLATE first so the output name is known before rendering.
    "$fn" >/dev/null 2>&1 || true
    tmplname=${TEMPLATE:-}
    [ -n "$tmplname" ] || { warn "$fn sets no TEMPLATE; skipped"; rc=1; continue; }
    tmpl="$PREFIX/share/examples/$tmplname"
    [ -f "$tmpl" ] || tmpl="$PREFIX/share/examples/$(basename "$tmplname")"
    if [ ! -f "$tmpl" ]; then
        warn "$fn: template not found: $tmpl"; rc=1; continue
    fi

    out="$tmpdir/$(basename "${tmpl%.in}")"
    render_one "$fn" "$tmpl" "$out" || { rc=1; continue; }
    note "$fn: rendered ${tmpl%.in}"

    if [ -n "$WRITE_DIR" ]; then
        cp -f "$out" "$WRITE_DIR/$(basename "${tmpl%.in}")" ||
            { warn "cannot write $WRITE_DIR/$(basename "${tmpl%.in}")"; rc=1; }
    fi

    if [ "$DEFINE" = 1 ]; then
        if ! command -v virsh >/dev/null 2>&1; then
            warn "$fn: virsh not available; not defined"; rc=1; continue
        fi
        if virsh define "$out" >/dev/null 2>&1; then
            note "$fn: defined ${NAME:-domain}"
        else
            warn "$fn: virsh define failed"; rc=1
        fi
    fi
done

exit "$rc"
