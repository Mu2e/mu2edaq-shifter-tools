#!/usr/bin/env bash
#
# stop-daq.sh
#
# Stop the Mu2e DAQ for one partition (or for every configured
# partition) by sending "ots -k" into each of the tmux windows that
# start-daq.sh created, then tearing down the session.
#
# Windows are addressed by name (daq-<partition>-<environment>), so this
# script does not depend on the order in which start-daq.sh created
# them.
#
# Configuration precedence: command line > environment > .env > config file.
#
#   -c, --config FILE     operations YAML   (env MU2EDAQ_CONFIG,
#                                            default: daq-operations.yaml
#                                            from the config search path)
#   -z, --partition NAME  partition         (env MU2EDAQ_PARTITION,
#                                            default partition_0)
#   -A, --all             stop every configured partition
#   -k, --kill-session    kill the tmux session instead of waiting for
#                         the ots processes to exit cleanly
#   -t, --timeout SEC     seconds to wait for a clean ots shutdown
#                         (env MU2EDAQ_STOP_TIMEOUT, default 30)
#   -y, --yes             do not ask for confirmation
#   -n, --dry-run         print what would happen, change nothing
#   -h, --help            show this help and exit
#
# See stop-daq.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/scripts/daq-common.sh" "$SCRIPT_DIR/daq-common.sh" \
           "$HOME/bin/daq-common.sh"; do
    # shellcheck source=scripts/daq-common.sh
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "stop-daq.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="stop-daq.sh"
daq_load_dotenv

config="${MU2EDAQ_CONFIG:-}"
partition="${MU2EDAQ_PARTITION:-partition_0}"
timeout="${MU2EDAQ_STOP_TIMEOUT:-30}"
do_all=0
kill_session=0
assume_yes=0
dry_run=0

USAGE="\
usage: $(basename "$0") [-c config] [-z partition] [-A] [-k] [-t sec] [-y] [-n]

Stop the DAQ for one partition, or for all of them with -A.

  -c, --config FILE     operations YAML to read
  -z, --partition NAME  partition to stop (default partition_0)
  -A, --all             stop every configured partition
  -k, --kill-session    kill the tmux session outright
  -t, --timeout SEC     seconds to wait for a clean shutdown (default 30)
  -y, --yes             skip the confirmation prompt
  -n, --dry-run         show what would be done, change nothing
  -h, --help            show this help and exit
"

# Options may also be supplied via $STOP_DAQ_SH_OPTS, or via $STOP_DAQ_OPTS
# and the original $KILL_DAQ_OPTS for compatibility with the pre-rename
# kill_daq script. daq_script_opts derives the legacy name from this
# file's own name, so the kill_daq spelling has to be honoured here.
if [ -z "${STOP_DAQ_SH_OPTS:-}${STOP_DAQ_OPTS:-}" ] && [ -n "${KILL_DAQ_OPTS:-}" ]; then
    STOP_DAQ_SH_OPTS="$KILL_DAQ_OPTS"
fi
# The command substitution is deliberately unquoted: $<COMMAND>_OPTS
# holds a list of options that must be split into separate words.
# shellcheck disable=SC2046
eval set -- $(daq_script_opts stop-daq.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -c|--config)       shift; config="${1:-}";;
        -z|--partition)    shift; partition="${1:-}";;
        -t|--timeout)      shift; timeout="${1:-}";;
        -A|--all)          do_all=1;;
        -k|--kill-session) kill_session=1;;
        -y|--yes)          assume_yes=1;;
        -n|--dry-run)      dry_run=1;;
        -h|--help|-\?)     printf '%s' "$USAGE"; exit 0;;
        --debug)           set -x;;
        *)                 daq_warn "unknown option: $1"
                           printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

command -v tmux >/dev/null 2>&1 || daq_die "tmux is not installed"

config_file="$(daq_config_file daq-operations.yaml "$config")" || exit 1

run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

stop_partition() {
    # Two statements, deliberately: a variable assigned in a 'local' is
    # not yet visible to a later assignment in that same 'local', so
    # session="daq-$target" on one line would expand to just "daq-".
    local target="$1"
    local session="daq-$target"
    local envs env window
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "Partition $target: no tmux session $session, nothing to stop"
        return 0
    fi

    envs="$(daq_read_config --config "$config_file" \
                --partition "$target" active-envs)" || envs=""

    echo "Partition $target: stopping ots in session $session"
    for env in $envs; do
        [ -n "$env" ] || continue
        window="$session-$env"
        if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null \
            | grep -qx "$window"; then
            run tmux send-keys -t "$session:$window" "ots -k" Enter
        else
            echo "  window $window not present, skipping"
        fi
    done

    if [ "$kill_session" -eq 1 ]; then
        run tmux kill-session -t "$session"
        return 0
    fi

    # Give ots a chance to shut down before dropping the session.
    if [ "$dry_run" -eq 0 ]; then
        local waited=0
        while [ "$waited" -lt "$timeout" ]; do
            tmux has-session -t "$session" 2>/dev/null || break
            # Once every window is back to a plain shell, ots is gone.
            if ! tmux list-panes -t "$session" -F '#{pane_current_command}' \
                    2>/dev/null | grep -q '^ots'; then
                break
            fi
            sleep 2
            waited=$(( waited + 2 ))
        done
        [ "$waited" -ge "$timeout" ] && \
            daq_warn "ots still running in $session after ${timeout}s"
    fi
    run tmux kill-session -t "$session"
}

if [ "$do_all" -eq 1 ]; then
    partitions="$(daq_read_config --config "$config_file" partitions)" \
        || daq_die "cannot read the partition list"
    daq_confirm "$assume_yes" "Stop ALL partitions ($partitions)?" || {
        echo "Aborted."; exit 0; }
    for p in $partitions; do
        [ -n "$p" ] || continue
        stop_partition "$p"
    done
else
    daq_confirm "$assume_yes" "Stop partition $partition?" || {
        echo "Aborted."; exit 0; }
    stop_partition "$partition"
fi

[ "$dry_run" -eq 1 ] && echo "Dry run: nothing was stopped."
exit 0
