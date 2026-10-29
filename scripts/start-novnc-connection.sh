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
# Each card shows the login account, the host it connects to and a
# description, taken from novnc-sessions.yaml (see novnc-sessions.yaml(5)).
# The order of that file is the order of the cards; sessions the portal
# lists but the file does not follow, in the portal's order. Reading the
# file needs PyYAML; without it, or without the file, the cards are shown
# in portal order with no descriptions.
#
# For every session the file gives a display for (on the tunnel host),
# the same ssh also forwards a free local port to that session's VNC
# port, 5900+display, so the card can offer a native viewer link,
# vnc://localhost:<port> (macOS opens it in Screen Sharing). The page
# shows each forward and the portal tunnel it belongs to.
#
# Configuration precedence: command line > environment > .env > default.
#
#   -H, --host HOST         remote host        (env NOVNC_HOST,
#                                               default mu2e-mgr-01.fnal.gov)
#   -u, --user USER         ssh user           (env NOVNC_USER,
#                                               default current user)
#   -J, --proxy-jump HOST   ProxyJump host     (env NOVNC_PROXY_JUMP,
#                            "none" disables    default mu2egateway01.fnal.gov
#                                               when the remote host is
#                                               mu2e-mgr-01.fnal.gov, else none)
#   -p, --port PORT         local port to use  (env NOVNC_LOCAL_PORT,
#                                               default: a free port)
#   -r, --remote-port PORT  remote port        (env NOVNC_REMOTE_PORT,
#                                               default 443)
#   -P, --password-file FILE file holding the  (env NOVNC_PASSWORD_FILE,
#                            VNC password        default ~/.novnc_password)
#                            (first line used)
#   -c, --sessions FILE     session descriptions (env NOVNC_SESSIONS_FILE,
#                            and card order         default novnc-sessions.yaml
#                                                   on the config search path)
#       --no-native         no native VNC forwards (env NOVNC_NATIVE=0)
#   -n, --dry-run           print what would happen, do nothing
#   -h, --help              show this help and exit
#
# The browser is chosen from $BROWSER, else xdg-open (Linux), else
# open (macOS).

set -u

# Load the .env tier if the shared library is reachable. It is optional
# here on purpose: this script must keep working when copied to a laptop
# on its own, with nothing but bash and ssh.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$HOME/bin/daq-common.sh"; do
    # shellcheck source=scripts/daq-common.sh
    [ -f "$lib" ] && { . "$lib"; break; }
done
command -v daq_load_dotenv >/dev/null 2>&1 && daq_load_dotenv

default_host="mu2e-mgr-01.fnal.gov"
default_proxy_jump="mu2egateway01.fnal.gov"

host="${NOVNC_HOST:-$default_host}"
user="${NOVNC_USER:-$(id -un)}"
proxy_jump="${NOVNC_PROXY_JUMP:-}"
proxy_jump_set=0
[ -n "${NOVNC_PROXY_JUMP+x}" ] && proxy_jump_set=1
local_port="${NOVNC_LOCAL_PORT:-}"
remote_port="${NOVNC_REMOTE_PORT:-443}"
password_file="${NOVNC_PASSWORD_FILE:-$HOME/.novnc_password}"
sessions_file="${NOVNC_SESSIONS_FILE:-}"
native="${NOVNC_NATIVE:-1}"
dry_run=0

USAGE="\
usage: $(basename "$0") [-H host] [-u user] [-J proxy_jump] [-p local_port] [-r remote_port] [-P password_file] [-c sessions_file] [--no-native] [-n]

Open an SSH tunnel to port $remote_port on the remote host and launch a
browser pointed at the local end of the tunnel.

  -H, --host HOST          remote host (default $default_host)
  -u, --user USER          ssh user (default: current user)
  -J, --proxy-jump HOST    ssh ProxyJump host; \"none\" disables it
                           (default $default_proxy_jump when the remote
                           host is $default_host, otherwise none)
  -p, --port PORT          local port (default: an automatically chosen free port)
  -r, --remote-port PORT   remote port (default 443)
  -P, --password-file FILE file whose first line is the VNC password, used to
                           build auto-connecting session links
                           (default ~/.novnc_password; ignored if absent)
  -c, --sessions FILE      YAML file of session descriptions and card order
                           (default novnc-sessions.yaml on the config search
                           path; ignored if absent; needs PyYAML)
      --no-native          do not forward each session's VNC port for the
                           native viewer links
  -n, --dry-run            show what would be done, change nothing
  -h, --help               show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -H|--host)          shift; host="${1:-}";;
        -u|--user)          shift; user="${1:-}";;
        -J|--proxy-jump)    shift; proxy_jump="${1:-}"; proxy_jump_set=1;;
        -p|--port)          shift; local_port="${1:-}";;
        -r|--remote-port)   shift; remote_port="${1:-}";;
        -P|--password-file) shift; password_file="${1:-}";;
        -c|--sessions)      shift; sessions_file="${1:-}";;
        --no-native)        native=0;;
        -n|--dry-run)       dry_run=1;;
        -h|--help)          echo "$USAGE"; exit 0;;
        *) echo "Unknown option: $1" >&2; echo "$USAGE" >&2; exit 1;;
    esac
    shift
