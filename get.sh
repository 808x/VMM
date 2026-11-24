#!/bin/bash
# Fetch the VMM source and lay out a tidy install tree.
#
# Usage:
#   get.sh [--target DIR] [--branch NAME] [--url URL] [--sha256 HASH]
#          [--force] [--run [install.sh args...]]
#
# Produced in DIR (default: ./VMM):
#
#   get.sh          copy of this script
#   install.sh      symlink to src/install.sh (copy if links are unsupported)
#   src/            main.tar.gz plus the unpacked source tree
#   prefix/         built by install.sh; launch.sh is linked once it exists
#
# Symlinks are preferred. On filesystems without symlink support (NTFS,
# SMB2) the two tiny front scripts are copied instead.
set -eu

BRANCH="${VMM_BRANCH:-main}"
BASE_URL="${VMM_BASE_URL:-https://github.com/808x/VMM/archive/refs/heads}"
RAW_GET_URL="${VMM_GET_URL:-https://raw.githubusercontent.com/808x/VMM/main/get.sh}"
PINNED_SHA256="${VMM_SHA256:-}"
TARGET="${VMM_TARGET:-}"
URL=""
URL_GIVEN=0
SHA256=""
FORCE=0
RUN=0
INSTALL_ARGS=()

usage() {
    cat <<'EOF'
Fetch the VMM source and lay out a tidy install tree.

  --target DIR     install tree location (default: ./VMM)
  --branch NAME    source branch to fetch (default: main)
  --url URL        archive URL, or a base URL containing <branch>.tar.gz
  --sha256 HASH    expected archive SHA-256 (overrides a sidecar file)
  --force          refresh src/ and the front links in an existing tree
  --run            run ./install.sh after unpacking; remaining arguments
                   are passed to it
  -h, --help       show this help

Environment: VMM_URL, VMM_SHA256, VMM_BRANCH, VMM_TARGET, VMM_TARBALL.

The archive is stored as src/<branch>.tar.gz. When no SHA-256 is supplied,
the computed value is printed so it can be pinned with --sha256.
EOF
}

die() { printf 'get: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --target) [ $# -ge 2 ] || die "--target needs a directory"
                  TARGET=$2; shift 2 ;;
        --target=*) TARGET=${1#*=}; shift ;;
        --branch) [ $# -ge 2 ] || die "--branch needs a value"
                  BRANCH=$2; shift 2 ;;
        --branch=*) BRANCH=${1#*=}; shift ;;
        --url) [ $# -ge 2 ] || die "--url needs a value"
               URL=$2; URL_GIVEN=1; shift 2 ;;
        --url=*) URL=${1#*=}; URL_GIVEN=1; shift ;;
        --sha256) [ $# -ge 2 ] || die "--sha256 needs a value"
                  SHA256=$2; shift 2 ;;
        --sha256=*) SHA256=${1#*=}; shift ;;
        --force) FORCE=1; shift ;;
        --run) RUN=1; shift
               INSTALL_ARGS=("$@"); break ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "${VMM_URL:-}" ] && URL_GIVEN=1
[ -n "$URL" ] || URL=${VMM_URL:-$BASE_URL}
[ -n "$SHA256" ] || SHA256=$PINNED_SHA256
[ -n "$TARGET" ] || TARGET=$PWD/VMM
[ -n "$BRANCH" ] || die "empty branch name"

