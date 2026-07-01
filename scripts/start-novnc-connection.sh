#!/usr/bin/env bash
#
# start-novnc-connection.sh
#
# Open an SSH tunnel from a free local port to port 443 on the noVNC
# manager host (mu2e-mgr-01.fnal.gov) as the current user. Once the
# tunnel is up, the plain session-list page served at
# https://localhost:<localport> is scraped and rendered into a
# self-contained, modern-looking "dashboard" HTML page (one card per
# session) which is opened in the browser instead. The tunnel stays up
# until you press Ctrl-C (or the ssh session dies), at which point it
# is torn down and the generated dashboard file is removed.
#
# If a VNC password file is found, each card's link is built with
# noVNC's "password" and "autoconnect=true" query parameters so the
# session connects automatically instead of prompting for a password.
#
# Configuration precedence: command line > environment > default.
#
#   -H, --host HOST         remote host        (env NOVNC_HOST,
#                                               default mu2e-mgr-01.fnal.gov)
#   -u, --user USER         ssh user           (env NOVNC_USER,
#                                               default current user)
#   -p, --port PORT         local port to use  (env NOVNC_LOCAL_PORT,
#                                               default: a free port)
#   -r, --remote-port PORT  remote port        (env NOVNC_REMOTE_PORT,
#                                               default 443)
#   -P, --password-file FILE file holding the  (env NOVNC_PASSWORD_FILE,
#                            VNC password        default ~/.novnc_password)
#                            (first line used)
#   -n, --dry-run           print what would happen, do nothing
#   -h, --help              show this help and exit
#
# The browser is chosen from $BROWSER, else xdg-open (Linux), else
# open (macOS).

set -u

host="${NOVNC_HOST:-mu2e-mgr-01.fnal.gov}"
user="${NOVNC_USER:-$(id -un)}"
local_port="${NOVNC_LOCAL_PORT:-}"
remote_port="${NOVNC_REMOTE_PORT:-443}"
password_file="${NOVNC_PASSWORD_FILE:-$HOME/.novnc_password}"
dry_run=0

USAGE="\
usage: $(basename "$0") [-H host] [-u user] [-p local_port] [-r remote_port] [-P password_file] [-n]

Open an SSH tunnel to port $remote_port on the remote host and launch a
browser pointed at the local end of the tunnel.

  -H, --host HOST          remote host (default mu2e-mgr-01.fnal.gov)
  -u, --user USER          ssh user (default: current user)
  -p, --port PORT          local port (default: an automatically chosen free port)
  -r, --remote-port PORT   remote port (default 443)
  -P, --password-file FILE file whose first line is the VNC password, used to
                           build auto-connecting session links
                           (default ~/.novnc_password; ignored if absent)
  -n, --dry-run            show what would be done, change nothing
  -h, --help               show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -H|--host)          shift; host="${1:-}";;
        -u|--user)          shift; user="${1:-}";;
        -p|--port)          shift; local_port="${1:-}";;
        -r|--remote-port)   shift; remote_port="${1:-}";;
        -P|--password-file) shift; password_file="${1:-}";;
        -n|--dry-run)       dry_run=1;;
        -h|--help)          echo "$USAGE"; exit 0;;
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