done

# Default the ProxyJump host when tunnelling to the stock manager host
# and the user has not said otherwise; "none" (or empty) disables it.
if [ "$proxy_jump_set" -eq 0 ] && [ "$host" = "$default_host" ]; then
    proxy_jump="$default_proxy_jump"
fi
[ "$proxy_jump" = "none" ] && proxy_jump=""

jump_opts=()
[ -n "$proxy_jump" ] && jump_opts=(-J "$proxy_jump")

# Session descriptions and card order. An explicit file must exist; the
# default is optional, looked for on the toolkit's config search path
# when daq-common.sh is available, else beside this script's checkout.
if [ -n "$sessions_file" ]; then
    case "$sessions_file" in "~/"*) sessions_file="$HOME/${sessions_file#'~/'}";; esac
    [ -f "$sessions_file" ] || { echo "ERROR: sessions file not found: $sessions_file" >&2; exit 1; }
elif command -v daq_config_file >/dev/null 2>&1; then
    sessions_file=$(daq_config_file novnc-sessions.yaml 2>/dev/null) || sessions_file=""
elif [ -f "$SCRIPT_DIR/../config/novnc-sessions.yaml" ]; then
    sessions_file="$SCRIPT_DIR/../config/novnc-sessions.yaml"
fi

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

# plan_native_forwards SESSIONS_FILE TUNNEL_HOST AVOID_PORT
#
# Print "account display local_port" for every session in the sessions
# file that has a display and runs on the tunnel host (Xvnc listens on
# that host's loopback only, so a forward through it cannot reach
# another host's sessions). Local ports are free ports, all held open
# at once while choosing so no two are the same, and never AVOID_PORT.
# Prints nothing, after one warning, when PyYAML is missing; problems
# with the file itself are left to the renderer to report.
plan_native_forwards() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$1" "$2" "$3" <<'PY'
import socket
import sys

path, tunnel_host, avoid = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml
except ImportError:
    sys.stderr.write("WARNING: PyYAML is not installed, so no native VNC links\n")
    sys.exit(0)
try:
    with open(path, encoding="utf-8") as fh:
        entries = (yaml.safe_load(fh) or {}).get("sessions") or []
except Exception:
    sys.exit(0)

wanted = []
for entry in entries:
    if not isinstance(entry, dict) or not entry.get("account"):
        continue
    display = entry.get("display")
    if isinstance(display, bool) or not isinstance(display, int) or display < 0:
        continue
    if entry.get("host") and str(entry["host"]) != tunnel_host:
        continue
    wanted.append((str(entry["account"]), display))

held = []
try:
    for account, display in wanted:
        while True:
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            if str(s.getsockname()[1]) != avoid:
                break
            s.close()
        held.append(s)
        print(account, display, s.getsockname()[1])
finally:
    for s in held:
        s.close()
PY
}

