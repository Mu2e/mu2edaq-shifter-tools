#!/usr/bin/env bash
#
# manage-vnc-servers.sh
#
# Start, stop, or restart the VNC servers running on the noVNC manager
# host (mu2e-mgr-01.fnal.gov). Connects over ssh as the mu2ecr01 user
# and runs "systemctl <action> vncserver@:<port>.service" for each of
# the configured display ports (default: 4 through 9).
#
# Restarting/stopping these services disconnects anyone currently
# using that display, so by default the script asks for confirmation
# before doing anything. Pass -y/--yes to skip the prompt.
#
# Configuration precedence: command line > environment > default.
#
#   -H, --host HOST    remote host          (env VNC_HOST,
#                                            default mu2e-mgr-01.fnal.gov)
#   -u, --user USER    ssh user             (env VNC_USER,
#                                            default mu2ecr01)
#   -P, --ports PORTS  space/comma-separated (env VNC_PORTS,
#                       list of display        default "4 5 6 7 8 9")
#                       numbers
#   -y, --yes          skip confirmation prompt
#   -n, --dry-run      print what would happen, do nothing
#   -h, --help         show this help and exit
#
# Usage: manage-vnc-servers.sh {start|stop|restart} [options]

set -u

host="${VNC_HOST:-mu2e-mgr-01.fnal.gov}"
user="${VNC_USER:-mu2ecr01}"
ports="${VNC_PORTS:-4 5 6 7 8 9}"
assume_yes=0
dry_run=0
action=""

USAGE="\
usage: $(basename "$0") {start|stop|restart} [-H host] [-u user] [-P ports] [-y] [-n]

Start, stop, or restart the VNC servers on $host by running
systemctl <action> vncserver@:<port>.service over ssh as \$user, for
each port in \$ports.

  -H, --host HOST    remote host (default mu2e-mgr-01.fnal.gov)
  -u, --user USER    ssh user (default mu2ecr01)
  -P, --ports PORTS  space/comma-separated display ports (default \"4 5 6 7 8 9\")
  -y, --yes          skip the confirmation prompt
  -n, --dry-run      show what would be done, change nothing
  -h, --help         show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        start|stop|restart) action="$1";;
        -H|--host)  shift; host="${1:-}";;
        -u|--user)  shift; user="${1:-}";;
        -P|--ports) shift; ports="${1:-}";;
        -y|--yes)   assume_yes=1;;
        -n|--dry-run) dry_run=1;;
        -h|--help)  echo "$USAGE"; exit 0;;
        *) echo "Unknown option: $1" >&2; echo "$USAGE" >&2; exit 1;;
    esac
    shift
done

if [ -z "$action" ]; then
    echo "ERROR: an action (start|stop|restart) is required" >&2
    echo "$USAGE" >&2
    exit 1
fi

# Normalize comma/space separated port list into an array, validating
# that every entry is numeric.
port_list=()
old_ifs="$IFS"
IFS=', '
for p in $ports; do
    case "$p" in
        ''|*[!0-9]*) echo "ERROR: invalid port '$p' in port list" >&2; exit 1;;
    esac
    port_list+=("$p")
done
IFS="$old_ifs"

if [ "${#port_list[@]}" -eq 0 ]; then
    echo "ERROR: no ports given" >&2
    exit 1
fi

echo "This will run 'systemctl $action vncserver@:<port>.service' on"
echo "$user@$host for ports: ${port_list[*]}"

if [ "$dry_run" -eq 1 ]; then
    for p in "${port_list[@]}"; do
        echo "ssh $user@$host \"systemctl $action vncserver@:$p.service\""
    done
    exit 0
fi

if [ "$assume_yes" -ne 1 ]; then
    if [ -t 0 ]; then
        read -r -p "Continue? [y/N] " reply
        case "$reply" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 1;;
        esac
    else
        echo "ERROR: not running interactively; pass -y/--yes to confirm" >&2
        exit 1
    fi
fi

# Build one remote script that runs systemctl for every port in a
# single ssh session, reporting success/failure per port.
remote_script=""
for p in "${port_list[@]}"; do
    remote_script+="if systemctl $action vncserver@:$p.service; then echo ':$p -> OK'; else echo ':$p -> FAILED'; fi; "
done

ssh "$user@$host" "$remote_script"
exit $?