case "$TARGET" in
    /*) ;;
    *) TARGET=$PWD/$TARGET ;;
esac
TARGET=${TARGET%/}
[ -n "$TARGET" ] || die "refusing to unpack into /"

ARCHIVE="$BRANCH.tar.gz"
script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/vmm-get.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- target

parent=$(dirname -- "$TARGET")
[ -d "$parent" ] || mkdir -p "$parent" || die "cannot create $parent"
[ -w "$parent" ] || die "not writable: $parent (run as the user who owns it)"

if [ -e "$TARGET" ]; then
    [ -d "$TARGET" ] || die "target exists and is not a directory: $TARGET"
    if [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
        if [ "$FORCE" = 0 ]; then
            die "target already exists: $TARGET
Use --force to refresh src/ and the front links, or choose another --target."
        fi
        case "$TARGET" in
            /|/home|/root|/usr|/usr/local|/media|/mnt)
                die "refusing to --force into $TARGET" ;;
        esac
    fi
else
    mkdir -p "$TARGET" || die "cannot create $TARGET"
fi

# --------------------------------------------------------------- acquire

local_archive() {
    for f in "${VMM_TARBALL:-}" "$script_dir/$ARCHIVE" "$PWD/$ARCHIVE" "$TARGET/src/$ARCHIVE"; do
        [ -n "$f" ] && [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

download() {
    local url=$1 out=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --proto '=https' --proto-redir '=https' \
             --tlsv1.2 -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only -O "$out" "$url"
    else
        die "need curl or wget to download $url"
    fi
}

file=${VMM_TARBALL:-}
if [ -n "$file" ]; then
    [ -f "$file" ] || die "VMM_TARBALL does not exist: $file"
elif [ "$URL_GIVEN" = 0 ] && file=$(local_archive); then
    : # An adjacent archive wins over the network.
else
    case "$URL" in
        *.tar.gz|*.tgz) url=$URL ;;
        *) url=${URL%/}/$ARCHIVE ;;
    esac
    say "Fetching $url"
    download "$url" "$work/$ARCHIVE" || die "download failed: $url"
    file=$work/$ARCHIVE
fi

# ---------------------------------------------------------------- verify

if [ -z "$SHA256" ]; then
    for sidecar in "$file.sha256" "$script_dir/$ARCHIVE.sha256" "$PWD/$ARCHIVE.sha256"; do
        [ -f "$sidecar" ] || continue
        SHA256=$(awk 'NR == 1 { print $1 }' "$sidecar")
        break
    done
fi

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
actual=$(sha256sum "$file" | awk '{ print $1 }')
if [ -n "$SHA256" ]; then
    [ "$actual" = "$SHA256" ] || die "SHA-256 mismatch for $ARCHIVE
  expected: $SHA256
  actual:   $actual"
    say "Verified $ARCHIVE"
else
    say "No SHA-256 supplied; computed $actual"
    say "Pin it with --sha256 $actual"
fi

# A refresh may be reusing the archive stored in src/, which is about to be
# removed; move it out of the way first.
case "$file" in
    "$TARGET/src/"*) cp -f "$file" "$work/$ARCHIVE"; file=$work/$ARCHIVE ;;
esac

# --------------------------------------------------------------- extract

tar -tzf "$file" > "$work/listing" || die "archive is not readable: $file"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$work/listing"; then
    die "archive contains unsafe paths"
fi
top=$(awk -F/ 'NF { print $1; exit }' "$work/listing")
[ -n "$top" ] || die "archive is empty"
if grep -Evq "^$top/|^$top$" "$work/listing"; then
    die "archive does not have a single top-level directory"
fi

if [ "$FORCE" = 1 ] && [ -d "$TARGET/src" ]; then
    rm -rf "$TARGET/src" || die "cannot refresh $TARGET/src"
fi
mkdir -p "$TARGET/src" || die "cannot create $TARGET/src"
tar -xzf "$file" -C "$TARGET/src" --strip-components=1 ||
    die "extraction failed"
[ -f "$TARGET/src/install.sh" ] || die "archive has no install.sh"
[ -d "$TARGET/src/tools" ] || die "archive has no tools/"

if [ "$(cd "$(dirname -- "$file")" && pwd)/$(basename -- "$file")" != \
     "$TARGET/src/$ARCHIVE" ]; then
    cp -f "$file" "$TARGET/src/$ARCHIVE" || die "cannot store $ARCHIVE in src/"
fi

# ----------------------------------------------------------- front links

link_or_copy() {
    local rel=$1 dst=$2
    rm -f "$dst" 2>/dev/null || true
    if ln -s "$rel" "$dst" 2>/dev/null; then
        say "linked $dst -> $rel"
    elif cp -f "$TARGET/$rel" "$dst" && chmod 0755 "$dst"; then
        say "copied $dst (symlinks unsupported on this filesystem)"
    else
        die "cannot link or copy $dst"
    fi
}

link_or_copy "src/install.sh" "$TARGET/install.sh"
if [ -f "$TARGET/prefix/launch.sh" ]; then
    link_or_copy "prefix/launch.sh" "$TARGET/launch.sh"
else
    say "no prebuilt prefix/launch.sh; install.sh will create it"
fi

# Keep a readable copy of the bootstrap beside the tree. When running from a
# pipe there is no local file, so fetch it best-effort.
dest=$TARGET/get.sh
self=$([ -f "${BASH_SOURCE[0]:-}" ] && readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
dest_real=$(readlink -f "$dest" 2>/dev/null || printf '%s' "$dest")
if [ -n "$self" ] && [ "$self" != "$dest_real" ]; then
    cp -f "$self" "$dest" && chmod 0755 "$dest" ||
        say "warning: could not copy get.sh into $TARGET"
elif [ ! -f "$dest" ]; then
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$RAW_GET_URL" 2>/dev/null &&
            chmod 0755 "$dest" ||
            say "warning: could not fetch get.sh into $TARGET"
    else
        say "warning: get.sh is not saved in $TARGET"
    fi
fi

say "Unpacked VMM $BRANCH into $TARGET"

if [ "$RUN" = 1 ]; then
    [ -x "$TARGET/install.sh" ] || die "install.sh is not executable"
    cd "$TARGET"
    run_install() {
        if [ "${#INSTALL_ARGS[@]}" -gt 0 ]; then
            ./install.sh "${INSTALL_ARGS[@]}"
        else
            ./install.sh
        fi
    }
    if [ -t 0 ]; then
        run_install
        exit $?
    elif [ "${#INSTALL_ARGS[@]}" -gt 0 ]; then
        # Explicit installer arguments do not need the interactive menu.
        run_install
        exit $?
    elif ( : < /dev/tty ) 2>/dev/null; then
        run_install < /dev/tty
        exit $?
    else
        die "no terminal for the installer; run $TARGET/install.sh yourself"
    fi
fi

cat <<EOF

Next:
  cd $TARGET
  ./install.sh
  ./prefix/launch.sh
EOF