# Fetch the noVNC session-list page at $1 and render it into a
# self-contained dashboard HTML file at $2, one card per session link.
# If a password is given as $3, each link is built with noVNC's
# password/autoconnect query parameters so it connects automatically.
# $4 is the sessions file (descriptions and card order; may be empty)
# and $5 the host the tunnel reaches, shown on every card unless the
# sessions file names another. $6-$9 describe the tunnel (ssh user, jump
# host, remote port, ssh pid) for the tunnel panel, and $10 lists the
# native VNC forwards as "account=local_port:display ...".
# Requires python3; returns non-zero if unavailable or the fetch/parse
# fails, in which case the caller should fall back to the raw page.
# Problems with the sessions file are warnings, never failures.
render_dashboard() {
    local base_url="$1"
    local out_file="$2"
    local password="${3:-}"
    local sessions="${4:-}"
    local default_host="${5:-}"

    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "$base_url" "$out_file" "$password" "$sessions" "$default_host" \
        "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" <<'PY'
import html
import ssl
import sys
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urljoin, quote, urlparse

(base_url, out_file, password, sessions_file, default_host,
 ssh_user, jump, remote_port, ssh_pid, native_spec) = (sys.argv[1:11] + [""] * 10)[:10]
portal_port = urlparse(base_url).port or ""
portal_port = str(portal_port)

# "account=local_port:display ..." -> {account: (local_port, display)}
native = {}
for item in native_spec.split():
    account, _, rest = item.partition("=")
    lport, _, disp = rest.partition(":")
    if account and lport.isdigit() and disp.isdigit():
        native[account] = (lport, disp)


def warn(message):
    sys.stderr.write("WARNING: " + message + "\n")


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


def load_sessions(path):
    """Return the sessions file as an ordered list of dicts keyed by
    account. Any problem is a warning and yields an empty list, so the
    dashboard still renders."""
    if not path:
        return []
    try:
        import yaml
    except ImportError:
        warn(
            "PyYAML is not installed, so %s is ignored and the cards have no "
            "descriptions. Install it with: python3 -m pip install --user pyyaml" % path
        )
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception as exc:
        warn("cannot read %s: %s" % (path, exc))
        return []
    entries = data.get("sessions") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        warn("%s has no 'sessions:' list; ignoring it" % path)
        return []
    sessions = []
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict) or not entry.get("account"):
            warn("%s: sessions[%d] has no 'account'; skipping it" % (path, i))
            continue
        sessions.append(entry)
    return sessions


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

# Order: the sessions file first, then whatever else the portal lists,
# in the portal's order. File entries the portal does not list are
# reported, not drawn, since there is no link for them.
sessions = load_sessions(sessions_file)
portal = dict(parser.links)
ordered = []
for entry in sessions:
    account = str(entry["account"])
    if account in portal:
        ordered.append((account, portal.pop(account), entry))
    else:
        warn("%s lists '%s', which the portal does not offer" % (sessions_file, account))
for account, href in parser.links:
    if account in portal:
        ordered.append((account, href, {}))

cards = []
for name, href, entry in ordered:
    link = urljoin(base_url, href)
    if password:
        sep = "&" if "?" in link else "?"
        link = f"{link}{sep}password={quote(password, safe='')}&autoconnect=true"
    host = str(entry.get("host") or default_host)
    display = entry.get("display")
    forward = native.get(name)
    if forward and display in (None, ""):
        display = forward[1]
    where = host + (":%s" % display if display not in (None, "") else "")
    description = str(entry.get("description") or "").strip()

    if forward:
        lport, disp = forward
        vnc_url = "vnc://localhost:%s" % lport
        native_btn = '<a class="btn" href="{u}" title="Opens the native viewer (Screen Sharing on macOS)">Native VNC</a>'.format(
            u=html.escape(vnc_url)
        )
        native_line = (
            '<div class="tun-row"><span class="tun-key">native</span>'
            "<code>localhost:{lp}</code> &rarr; <code>{h}:{rp}</code></div>"
            '<div class="tun-row"><span class="tun-key">open</span>'
            '<code class="sel">open {u}</code></div>'
        ).format(lp=lport, h=html.escape(host), rp=5900 + int(disp), u=html.escape(vnc_url))
    else:
        reason = "no display configured" if display in (None, "") else "not forwarded"
        native_btn = '<span class="btn btn-off" title="{r}">Native VNC</span>'.format(r=reason)
        native_line = (
            '<div class="tun-row"><span class="tun-key">native</span>'
            '<span class="muted">{r}</span></div>'
        ).format(r=reason)

    cards.append(
        '<div class="card">'
        '<a class="card-main" href="{url}" target="_blank" rel="noopener">'
        '<div class="card-icon">&#128421;&#65039;</div>'
        '<div class="card-name">{name}</div>'
        '<div class="card-host">{where}</div>'
        '<div class="card-desc{empty}">{desc}</div>'
        "</a>"
        '<div class="card-actions">'
        '<a class="btn" href="{url}" target="_blank" rel="noopener">Browser (noVNC)</a>'
        "{native_btn}"
        "</div>"
        # <details> without "open": collapsed until clicked, no script needed.
        '<details class="card-tunnel">'
        "<summary>Tunnel details</summary>"
        '<div class="tun-body">'
        '<div class="tun-row"><span class="tun-key">noVNC</span>'
        "<code>localhost:{pport}</code> &rarr; <code>{thost}:{rport}</code></div>"
        "{native_line}"
        "</div>"
        "</details>"
        "</div>".format(
            url=html.escape(link),
            name=html.escape(name),
            where=html.escape(where),
            empty="" if description else " card-desc-none",
            desc=html.escape(description) if description else "no description configured",
            native_btn=native_btn,
            native_line=native_line,
            pport=html.escape(portal_port),
            thost=html.escape(default_host),
            rport=html.escape(remote_port),
        )
    )

