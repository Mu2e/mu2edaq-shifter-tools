#!/bin/bash
#
# install_login.sh
#
# Install the Mu2e DAQ shifter login environment for the current user:
#   * Files in   login/   are installed into $HOME with a leading "."
#                (e.g. login/bashrc -> ~/.bashrc)
#   * Files in   scripts/ are installed into ~/bin and made executable.
#
# ~/bin is already added to PATH by login/bash_profile, so the scripts
# become available on the PATH after the next login.
#
# Any existing file that would be overwritten is first backed up to
# <file>.bak.<timestamp>.

set -u

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

LOGIN_SRC="$SCRIPT_DIR/login"
SCRIPTS_SRC="$SCRIPT_DIR/scripts"

# Defaults (overridable on the command line)
target_home="$HOME"
bin_dir=""          # defaults to <target_home>/bin once parsed
dry_run=0

USAGE="\
usage: $(basename "$0") [options]

Install the login dotfiles and helper scripts for the current user.

  -d, --home DIR   Install dotfiles into DIR        (default: \$HOME)
  -b, --bin  DIR   Install scripts into DIR         (default: <home>/bin)
  -n, --dry-run    Show what would be done, change nothing
  -h, --help       Show this help and exit

Any existing file that would be overwritten is backed up to
<file>.bak.<timestamp> first.
"

while [ -n "${1-}" ]; do
    case "$1" in
        -d|--home)    shift; target_home="${1-}";;
        -b|--bin)     shift; bin_dir="${1-}";;
        -n|--dry-run) dry_run=1;;
        -h|--help)    echo "$USAGE"; exit 0;;
        *)            echo "Unknown option: $1" >&2; echo "$USAGE" >&2; exit 1;;
    esac
    shift
done

[ -z "$bin_dir" ] && bin_dir="$target_home/bin"

# run CMD... unless this is a dry run; always echo what is happening
run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

# Back up DEST if it already exists, before it gets overwritten
backup() {
    local dest="$1"
    if [ -e "$dest" ]; then
        run cp -p "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
    fi
}

install_file() {
    local src="$1" dest="$2" mode="$3"
    backup "$dest"
    run install -m "$mode" "$src" "$dest"
}

# --- Sanity checks --------------------------------------------------------
status=0
[ -d "$LOGIN_SRC" ]   || { echo "ERROR: missing source directory: $LOGIN_SRC" >&2; status=1; }
[ -d "$SCRIPTS_SRC" ] || { echo "ERROR: missing source directory: $SCRIPTS_SRC" >&2; status=1; }
[ "$status" -eq 0 ]   || exit "$status"

# --- Install login dotfiles ----------------------------------------------
echo "Installing login files from $LOGIN_SRC into $target_home"
run mkdir -p "$target_home"
for src in "$LOGIN_SRC"/*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    install_file "$src" "$target_home/.$name" 644
done

# --- Install helper scripts ----------------------------------------------
echo "Installing scripts from $SCRIPTS_SRC into $bin_dir"
run mkdir -p "$bin_dir"
for src in "$SCRIPTS_SRC"/*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    install_file "$src" "$bin_dir/$name" 755
done

echo "Done.${dry_run:+ (dry run)}"
echo "Note: ~/bin is added to PATH by ~/.bash_profile; open a new login shell to pick it up."
