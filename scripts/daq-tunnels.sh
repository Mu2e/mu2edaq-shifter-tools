#!/usr/bin/env bash
#
# daq-tunnels.sh
#
# Open, close, and report the SSH port forwards that the Mu2e shifter
# GUIs are reached through. Two forwarding groups are opened, each in
# its own ssh process so that one failing forward cannot take the other
# group down:
#
#   daq      the otsdaq gateway, DQM and subsystem GUIs on mu2e-cfo-01
#            and mu2e-dl-01, reached through the shift gateway
#   extra    Grafana on mu2e-dcs-01
#
# The pid of each ssh is recorded in a state file so that "stop" can
# terminate exactly the tunnels this command started. That matters: the
# earlier version of this script stopped tunnels with
# "pkill -f 'ssh.*mu2e-'", which also killed the operator's interactive
# ssh sessions to any mu2e host. Pattern matching is still available
# via --all-matching, but it is no longer the default.
#
# Service tables are "label=port[!]:host" lists; ! means the port takes
# no offset. Override them wholesale from the environment if the ports
# move.
#
# Configuration precedence: command line > environment > .env > default.
#
#   -o, --offset N       add N to every forwarded port
#                        (env MU2EDAQ_TUNNEL_OFFSET, default 0)
#   -u, --user USER      ssh user       (env MU2EDAQ_TUNNEL_USER,
#                                        default mu2eshift)
#   -H, --host HOST      host to ssh to (env MU2EDAQ_TUNNEL_HOST,
#                                        default mu2e-dcs-01.fnal.gov)
#   -J, --proxy-jump H   ProxyJump host (env MU2EDAQ_TUNNEL_JUMP,
#                                        default mu2egateway02.fnal.gov;
#                                        "none" disables it)
#   -s, --state FILE     pid state file (env MU2EDAQ_TUNNEL_STATE_SH,
#                                        default ~/.mu2edaq/daq_tunnels)
#   -A, --all-matching   on stop, also pkill any ssh that looks like a
#                        Mu2e tunnel, not just the recorded pids
#   -y, --yes            do not ask for confirmation
#   -n, --dry-run        print what would happen, change nothing
#   -h, --help           show this help and exit
#
# Usage: daq-tunnels.sh [options] {start|stop|restart|status}
#
# See daq-tunnels.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$HOME/bin/daq-common.sh"; do
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "daq-tunnels.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="daq-tunnels.sh"
daq_load_dotenv

# label=port[!]:host  -- ! marks a port that takes no offset.
DEFAULT_DAQ_SERVICES="\
shift=3075:mu2e-cfo-01 \
crv=3085:mu2e-cfo-01 \
calo=3025:mu2e-cfo-01 \
trig=3045:mu2e-cfo-01 \
dqm=5029:mu2e-cfo-01 \
dqmvis=5033:mu2e-dl-01-data \
crvdqm=8877!:mu2e-dl-01 \
cfo=3095:mu2e-cfo-01 \
stm=30351:mu2e-cfo-01 \
trk=3065:mu2e-cfo-01"

DEFAULT_EXTRA_SERVICES="grafana=3000!:mu2e-dcs-01"

daq_services="${MU2EDAQ_TUNNEL_SERVICES:-$DEFAULT_DAQ_SERVICES}"
extra_services="${MU2EDAQ_TUNNEL_EXTRA_SERVICES:-$DEFAULT_EXTRA_SERVICES}"

offset="${MU2EDAQ_TUNNEL_OFFSET:-0}"
user="${MU2EDAQ_TUNNEL_USER:-mu2eshift}"
host="${MU2EDAQ_TUNNEL_HOST:-mu2e-dcs-01.fnal.gov}"
jump="${MU2EDAQ_TUNNEL_JUMP:-mu2egateway02.fnal.gov}"
state_file="${MU2EDAQ_TUNNEL_STATE_SH:-$HOME/.mu2edaq/daq_tunnels}"
all_matching=0
assume_yes=0
dry_run=0
action=""

USAGE="\
usage: $(basename "$0") [options] {start|stop|restart|status}

