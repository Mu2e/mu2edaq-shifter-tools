#!/usr/bin/env bash
#
# daq-status.sh
#
# Report the state of the configured DAQ partitions: for each partition
# and each of its active environments, whether start-daq.sh has built a
# tmux window for it and whether ots is currently the running command in
# that window.
#
# This is a read-only report; it never touches a running partition.
#
# Configuration precedence: command line > environment > .env > config file.
#
#   -c, --config FILE     operations YAML  (env MU2EDAQ_CONFIG,
#                                           default: daq-operations.yaml
#                                           from the config search path)
#   -z, --partition NAME  report only this partition
#                                          (env MU2EDAQ_PARTITION)
#   -j, --json            emit JSON instead of a table
#   -q, --quiet           print nothing; exit 0 if every active
#                         environment is running, 1 otherwise
#   -h, --help            show this help and exit
#
# See daq-status.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$SCRIPT_DIR/scripts/daq-common.sh" \
           "$HOME/bin/daq-common.sh"; do
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "daq-status.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="daq-status.sh"
daq_load_dotenv

config="${MU2EDAQ_CONFIG:-}"
partition="${MU2EDAQ_PARTITION:-}"
as_json=0
quiet=0

USAGE="\
usage: $(basename "$0") [-c config] [-z partition] [-j] [-q]

Report which DAQ partitions and environments are running.

  -c, --config FILE     operations YAML to read
  -z, --partition NAME  report only this partition
  -j, --json            emit JSON instead of a table
  -q, --quiet           print nothing; exit 0 only if all are running
  -h, --help            show this help and exit
"

# Options may also be supplied via $DAQ_STATUS_SH_OPTS.
eval set -- $(daq_script_opts daq-status.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -c|--config)    shift; config="${1:-}";;
        -z|--partition) shift; partition="${1:-}";;
        -j|--json)      as_json=1;;
        -q|--quiet)     quiet=1;;
        -h|--help|-\?)  printf '%s' "$USAGE"; exit 0;;
        --debug)        set -x;;
        *)              daq_warn "unknown option: $1"
                        printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

command -v tmux >/dev/null 2>&1 || daq_die "tmux is not installed"

config_file="$(daq_config_file daq-operations.yaml "$config")" || exit 1

if [ -n "$partition" ]; then
    partitions="$partition"
else
    partitions="$(daq_read_config --config "$config_file" partitions)" \
        || daq_die "cannot read the partition list"
fi

# Classify one environment as RUNNING / STOPPED / NO-SESSION.
env_state() {
    local session="$1" window="$2"
    if ! tmux has-session -t "$session" 2>/dev/null; then
        printf 'NO-SESSION\n'; return
    fi
    if ! tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null \
        | grep -qx "$window"; then
        printf 'NO-WINDOW\n'; return
    fi
    if tmux list-panes -t "$session:$window" -F '#{pane_current_command}' \
        2>/dev/null | grep -q '^ots'; then
        printf 'RUNNING\n'
    else
        printf 'STOPPED\n'
    fi
}

all_running=1
rows=""

for p in $partitions; do
    [ -n "$p" ] || continue
    session="daq-$p"
    envs="$(daq_read_config --config "$config_file" --partition "$p" \
                active-envs 2>/dev/null)" || envs=""
    if [ -z "${envs// /}" ]; then
        rows="$rows$p|(none configured)|$session|N/A
"
        continue
    fi
    for e in $envs; do
        [ -n "$e" ] || continue
        window="$session-$e"
        state="$(env_state "$session" "$window")"
        [ "$state" = "RUNNING" ] || all_running=0
        rows="$rows$p|$e|$window|$state
"
    done
done

if [ "$quiet" -eq 1 ]; then
    [ "$all_running" -eq 1 ] && exit 0 || exit 1
fi

if [ "$as_json" -eq 1 ]; then
    printf '{\n  "config": "%s",\n  "environments": [\n' "$config_file"
    first=1
    printf '%s' "$rows" | while IFS='|' read -r p e w s; do
        [ -n "$p" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {"partition": "%s", "environment": "%s", "window": "%s", "state": "%s"}' \
            "$p" "$e" "$w" "$s"
    done
    printf '\n  ]\n}\n'
    exit 0
fi

echo "Configuration: $config_file"
echo ""
printf '%-14s %-14s %-26s %s\n' "PARTITION" "ENVIRONMENT" "TMUX WINDOW" "STATE"
printf '%-14s %-14s %-26s %s\n' "---------" "-----------" "-----------" "-----"
printf '%s' "$rows" | while IFS='|' read -r p e w s; do
    [ -n "$p" ] || continue
    printf '%-14s %-14s %-26s %s\n' "$p" "$e" "$w" "$s"
done

echo ""
echo "Live tmux sessions:"
tmux list-sessions -F '  #{session_name}: #{session_windows} window(s), created #{t:session_created}' \
    2>/dev/null | grep '  daq-' || echo "  none"

exit 0
