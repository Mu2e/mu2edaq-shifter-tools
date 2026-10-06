#!/usr/bin/env bash
#
# install-login.sh
#
# Install the Mu2e DAQ shifter environment for the current user:
#
#   * login/*        -> $HOME/.<name>        (e.g. login/bashrc -> ~/.bashrc)
#   * scripts/*      -> ~/bin/<name>         executable
#   * start-daq.sh   -> ~/bin/start-daq.sh   executable
#   * stop-daq.sh    -> ~/bin/stop-daq.sh    executable
#   * MU2EDAQ_ROOT   -> ~/.mu2edaq/env       so the installed commands
#                                            find config/ and data/
#
# ~/bin is added to PATH by login/bash_profile, so everything becomes
# available on the PATH after the next login.
#
# Any existing file that would be overwritten is first backed up to
# <file>.bak.<timestamp>.
#
# Configuration precedence: command line > environment > default.
#
#   -d, --home DIR   install the dotfiles here   (env MU2EDAQ_INSTALL_HOME,
#                                                 default $HOME)
#   -b, --bin  DIR   install the commands here   (env MU2EDAQ_INSTALL_BIN,
#                                                 default <home>/bin)
#   -r, --root DIR   record this as MU2EDAQ_ROOT (default: this checkout)
#   -N, --no-env     do not write ~/.mu2edaq/env
#   -n, --dry-run    show what would be done, change nothing
#   -h, --help       show this help and exit
#
# See install-login.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

LOGIN_SRC="$SCRIPT_DIR/login"
SCRIPTS_SRC="$SCRIPT_DIR/scripts"

# Top-level commands that also belong on the PATH.
TOPLEVEL_COMMANDS="start-daq.sh stop-daq.sh"

target_home="${MU2EDAQ_INSTALL_HOME:-$HOME}"
bin_dir="${MU2EDAQ_INSTALL_BIN:-}"
record_root="$SCRIPT_DIR"
write_env=1
dry_run=0

USAGE="\
usage: $(basename "$0") [-d home] [-b bin] [-r root] [-N] [-n]

Install the login dotfiles and the shifter commands for the current user.

  -d, --home DIR   install dotfiles into DIR   (default: \$HOME)
  -b, --bin  DIR   install commands into DIR   (default: <home>/bin)
  -r, --root DIR   record DIR as MU2EDAQ_ROOT  (default: this checkout)
  -N, --no-env     do not write <home>/.mu2edaq/env
  -n, --dry-run    show what would be done, change nothing
  -h, --help       show this help and exit

Any existing file that would be overwritten is backed up to
<file>.bak.<timestamp> first.
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -d|--home)    shift; target_home="${1:-}";;
        -b|--bin)     shift; bin_dir="${1:-}";;
        -r|--root)    shift; record_root="${1:-}";;
        -N|--no-env)  write_env=0;;
        -n|--dry-run) dry_run=1;;
        -h|--help)    printf '%s' "$USAGE"; exit 0;;
        *)            echo "Unknown option: $1" >&2
                      printf '%s' "$USAGE" >&2; exit 2;;
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
    name="$(basename "$src")"
    install_file "$src" "$target_home/.$name" 644
done

# --- Install the commands ------------------------------------------------
echo "Installing commands from $SCRIPTS_SRC into $bin_dir"
run mkdir -p "$bin_dir"
for src in "$SCRIPTS_SRC"/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    install_file "$src" "$bin_dir/$name" 755
done

echo "Installing top-level commands into $bin_dir"
for name in $TOPLEVEL_COMMANDS; do
    src="$SCRIPT_DIR/$name"
    if [ -f "$src" ]; then
        install_file "$src" "$bin_dir/$name" 755
    else
        echo "  WARNING: $src is missing, skipping" >&2
    fi
done

# --- Record the installation root -----------------------------------------
# The commands in ~/bin cannot locate config/ and data/ by walking up from
# themselves, so MU2EDAQ_ROOT is recorded where daq-common.sh and the
# Python config module both look for it.
if [ "$write_env" -eq 1 ]; then
    env_dir="$target_home/.mu2edaq"
    env_file="$env_dir/env"
    echo "Recording MU2EDAQ_ROOT=$record_root in $env_file"
    run mkdir -p "$env_dir"
    if [ "$dry_run" -eq 1 ]; then
        echo "  + write MU2EDAQ_ROOT=$record_root to $env_file"
    else
        backup "$env_file"
        cat > "$env_file" <<ENVEOF
# Written by install-login.sh on $(date).
#
# Read by daq-common.sh and mu2edaq_shifter_tools.config so the commands
# installed in $bin_dir can find config/ and data/. Values here rank
# below the real environment, so exporting MU2EDAQ_ROOT still wins.
MU2EDAQ_ROOT=$record_root
ENVEOF
    fi
fi

echo ""
if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: nothing was installed."
else
    echo "Done."
fi
echo "Note: $bin_dir is added to PATH by ~/.bash_profile;"
echo "      open a new login shell to pick it up."
exit 0
