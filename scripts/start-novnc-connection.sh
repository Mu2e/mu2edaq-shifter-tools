#!/usr/bin/env bash
#
# start-novnc-connection.sh
#
# Open an SSH tunnel from a free local port to port 443 on the noVNC
# manager host (mu2e-mgr-01.fnal.gov) as the current user, then launch
# a browser at https://localhost:<localport>. The tunnel stays up until
# you press Ctrl-C (or the ssh session dies), at which point it is torn
# down.
#
# Configuration precedence: command line > environment > default.
#
#   -H, --host HOST        remote host        (env NOVNC_HOST,
#                                              default mu2e-mgr-01.fnal.gov)
#   -u, --user USER        ssh user           (env NOVNC_USER,
#                                              default current user)
#   -p, --port PORT        local port to use  (env NOVNC_LOCAL_PORT,
#                                              default: a free port)
#   -r, --remote-port PORT remote port        (env NOVNC_REMOTE_PORT,
#                                              default 443)
#   -n, --dry-run          print what would happen, do nothing
#   -h, --help             show this help and exit
#
# The browser is chosen from $BROWSER, else xdg-open (Linux), else
# open (macOS).

set -u

host="${NOVNC_HOST:-mu2e-mgr-01.fnal.gov}"
user="${NOVNC_USER:-$(id -un)}"
local_port="${NOVNC_LOCAL_PORT:-}"
remote_port="${NOVNC_REMOTE_PORT:-443}"
dry_run=0

USAGE="\
usage: $(basename "$0") [-H host] [-u user] [-p local_port] [-r remote_port] [-n]

Open an SSH tunnel to port $remote_port on the remote host and launch a
browser pointed at the local end of the tunnel.

  -H, --host HOST         remote host (default mu2e-mgr-01.fnal.gov)
  -u, --user USER         ssh user (default: current user)
  -p, --port PORT         local port (default: an automatically chosen free port)
  -r, --remote-port PORT  remote port (default 443)
  -n, --dry-run           show what would be done, change nothing
  -h, --help              show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -H|--host)        shift; host="${1:-}";;
        -u|--user)        shift; user="${1:-}";;
        -p|--port)        shift; local_port="${1:-}";;
        -r|--remote-port) shift; remote_port="${1:-}";;
        -n|--dry-run)     dry_run=1;;
        -h|--help)        echo "$USAGE"; exit 0;;
        *) echo "Unknown option: $1" >&2; echo "$USAGE" >&2; exit 1;;
    esac
    shift
done

# Find a free TCP port on the loopback interface.
find_free_port() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    else
        # Fallback: scan the ephemeral range for a port nothing answers on.
        local p
        for p in $(seq 20000 20100); do
            if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
                echo "$p"; return 0
            fi
            exec 3>&- 2>/dev/null
        done
        return 1
    fi
}

# Launch the user's browser at the given URL (non-blocking).
open_browser() {
    local url="$1"
    if [ -n "${BROWSER:-}" ]; then
        "$BROWSER" "$url" >/dev/null 2>&1 &
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 &
    else
        echo "No browser launcher found; please open $url manually." >&2
    fi
}

if [ -z "$local_port" ]; then
    local_port=$(find_free_port) || { echo "ERROR: could not find a free local port" >&2; exit 1; }
fi

url="https://localhost:$local_port"

if [ "$dry_run" -eq 1 ]; then
    echo "ssh -N -o ExitOnForwardFailure=yes -L $local_port:localhost:$remote_port $user@$host"
    echo "browser -> $url"
    exit 0
fi

echo "Opening SSH tunnel: localhost:$local_port -> $user@$host:$remote_port"
ssh -N -o ExitOnForwardFailure=yes \
    -L "$local_port:localhost:$remote_port" "$user@$host" &
ssh_pid=$!

# Tear the tunnel down on exit / Ctrl-C.
cleanup() { kill "$ssh_pid" 2>/dev/null; }
trap cleanup EXIT INT TERM

# Wait for the local end of the forward to start accepting connections,
# bailing out if ssh dies first.
for _ in $(seq 1 50); do
    if ! kill -0 "$ssh_pid" 2>/dev/null; then
        echo "ERROR: ssh exited before the tunnel came up" >&2
        exit 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
        exec 3>&-
        break
    fi
    sleep 0.2
done

echo "Launching browser at $url"
open_browser "$url"

echo "Tunnel is up. Press Ctrl-C to close it."
wait "$ssh_pid"
