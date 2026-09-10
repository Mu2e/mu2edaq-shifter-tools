#!/usr/bin/env bash
#
# start-tmux.sh
#
# Build the shifter's tmux workspace: a session whose first window is
# split into four quadrants for general operator work, plus a second
# window split in two for building.
#
#     |---------------------------|---------------------------|
#     | main                      | monitor                   |
#     |---------------------------|---------------------------|
#     | env A                     | env B                     |
#     |---------------------------|---------------------------|
#
# This only lays out panes; it does not start ots. Use start-daq.sh for
# that -- the two are independent and can both be running.
#
# Configuration precedence: command line > environment > .env > default.
#
#   -s, --session NAME  session name    (env MU2EDAQ_TMUX_SESSION,
#                                        default daq)
#   -d, --directory DIR starting directory for every pane
#                                       (env MU2EDAQ_TMUX_CWD, default $PWD)
#   -a, --attach        attach when the layout is built
#   -n, --dry-run       print what would happen, change nothing
#   -h, --help          show this help and exit
#
# See start-tmux.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$SCRIPT_DIR/scripts/daq-common.sh" \
           "$HOME/bin/daq-common.sh"; do
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "start-tmux.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="start-tmux.sh"
daq_load_dotenv

session="${MU2EDAQ_TMUX_SESSION:-daq}"
cwd="${MU2EDAQ_TMUX_CWD:-$PWD}"
attach=0
dry_run=0

USAGE="\
usage: $(basename "$0") [-s session] [-d directory] [-a] [-n]

Build the shifter tmux workspace (four-quadrant main window plus a
split build window).

  -s, --session NAME   session name (default daq)
  -d, --directory DIR  starting directory for each pane (default \$PWD)
  -a, --attach         attach when the layout is built
  -n, --dry-run        show what would be done, change nothing
  -h, --help           show this help and exit
"

# Options may also be supplied via $START_TMUX_SH_OPTS.
eval set -- $(daq_script_opts start-tmux.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -s|--session)   shift; session="${1:-}";;
        -d|--directory) shift; cwd="${1:-}";;
        -a|--attach)    attach=1;;
        -n|--dry-run)   dry_run=1;;
        -h|--help|-\?)  printf '%s' "$USAGE"; exit 0;;
        --debug)        set -x;;
        *)              daq_warn "unknown option: $1"
                        printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

command -v tmux >/dev/null 2>&1 || daq_die "tmux is not installed"
[ -d "$cwd" ] || daq_die "not a directory: $cwd"

if [ "$dry_run" -eq 0 ] && tmux has-session -t "$session" 2>/dev/null; then
    echo "Session $session already exists."
    [ "$attach" -eq 1 ] && exec tmux attach -t "$session"
    exit 0
fi

run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

echo "Building tmux session $session in $cwd"

# Main window: four quadrants.
run tmux new-session -d -s "$session" -n "daq-main" -c "$cwd"
run tmux split-window -t "$session:daq-main" -h -c "$cwd"
run tmux split-window -t "$session:daq-main.0" -v -c "$cwd"
run tmux split-window -t "$session:daq-main.2" -v -c "$cwd"
run tmux select-layout -t "$session:daq-main" tiled
run tmux select-pane -t "$session:daq-main.0"

# Build window: two panes side by side.
run tmux new-window -t "$session" -n "build" -c "$cwd"
run tmux split-window -t "$session:build" -h -c "$cwd"
run tmux select-pane -t "$session:build.0"

run tmux select-window -t "$session:daq-main"

if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: nothing was created."
    exit 0
fi

echo ""
tmux list-windows -t "$session" -F '  #{window_index}: #{window_name} (#{window_panes} panes)'
echo ""
echo "Attach with:  tmux attach -t $session"

[ "$attach" -eq 1 ] && exec tmux attach -t "$session"
exit 0
