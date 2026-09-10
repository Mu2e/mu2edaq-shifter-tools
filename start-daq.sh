#!/usr/bin/env bash
#
# start-daq.sh
#
# Start the Mu2e DAQ for one partition: create a tmux session named
# daq-<partition> with one window per active environment, each running
# setup-online.sh followed by ots.
#
# The venv holding the Python helpers is bootstrapped automatically if
# it is missing, so a fresh checkout can be started with no other setup.
#
# Configuration precedence: command line > environment > .env > config file.
#
#   -c, --config FILE     operations YAML   (env MU2EDAQ_CONFIG,
#                                            default: daq-operations.yaml
#                                            from the config search path)
#   -z, --partition NAME  partition         (env MU2EDAQ_PARTITION,
#                                            default partition_0)
#   -e, --environment ENV start only this environment; repeatable
#   -a, --attach          attach to the session once it is built
#   -n, --dry-run         print what would happen, change nothing
#   -h, --help            show this help and exit
#
# See start-daq.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/scripts/daq-common.sh" "$SCRIPT_DIR/daq-common.sh" \
           "$HOME/bin/daq-common.sh"; do
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "start-daq.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="start-daq.sh"
daq_load_dotenv

config="${MU2EDAQ_CONFIG:-}"
partition="${MU2EDAQ_PARTITION:-partition_0}"
environments=""
attach=0
dry_run=0

USAGE="\
usage: $(basename "$0") [-c config] [-z partition] [-e environment] [-a] [-n]

Start the DAQ for one partition in a tmux session named daq-<partition>.

  -c, --config FILE      operations YAML to read
  -z, --partition NAME   partition to start (default partition_0)
  -e, --environment ENV  start only this environment (repeatable)
  -a, --attach           attach to the tmux session when it is ready
  -n, --dry-run          show what would be done, change nothing
  -h, --help             show this help and exit
"

# Options may also be supplied via $START_DAQ_SH_OPTS.
eval set -- $(daq_script_opts start-daq.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -c|--config)      shift; config="${1:-}";;
        -z|--partition)   shift; partition="${1:-}";;
        -e|--environment) shift; environments="$environments ${1:-}";;
        -a|--attach)      attach=1;;
        -n|--dry-run)     dry_run=1;;
        -h|--help|-\?)    printf '%s' "$USAGE"; exit 0;;
        --debug)          set -x;;
        *)                daq_warn "unknown option: $1"
                          printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

command -v tmux >/dev/null 2>&1 || daq_die "tmux is not installed"

# --- make sure the Python helpers can run -------------------------------
if ! daq_require_python_deps 2>/dev/null; then
    root="$(daq_repo_root)"
    if [ -x "$root/bootstrap.sh" ]; then
        echo "Python dependencies missing; running bootstrap.sh"
        if [ "$dry_run" -eq 1 ]; then
            echo "  + $root/bootstrap.sh"
        else
            "$root/bootstrap.sh" || daq_die "bootstrap.sh failed"
        fi
    else
        daq_die "PyYAML and click are required and bootstrap.sh was not found"
    fi
fi

config_file="$(daq_config_file daq-operations.yaml "$config")" || exit 1
echo "Using configuration $config_file"

if [ -z "${environments// /}" ]; then
    environments="$(daq_read_config --config "$config_file" \
                       --partition "$partition" active-envs)" \
        || daq_die "cannot read active environments for $partition"
fi
[ -n "${environments// /}" ] || daq_die "no active environments for $partition"

session="daq-$partition"

if [ "$dry_run" -eq 0 ] && tmux has-session -t "$session" 2>/dev/null; then
    daq_die "tmux session $session already exists; run stop-daq.sh -z $partition first"
fi

setup_online="$(daq_repo_root)/scripts/setup-online.sh"
[ -f "$setup_online" ] || setup_online="$HOME/bin/setup-online.sh"

run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

echo "Starting DAQ session $session"
# Window 0 is a plain shell kept for the operator; the DAQ environments
# get their own named windows.
run tmux new-session -d -s "$session" -n "$partition-main"

for env in $environments; do
    [ -n "$env" ] || continue
    # Windows are addressed BY NAME here and in stop-daq.sh, so the two
    # scripts do not have to agree on a window ordering.
    window="$session-$env"
    echo "  environment $env -> window $window"
    run tmux new-window -t "$session" -n "$window" \
        "source '$setup_online' -c '$config_file' -z '$partition' -e '$env'; ots; exec bash"
done

if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: nothing was started."
    exit 0
fi

echo ""
echo "Session $session is up. Windows:"
tmux list-windows -t "$session" -F '  #{window_index}: #{window_name}'
echo ""
echo "Attach with:  tmux attach -t $session"
echo "Stop with:    stop-daq.sh -z $partition"

[ "$attach" -eq 1 ] && exec tmux attach -t "$session"
exit 0
