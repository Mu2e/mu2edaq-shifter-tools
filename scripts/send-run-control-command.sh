#!/usr/bin/env bash
#
# send-run-control-command.sh
#
# Send a run-control state-transition command to the otsdaq gateway
# supervisor of one DAQ environment over UDP.
#
# STATUS: NOT IMPLEMENTED.
#
# The wire format of the otsdaq run-control UDP message is defined by
# the gateway supervisor in otsdaq, and has not been transcribed here.
# The option handling, configuration resolution, and target-port
# calculation below are complete and tested; only the datagram payload
# is missing. See the IMPLEMENTATION NOTES at the bottom of this file
# and send-run-control-command.sh(1).
#
# Until it is implemented, drive state transitions from the otsdaq web
# GUI, reachable through the tunnels opened by daq-tunnels.sh.
#
# Configuration precedence: command line > environment > .env > config file.
#
#   -c, --config FILE       operations YAML  (env MU2EDAQ_CONFIG)
#   -z, --partition NAME    partition        (env MU2EDAQ_PARTITION,
#                                             default partition_0)
#   -e, --environment NAME  target environment (required)
#   -H, --host HOST         gateway host     (env MU2EDAQ_RC_HOST,
#                                             default localhost)
#   -n, --dry-run           print the datagram that would be sent
#   -h, --help              show this help and exit
#
# Commands: init configure start stop pause resume halt

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$SCRIPT_DIR/scripts/daq-common.sh" \
           "$HOME/bin/daq-common.sh"; do
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "send-run-control-command.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="send-run-control-command.sh"
daq_load_dotenv

VALID_COMMANDS="init configure start stop pause resume halt"

config="${MU2EDAQ_CONFIG:-}"
partition="${MU2EDAQ_PARTITION:-partition_0}"
environment="${MU2EDAQ_ENVIRONMENT:-}"
host="${MU2EDAQ_RC_HOST:-localhost}"
dry_run=0

USAGE="\
usage: $(basename "$0") [-c config] [-z partition] -e environment [-H host] [-n] <command>

Send a run-control state transition to one DAQ environment.

  -c, --config FILE       operations YAML to read
  -z, --partition NAME    partition (default partition_0)
  -e, --environment NAME  target environment (required)
  -H, --host HOST         gateway host (default localhost)
  -n, --dry-run           show the datagram, send nothing
  -h, --help              show this help and exit

Commands: $VALID_COMMANDS

NOTE: this command is not implemented yet -- see
send-run-control-command.sh(1). Use the otsdaq web GUI instead.
"

# Options may also be supplied via $SEND_RUN_CONTROL_COMMAND_SH_OPTS.
eval set -- $(daq_script_opts send-run-control-command.sh) '"$@"'

command_verb=""
while [ -n "${1:-}" ]; do
    case "$1" in
        -c|--config)      shift; config="${1:-}";;
        -z|--partition)   shift; partition="${1:-}";;
        -e|--environment) shift; environment="${1:-}";;
        -H|--host)        shift; host="${1:-}";;
        -n|--dry-run)     dry_run=1;;
        -h|--help|-\?)    printf '%s' "$USAGE"; exit 0;;
        --debug)          set -x;;
        -*)               daq_warn "unknown option: $1"
                          printf '%s' "$USAGE" >&2; exit 2;;
        *)                command_verb="$1";;
    esac
    shift
done

[ -n "$environment" ]   || { daq_warn "an environment is required (-e)"
                             printf '%s' "$USAGE" >&2; exit 2; }
[ -n "$command_verb" ]  || { daq_warn "a command is required"
                             printf '%s' "$USAGE" >&2; exit 2; }

case " $VALID_COMMANDS " in
    *" $command_verb "*) ;;
    *) daq_die "unknown command: $command_verb (expected one of: $VALID_COMMANDS)";;
esac

config_file="$(daq_config_file daq-operations.yaml "$config")" || exit 1

# The target port is the partition's ots_port_offset plus the
# environment's port_offset, matching how ots itself is configured.
port="$(daq_read_config --config "$config_file" --partition "$partition" \
           --environment "$environment" gateway-port)" \
    || daq_die "cannot compute the gateway port for $partition/$environment"

echo "Target: $host:$port  ($partition/$environment)"
echo "Command: $command_verb"

if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: no datagram sent (payload format not implemented)."
    exit 0
fi

daq_warn "sending run-control commands is not implemented yet"
daq_warn "use the otsdaq web GUI on $host:$port instead"
exit 3

# ---------------------------------------------------------------------
# IMPLEMENTATION NOTES
#
# What is missing is only the datagram payload. Once the otsdaq gateway
# supervisor's UDP message format is transcribed, the send is a one-liner
# against the already-resolved $host/$port, e.g.
#
#     printf '%s' "$payload" | nc -u -w1 "$host" "$port"
#
# To pin the format down, read the UDP listener in the otsdaq gateway
# supervisor (otsdaq/otsdaq/GatewaySupervisor) and confirm against a
# live instance with -n first. The transitions that need to be covered
# are the ones in $VALID_COMMANDS above.
# ---------------------------------------------------------------------