ssh_cmd = "ssh -N%s -L %s:localhost:%s%s %s@%s" % (
    " -J " + jump if jump else "",
    portal_port,
    remote_port,
    "".join(" -L %s:localhost:%d" % (lp, 5900 + int(d)) for lp, d in native.values()),
    ssh_user,
    default_host,
)
tunnel_panel = (
    '<section class="tunnel">'
    '<div class="tun-title">Tunnel</div>'
    '<div class="tun-grid">'
    '<span class="tun-key">ssh</span><span><code>{who}@{thost}</code>{via}{pid}</span>'
    '<span class="tun-key">noVNC</span><span><code>localhost:{pport}</code> &rarr; '
    "<code>{thost}:{rport}</code> (portal)</span>"
    '<span class="tun-key">native</span><span>{nat}</span>'
    '<span class="tun-key">command</span><span><code class="sel">{cmd}</code></span>'
    "</div>"
    '<div class="tun-note">These forwards exist only while start-novnc-connection.sh '
    "is running in your terminal; Ctrl-C there closes all of them.</div>"
    "</section>"
).format(
    who=html.escape(ssh_user),
    thost=html.escape(default_host),
    via=(" via <code>%s</code>" % html.escape(jump)) if jump else "",
    pid=(" &middot; pid %s" % html.escape(ssh_pid)) if ssh_pid else "",
    pport=html.escape(portal_port),
    rport=html.escape(remote_port),
    nat=(
        "%d session(s), one local port each to <code>%s:59xx</code>"
        % (len(native), html.escape(default_host))
        if native
        else '<span class="muted">none (no displays in the sessions file, or --no-native)</span>'
    ),
    cmd=html.escape(ssh_cmd),
)

page = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>Mu2eDAQ noVNC Sessions</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>&#128421;&#65039;</text></svg>" />
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
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 1rem;
    max-width: 1100px;
    margin: 0 auto;
  }}
  .card {{
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1.25rem 1rem 1rem;
    background: var(--card-bg);
    border-radius: 12px;
    border: 1px solid transparent;
    transition: background 0.15s ease, border-color 0.15s ease;
  }}
  .card:hover {{ background: var(--card-hover); border-color: var(--accent); }}
  .card-main {{
    display: flex; flex-direction: column; align-items: center; gap: 0.4rem;
    text-decoration: none; color: var(--text);
  }}
  .card-actions {{ display: flex; gap: 0.5rem; justify-content: center; flex-wrap: wrap; }}
  .btn {{
    font-size: 0.8rem; padding: 0.35rem 0.7rem; border-radius: 6px;
    border: 1px solid var(--accent); color: var(--accent); text-decoration: none;
  }}
  .btn:hover {{ background: var(--accent); color: var(--bg); }}
  .btn-off {{ border-color: var(--muted); color: var(--muted); opacity: 0.6; cursor: not-allowed; }}
  .btn-off:hover {{ background: transparent; color: var(--muted); }}
  .card-tunnel {{ border-top: 1px solid var(--card-hover); padding-top: 0.5rem; font-size: 0.75rem; }}
  .card-tunnel > summary {{ cursor: pointer; color: var(--muted); font-size: 0.7rem; letter-spacing: 0.05em; text-transform: uppercase; }}
  .card-tunnel > summary:hover, .card-tunnel[open] > summary {{ color: var(--accent); }}
  .card-tunnel > summary:focus-visible {{ outline: 1px solid var(--accent); outline-offset: 2px; }}
  .tun-body {{ display: grid; gap: 0.25rem; margin-top: 0.5rem; }}
  .tun-row {{ display: flex; gap: 0.4rem; align-items: baseline; flex-wrap: wrap; min-width: 0; }}
  .tun-key {{ color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; font-size: 0.65rem; min-width: 3.6rem; }}
  code {{ font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 0.75rem; word-break: break-all; }}
  .sel {{ user-select: all; }}
  .muted {{ color: var(--muted); }}
  .tunnel {{
    max-width: 1100px; margin: 0 auto 2rem; padding: 1rem 1.25rem;
    background: var(--card-bg); border-radius: 12px; border: 1px solid var(--card-hover);
  }}
  .tun-title {{ font-weight: 600; margin-bottom: 0.6rem; }}
  .tun-grid {{ display: grid; grid-template-columns: max-content 1fr; gap: 0.35rem 1rem; font-size: 0.85rem; min-width: 0; }}
  .tun-grid > span {{ min-width: 0; }}
  .tun-note {{ color: var(--muted); font-size: 0.75rem; margin-top: 0.7rem; }}
  .card-icon {{ font-size: 2rem; }}
  .card-name {{ font-weight: 600; word-break: break-word; text-align: center; }}
  .card-host {{ font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 0.8rem; color: var(--accent); word-break: break-all; text-align: center; }}
  .card-desc {{ font-size: 0.85rem; color: var(--muted); text-align: center; line-height: 1.35; }}
  .card-desc-none {{ font-style: italic; opacity: 0.7; }}
  footer {{ text-align: center; color: var(--muted); font-size: 0.75rem; margin-top: 3rem; }}
