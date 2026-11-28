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

# ---------------------------------------------------------------------------
# Rolling build-log window.  One writer (the renderer) owns the TTY; the
# build subprocess writes only to its log file.  Non-TTY terminals get plain
# output, and VMM_LOGWIN=0 forces that fallback explicitly.
#   vmm_logwin_stream LOG LABEL VALUE PID
VMM_LOGWIN_N=${VMM_LOGWIN_N:-20}
VMM_LOGWIN_DELAY=${VMM_LOGWIN_DELAY:-1}

vmm_logwin_ok() {
    [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "${VMM_LOGWIN:-1}" != 0 ]
}

# Strip CR, expand tabs, strip embedded ANSI, then truncate by byte count.
vmm_logwin_clean() {
    local s="$1" max="$2"
    s=${s//$'\r'/}
    s=${s//$'\t'/ }
    s=$(printf '%s' "$s" | LC_ALL=C sed $'s/\033\[[0-9;?]*[A-Za-z]//g')
    printf '%s' "${s:0:max}"
}

vmm_logwin_stream() (
    local log="$1" label="$2" value="$3" pid="$4" status="${5:-}"
    local n="$VMM_LOGWIN_N" delay="$VMM_LOGWIN_DELAY" spinner=('|' '/' '-' '\')
    local cyan=$'\033[1;36m' amber=$'\033[1;33m' green=$'\033[1;32m' red=$'\033[1;31m'
    local reset=$'\033[0m' up erase hide show
    local rows cols width window tick=0 drawn=0 total start end final alive failed rc
    local val_max range_max frame file chunk line done_flag=0

    if ! vmm_logwin_ok; then
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        cat "$log"
        return 0
    fi

    cleanup() {
        [ "$done_flag" = 1 ] && return 0
        done_flag=1
        printf '%s\n' "$reset"
        printf '\033[?25h'
    }
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT TERM

    hide=$'\033[?25l'; show=$'\033[?25h'; erase=$'\033[2K'
    printf '%s' "$hide"

    while :; do
        rows=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
        [ "$rows" -gt 5 ] || rows=24
        [ "$cols" -gt 1 ] || cols=80
        [ "$n" -lt $((rows - 5)) ] || n=$((rows - 5))
        width=$((cols - 1))
        window=$((n + 3))
        up=$'\033['"$window"'A'

        total=$(wc -l < "$log" 2>/dev/null || echo 0)
        kill -0 "$pid" 2>/dev/null && alive=1 || alive=0
        # Tail window: always the latest n lines, so a burst cannot build a
        # backlog.  The log file itself remains the full archive.
        start=$((total - n + 1)); [ "$start" -lt 1 ] && start=1
        end=$total
        [ "$alive" = 0 ] && final=1 || final=0
        failed=0
        if [ "$final" = 1 ]; then
            rc=""
            [ -n "$status" ] && [ -f "$status" ] && rc=$(cat "$status" 2>/dev/null || true)
            if [ -n "$rc" ] && [ "$rc" != 0 ]; then
                failed=1
            elif [ -z "$rc" ] && grep -q '^ERROR:' "$log" 2>/dev/null; then
                failed=1
            fi
        fi

        [ "$drawn" -gt 0 ] && printf '%s' "$up"

        val_max=$((width - ${#label} - 9)); [ "$val_max" -lt 1 ] && val_max=1
        value=$(vmm_logwin_clean "$value" "$val_max")
        printf '\r%s%s%s%s %s (build)\n' \
            "$erase" "$cyan" "$label" "$reset" "$value"

        range_max=$((width - ${#start} - ${#end} - 22))
        [ "$range_max" -lt 1 ] && range_max=1
        file=$(vmm_logwin_clean "$log" "$range_max")
        frame=${spinner[tick % 4]}
        if [ "$final" = 1 ]; then
            if [ "$failed" = 1 ]; then
                printf '\r%s   %s[x] lines %s-%s%s from %s\n' \
                    "$erase" "$red" "$start" "$end" "$reset" "$file"
            else
                printf '\r%s   %s[+] lines %s-%s%s from %s\n' \
                    "$erase" "$green" "$start" "$end" "$reset" "$file"
            fi
        else
            printf '\r%s   %s[%s] lines %s-%s%s from %s\n' \
                "$erase" "$amber" "$frame" "$start" "$end" "$reset" "$file"
        fi
        printf '\r%s\n' "$erase"

        mapfile -t chunk < <(tail -n "$n" "$log" 2>/dev/null)
        for ((j = 0; j < n; j++)); do
            printf '\r%s%s\n' "$erase" "$(vmm_logwin_clean "${chunk[j]:-}" "$width")"
        done

        tick=$((tick + 1)); drawn=1
        [ "$final" = 1 ] && break
        sleep "$delay"
    done
    cleanup
)

# Extract a tarball, falling back to plain files when the filesystem cannot
# create symlinks (NTFS/SMB mounts).  The fallback writes symlink targets as
# text files and preserves regular-file modes.
#   vmm_extract_tar ARCHIVE DEST [STRIP_COMPONENTS]
vmm_extract_tar() {
    local tb="$1" dest="$2" strip="${3:-0}" err
    err="$(mktemp "${TMPDIR:-/tmp}/vmm-tar.XXXXXX")" || return 1
    if [ "${VMM_FORCE_TAR_FALLBACK:-0}" != 1 ] &&
       tar -xf "$tb" -C "$dest" --strip-components="$strip" 2>"$err"; then
        rm -f "$err"
        return 0
    fi
    if [ "${VMM_FORCE_TAR_FALLBACK:-0}" != 1 ] &&
       ! grep -qiE 'symlink|operation not supported|not supported' "$err"; then
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    printf -- '-- tar: symlinks unsupported; extracting with plain-file fallback\n' >&2
    python3 - "$tb" "$dest" "$strip" <<'PYFALLBACK'
import os, sys, tarfile
archive, dest, strip = sys.argv[1], sys.argv[2], int(sys.argv[3])
tf = tarfile.open(archive)
members = tf.getmembers()
tty = sys.stderr.isatty()
for index, member in enumerate(members, 1):
    if tty and (index % 200 == 0 or index == len(members)):
        sys.stderr.write('\r  extracting %d/%d entries' % (index, len(members)))
        sys.stderr.flush()
    parts = member.name.split('/')
    if len(parts) <= strip:
        continue
    name = '/'.join(parts[strip:]).lstrip('/')
    if not name or '..' in name.split('/'):
        continue
    target = os.path.join(dest, name)
    parent = os.path.dirname(target)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if member.isdir():
        os.makedirs(target, exist_ok=True)
        continue
    if member.isfile():
        source = tf.extractfile(member)
        with open(target, 'wb') as out:
            out.write(source.read())
    elif member.issym() or member.islnk():
        # Resolve the link against the archive when possible: writing the
        # target contents is more useful than a text file holding a path.
        link = member.linkname or ''
        if member.issym():
            base = member.name.rsplit('/', 1)[0] if '/' in member.name else ''
            resolved = os.path.normpath(os.path.join(base, link)) if base else link
        else:
            resolved = link
        parts = resolved.split('/')
        source_member = tf.getmember(resolved) if len(parts) > strip and parts[:strip] == member.name.split('/')[:strip] else None
        if source_member and source_member.isfile():
            src = tf.extractfile(source_member)
            with open(target, 'wb') as out:
                out.write(src.read())
        else:
            with open(target, 'w') as out:
                out.write(link + '\n')
    else:
        continue
    try:
        os.chmod(target, member.mode & 0o777)
    except OSError:
        pass
if tty:
    sys.stderr.write('\n')
PYFALLBACK
}