Manage the SSH port forwards for the Mu2e shifter GUIs.

  -o, --offset N       add N to every forwarded port (default 0)
  -u, --user USER      ssh user (default mu2eshift)
  -H, --host HOST      host to ssh to (default mu2e-dcs-01.fnal.gov)
  -J, --proxy-jump H   ProxyJump host, or none (default mu2egateway02.fnal.gov)
  -s, --state FILE     pid state file (default ~/.mu2edaq/daq_tunnels)
  -A, --all-matching   on stop, also pkill any ssh that looks like a tunnel
  -y, --yes            skip the confirmation prompt
  -n, --dry-run        show what would be done, change nothing
  -h, --help           show this help and exit
"

# Options may also be supplied via $DAQ_TUNNELS_SH_OPTS.
eval set -- $(daq_script_opts daq-tunnels.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        start|stop|restart|status) action="$1";;
        -o|--offset)      shift; offset="${1:-}";;
        -u|--user)        shift; user="${1:-}";;
        -H|--host)        shift; host="${1:-}";;
        -J|--proxy-jump)  shift; jump="${1:-}";;
        -s|--state)       shift; state_file="${1:-}";;
        -A|--all-matching) all_matching=1;;
        -y|--yes)         assume_yes=1;;
        -n|--dry-run)     dry_run=1;;
        -h|--help|-\?)    printf '%s' "$USAGE"; exit 0;;
        --debug)          set -x;;
        -*)               daq_warn "unknown option: $1"
                          printf '%s' "$USAGE" >&2; exit 2;;
        *)                # A bare number is the legacy positional offset.
                          case "$1" in
                              ''|*[!0-9]*) daq_warn "unknown argument: $1"
                                           printf '%s' "$USAGE" >&2; exit 2;;
                              *) offset="$1";;
                          esac;;
    esac
    shift
done

[ -n "$action" ] || action="start"

case "$offset" in
    ''|*[!0-9]*) daq_die "offset must be a non-negative integer: $offset";;
esac

# --- helpers -------------------------------------------------------------

run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

# Expand one service table into ssh -L arguments on stdout, one per line.
forward_args() {
    local table="$1" entry label portspec host_part port
    for entry in $table; do
        label="${entry%%=*}"
        portspec="${entry#*=}"
        host_part="${portspec#*:}"
        portspec="${portspec%%:*}"
        case "$portspec" in
            *!) port="${portspec%!}";;                 # fixed port
            *)  port=$(( portspec + offset ));;        # offset applied
        esac
        [ -n "$label" ] || continue
        printf -- '-L\n%s:%s:%s\n' "$port" "$host_part" "$port"
    done
}

# Read the output of forward_args into the named array. Replaces
# mapfile, which bash 3.2 (the system bash on macOS) does not have.
read_forwards() {
    local name="$1" table="$2" line
    eval "$name=()"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        eval "$name+=(\"\$line\")"
    done < <(forward_args "$table")
}

# Human-readable summary of a service table.
describe_services() {
    local table="$1" entry label portspec port
    for entry in $table; do
        label="${entry%%=*}"
        portspec="${entry#*=}"
        portspec="${portspec%%:*}"
        case "$portspec" in
            *!) port="${portspec%!}";;
            *)  port=$(( portspec + offset ));;
        esac
        printf '    %-10s localhost:%s\n' "$label" "$port"
    done
}

record_pid() {
    local group="$1" pid="$2"
    [ "$dry_run" -eq 1 ] && return 0
    mkdir -p "$(dirname "$state_file")"
    printf '%s, %s, %s, %s\n' "$pid" "$group" "$host" "$offset" >> "$state_file"
}

# The ssh processes are backgrounded by ssh itself (-f), so the pid we
# get from $! is the parent that immediately exits. Find the surviving
# child by matching the forward list instead.
find_ssh_pid() {
    local marker="$1"
    pgrep -f "ssh.*$marker" 2>/dev/null | head -1
}

stop_recorded() {
    local killed=0 pid group thehost theoffset
    if [ ! -f "$state_file" ]; then
        echo "  no recorded tunnels in $state_file"
        return 0
    fi
    while IFS=, read -r pid group thehost theoffset; do
        pid="$(printf '%s' "$pid" | tr -d '[:space:]')"
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            run kill "$pid"
            killed=$(( killed + 1 ))
        else
            echo "  pid $pid (${group# }) already gone"
        fi
    done < "$state_file"
    [ "$dry_run" -eq 1 ] || : > "$state_file"
    echo "  stopped $killed recorded tunnel(s)"
}

stop_matching() {
    echo "  also killing any ssh matching the Mu2e tunnel patterns"
    local pattern
    for pattern in "ssh.*mu2egateway" "ssh.*mu2e-cfo" "ssh.*mu2e-dl" \
                   "ssh.*mu2e-dcs"; do
        run pkill -f "$pattern" || true
    done
}