</style>
</head>
<body>
  <h1>Mu2eDAQ noVNC Sessions</h1>
  <div class="subtitle">Mu2eDAQ &middot; {base_url}</div>
  {tunnel}
  <div class="grid">
    {cards}
  </div>
  <footer>Generated by start-novnc-connection.sh{source}</footer>
</body>
</html>
""".format(
    base_url=html.escape(base_url),
    cards="\n    ".join(cards),
    tunnel=tunnel_panel,
    source=(" from " + html.escape(sessions_file)) if sessions else "",
)

with open(out_file, "w", encoding="utf-8") as fh:
    fh.write(page)
PY
}

if [ -z "$local_port" ]; then
    local_port=$(find_free_port) || { echo "ERROR: could not find a free local port" >&2; exit 1; }
fi

url="https://localhost:$local_port"

# Native VNC forwards, carried by the same ssh as the portal tunnel.
# native_map is "account=local_port:display ..." for the renderer.
native_opts=()
native_map=""
native_count=0
if [ "$native" != "0" ] && [ -n "$sessions_file" ]; then
    native_plan=$(plan_native_forwards "$sessions_file" "$host" "$local_port")
    while read -r n_account n_display n_port; do
        [ -n "$n_account" ] || continue
        native_opts+=(-L "$n_port:localhost:$((5900 + n_display))")
        native_map="$native_map $n_account=$n_port:$n_display"
        native_count=$((native_count + 1))
    done <<< "$native_plan"
fi

if [ "$dry_run" -eq 1 ]; then
    echo "ssh -N -o ExitOnForwardFailure=yes${jump_opts[*]:+ ${jump_opts[*]}} -L $local_port:localhost:$remote_port${native_opts[*]:+ ${native_opts[*]}} $user@$host"
    echo "browser -> $url"
    echo "sessions -> ${sessions_file:-none (portal order, no descriptions)}"
    for entry in $native_map; do
        n_port=${entry#*=}; n_port=${n_port%%:*}
        echo "native ${entry%%=*} -> vnc://localhost:$n_port (${host}:$((5900 + ${entry##*:})))"
    done
    exit 0
fi

echo "Opening SSH tunnel: localhost:$local_port -> $user@$host:$remote_port${proxy_jump:+ (via $proxy_jump)}"
[ "$native_count" -gt 0 ] && echo "  plus $native_count native VNC forward(s) to $host:59xx"
ssh -N -o ExitOnForwardFailure=yes ${jump_opts[@]:+"${jump_opts[@]}"} \
    -L "$local_port:localhost:$remote_port" ${native_opts[@]+"${native_opts[@]}"} "$user@$host" &
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
        if render_dashboard "$url" "$dashboard_file" "$password" "$sessions_file" "$host" \
                "$user" "$proxy_jump" "$remote_port" "$ssh_pid" "$native_map" \
                2>"$dashboard_dir/render.err"; then
            built=1
            break
        fi
        sleep 0.3
    done
    if [ "$built" -eq 1 ]; then
        open_url="file://$dashboard_file"
        # Pass on the renderer's warnings (missing PyYAML, a bad sessions
        # file) once, rather than from every retry.
        grep '^WARNING' "$dashboard_dir/render.err" >&2
    else
        echo "WARNING: could not build the session dashboard; opening the raw session list instead." >&2
        sed 's/^/  /' "$dashboard_dir/render.err" >&2
        rm -rf "$dashboard_dir"
        dashboard_dir=""
    fi
fi

echo "Launching browser at $open_url"
open_browser "$open_url"

echo "Tunnel is up. Press Ctrl-C to close it."
wait "$ssh_pid"