# Fetch the noVNC session-list page at $1 and render it into a
# self-contained dashboard HTML file at $2, one card per session link.
# If a password is given as $3, each link is built with noVNC's
# password/autoconnect query parameters so it connects automatically.
# Requires python3; returns non-zero if unavailable or the fetch/parse
# fails, in which case the caller should fall back to the raw page.
render_dashboard() {
    local base_url="$1"
    local out_file="$2"
    local password="${3:-}"

    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "$base_url" "$out_file" "$password" <<'PY'
import html
import ssl
import sys
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urljoin, quote

base_url, out_file = sys.argv[1], sys.argv[2]
password = sys.argv[3] if len(sys.argv) > 3 else ""


class LinkExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self._href = None
        self._text = []
        self._in_a = False

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._in_a = True
            self._href = dict(attrs).get("href")
            self._text = []

    def handle_data(self, data):
        if self._in_a:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._in_a:
            text = "".join(self._text).strip()
            if self._href and text:
                self.links.append((text, self._href))
            self._in_a = False


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

try:
    with urllib.request.urlopen(base_url, timeout=10, context=ctx) as resp:
        body = resp.read().decode("utf-8", errors="replace")
except Exception as exc:
    sys.stderr.write(f"render_dashboard: failed to fetch {base_url}: {exc}\n")
    sys.exit(1)

parser = LinkExtractor()
parser.feed(body)

if not parser.links:
    sys.stderr.write("render_dashboard: no session links found\n")
    sys.exit(1)

cards = []
for name, href in parser.links:
    link = urljoin(base_url, href)
    if password:
        sep = "&" if "?" in link else "?"
        link = f"{link}{sep}password={quote(password, safe='')}&autoconnect=true"
    cards.append(
        '<a class="card" href="{url}" target="_blank" rel="noopener">'
        '<div class="card-icon">&#128421;&#65039;</div>'
        '<div class="card-name">{name}</div>'
        "</a>".format(url=html.escape(link), name=html.escape(name))
    )

page = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>noVNC Sessions</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #0f172a;
    --card-bg: #1e293b;
    --card-hover: #334155;
    --text: #f1f5f9;
    --muted: #94a3b8;
    --accent: #38bdf8;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    min-height: 100vh;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 2.5rem 1.5rem;
  }}
  h1 {{ text-align: center; font-weight: 600; margin-bottom: 0.25rem; }}
  .subtitle {{ text-align: center; color: var(--muted); margin-bottom: 2.5rem; font-size: 0.9rem; }}
  .grid {{
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 1rem;
    max-width: 900px;
    margin: 0 auto;
  }}
  .card {{
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    padding: 1.5rem 1rem;
    background: var(--card-bg);
    border-radius: 12px;
    text-decoration: none;
    color: var(--text);
    transition: transform 0.15s ease, background 0.15s ease;
    border: 1px solid transparent;
  }}
  .card:hover {{ background: var(--card-hover); border-color: var(--accent); transform: translateY(-2px); }}
  .card-icon {{ font-size: 2rem; }}
  .card-name {{ font-weight: 500; word-break: break-word; text-align: center; }}
  footer {{ text-align: center; color: var(--muted); font-size: 0.75rem; margin-top: 3rem; }}
</style>
</head>
<body>
  <h1>noVNC Sessions</h1>
  <div class="subtitle">{base_url}</div>
  <div class="grid">
    {cards}
  </div>
  <footer>Generated by start-novnc-connection.sh</footer>
</body>
</html>
""".format(base_url=html.escape(base_url), cards="\n    ".join(cards))

with open(out_file, "w", encoding="utf-8") as fh:
    fh.write(page)
PY
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

# Tear the tunnel (and any generated dashboard dir) down on exit / Ctrl-C.
dashboard_dir=""
cleanup() {
    kill "$ssh_pid" 2>/dev/null
    [ -n "$dashboard_dir" ] && rm -rf "$dashboard_dir"
}
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

# Try to replace the plain session-list page with a nicer generated
# dashboard. The remote page can take a moment to become reachable
# even after the TCP port itself accepts connections, so retry briefly.
# Use a dedicated temp dir (rather than a templated temp filename) so
# the file keeps a real ".html" extension on every platform -- BSD/macOS
# mktemp does not substitute "XXXXXX" in a -t template, it just appends
# its own random suffix after the literal string, which breaks the
# extension and stops the browser from rendering it as HTML.
dashboard_dir=$(mktemp -d 2>/dev/null) || dashboard_dir=""
dashboard_file=""
open_url="$url"

password=""
if [ -n "$password_file" ] && [ -f "$password_file" ]; then
    perm=$(stat -f "%Lp" "$password_file" 2>/dev/null || stat -c "%a" "$password_file" 2>/dev/null)
    if [ -n "$perm" ] && [ "${perm: -2}" != "00" ]; then
        echo "WARNING: $password_file is readable by group/other; run 'chmod 600 $password_file'" >&2
    fi
    password=$(head -n1 "$password_file")
fi

if [ -n "$dashboard_dir" ]; then
    dashboard_file="$dashboard_dir/dashboard.html"
    built=0
    for _ in $(seq 1 15); do
        if render_dashboard "$url" "$dashboard_file" "$password" 2>/dev/null; then
            built=1
            break
        fi
        sleep 0.3
    done
    if [ "$built" -eq 1 ]; then
        open_url="file://$dashboard_file"
    else
        echo "WARNING: could not build the session dashboard; opening the raw session list instead." >&2
        rm -rf "$dashboard_dir"
        dashboard_dir=""
    fi
fi

echo "Launching browser at $open_url"
open_browser "$open_url"

echo "Tunnel is up. Press Ctrl-C to close it."
wait "$ssh_pid"