# --- actions -------------------------------------------------------------

case "$action" in
    status)
        echo "Recorded tunnels ($state_file):"
        if [ -f "$state_file" ] && [ -s "$state_file" ]; then
            while IFS=, read -r pid group thehost theoffset; do
                pid="$(printf '%s' "$pid" | tr -d '[:space:]')"
                [ -n "$pid" ] || continue
                if kill -0 "$pid" 2>/dev/null; then
                    printf '  pid %-8s %-8s %s (offset%s) ACTIVE\n' \
                        "$pid" "${group# }" "${thehost# }" "$theoffset"
                else
                    printf '  pid %-8s %-8s %s (offset%s) DEAD\n' \
                        "$pid" "${group# }" "${thehost# }" "$theoffset"
                fi
            done < "$state_file"
        else
            echo "  none"
        fi
        echo ""
        echo "ssh processes that look like Mu2e tunnels:"
        ps aux | grep -E "ssh.*(mu2e|cfo|dl|dcs)" | grep -v grep \
            || echo "  none"
        echo ""
        echo "Locally bound forwards:"
        if command -v lsof >/dev/null 2>&1; then
            lsof -i -P -n 2>/dev/null | grep ssh | grep LISTEN || echo "  none"
        else
            echo "  (lsof is not installed)"
        fi
        ;;

    stop)
        daq_confirm "$assume_yes" "Stop the Mu2e shifter tunnels?" || {
            echo "Aborted."; exit 0; }
        echo "Stopping tunnels..."
        stop_recorded
        [ "$all_matching" -eq 1 ] && stop_matching
        echo "  Done"
        ;;

    start)
        # Clear anything we started previously, so ports are free.
        if [ -f "$state_file" ] && [ -s "$state_file" ]; then
            echo "Clearing previously recorded tunnels..."
            stop_recorded
            [ "$dry_run" -eq 1 ] || sleep 1
        fi

        if [ "$dry_run" -eq 0 ] && ! klist -s 2>/dev/null; then
            daq_die "no valid Kerberos ticket; run kinit first"
        fi

        jump_args=()
        if [ -n "$jump" ] && [ "$jump" != "none" ]; then
            jump_args=(-J "$user@$jump")
        fi

        echo "Starting DAQ tunnels (offset=$offset, via ${jump:-none})..."
        describe_services "$daq_services"

        read_forwards daq_forwards "$daq_services"
        if [ "$dry_run" -eq 1 ]; then
            echo "  + ssh -f -K -N -q -o ExitOnForwardFailure=yes" \
                 "${jump_args[@]+${jump_args[@]}}" \
                 "${daq_forwards[@]}" "$user@$host"
        else
            if ssh -f -K -N -q -o ExitOnForwardFailure=yes \
                "${jump_args[@]+${jump_args[@]}}" \
                "${daq_forwards[@]}" "$user@$host" >/dev/null 2>&1; then
                echo "  DAQ: OK"
                record_pid daq "$(find_ssh_pid "${daq_forwards[1]}")"
            else
                echo "  DAQ: FAILED" >&2
            fi
        fi

        echo "Starting extra tunnels..."
        describe_services "$extra_services"

        read_forwards extra_forwards "$extra_services"
        if [ "$dry_run" -eq 1 ]; then
            echo "  + ssh -f -K -N -q -o ExitOnForwardFailure=yes" \
                 "${jump_args[@]+${jump_args[@]}}" \
                 "${extra_forwards[@]}" "$user@$host"
            echo "Dry run: no tunnels were opened."
        else
            if ssh -f -K -N -q -o ExitOnForwardFailure=yes \
                "${jump_args[@]+${jump_args[@]}}" \
                "${extra_forwards[@]}" "$user@$host" >/dev/null 2>&1; then
                echo "  Extra: OK"
                record_pid extra "$(find_ssh_pid "${extra_forwards[1]}")"
            else
                echo "  Extra: FAILED" >&2
            fi
        fi
        ;;

    restart)
        "$0" ${dry_run:+-n} ${assume_yes:+-y} -s "$state_file" stop
        "$0" ${dry_run:+-n} -o "$offset" -u "$user" -H "$host" \
             -J "$jump" -s "$state_file" start
        ;;
esac

exit 0
