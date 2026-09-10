#!/usr/bin/env bash
#
# daq-network-verify.sh
#
# Sweep the Mu2e DAQ private networks with nmap so that every reachable
# host appears in the local ARP table, then dump the ARP and routing
# tables and report which hosts answered on each network.
#
# Three networks are swept by default:
#   control  192.168.6.0/24
#   data     192.168.7.0/24
#   IPMI     192.168.157.0/24
#
# Configuration precedence: command line > environment > .env > default.
#
#   -N, --networks LIST  space/comma-separated CIDRs to sweep
#                        (env MU2EDAQ_NETWORKS)
#   -o, --output DIR     directory for the dumps
#                        (env MU2EDAQ_NETVERIFY_DIR, default $PWD)
#   -s, --skip-scan      reuse the existing ARP table, do not run nmap
#   -n, --dry-run        print what would happen, change nothing
#   -h, --help           show this help and exit
#
# nmap is required unless --skip-scan is given. Sweeping a /24 takes a
# few seconds per network.
#
# See daq-network-verify.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$HOME/bin/daq-common.sh"; do
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "daq-network-verify.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="daq-network-verify.sh"
daq_load_dotenv

# Default networks, in "label=cidr" form so the report can name them.
DEFAULT_NETWORKS="control=192.168.6.0/24 data=192.168.7.0/24 ipmi=192.168.157.0/24"

networks="${MU2EDAQ_NETWORKS:-$DEFAULT_NETWORKS}"
outdir="${MU2EDAQ_NETVERIFY_DIR:-$PWD}"
skip_scan=0
dry_run=0

USAGE="\
usage: $(basename "$0") [-N networks] [-o dir] [-s] [-n]

Sweep the DAQ private networks and report which hosts answered.

  -N, --networks LIST  space/comma-separated CIDRs, optionally
                       label=cidr (default: $DEFAULT_NETWORKS)
  -o, --output DIR     directory for the ARP/routing dumps (default \$PWD)
  -s, --skip-scan      reuse the existing ARP table, do not run nmap
  -n, --dry-run        show what would be done, change nothing
  -h, --help           show this help and exit
"

# Options may also be supplied via $DAQ_NETWORK_VERIFY_SH_OPTS.
eval set -- $(daq_script_opts daq-network-verify.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -N|--networks) shift; networks="${1:-}";;
        -o|--output)   shift; outdir="${1:-}";;
        -s|--skip-scan) skip_scan=1;;
        -n|--dry-run)  dry_run=1;;
        -h|--help|-\?) printf '%s' "$USAGE"; exit 0;;
        --debug)       set -x;;
        *)             daq_warn "unknown option: $1"
                       printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

networks="$(printf '%s' "$networks" | tr ',' ' ')"
[ -n "${networks// /}" ] || daq_die "no networks to sweep"

# A dry run only prints what it would do, so it needs no tools.
if [ "$skip_scan" -eq 0 ] && [ "$dry_run" -eq 0 ] \
    && ! command -v nmap >/dev/null 2>&1; then
    daq_die "nmap is required (or pass --skip-scan to reuse the ARP table)"
fi

arp_table="$outdir/arp_table.txt"
routing_table="$outdir/routing_table.txt"
filtered="$outdir/filtered_arp_table.txt"

run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

# As run(), but discard the command's own output. The redirection has to
# live inside the function so it does not also swallow the echo above.
run_quiet() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@" >/dev/null 2>&1
}

[ "$dry_run" -eq 1 ] || mkdir -p "$outdir"

# Populate the ARP table by pinging every host on each network.
if [ "$skip_scan" -eq 0 ]; then
    for entry in $networks; do
        cidr="${entry#*=}"
        label="${entry%%=*}"
        [ "$label" = "$cidr" ] && label="network"
        echo "Sweeping $label ($cidr)..."
        run_quiet nmap -sn "$cidr"
    done
fi

# Dump the ARP and routing tables. Option spellings differ between
# Linux (route -n) and macOS/BSD (netstat -rn).
if [ "$dry_run" -eq 0 ]; then
    arp -a | sort > "$arp_table"
    if command -v ip >/dev/null 2>&1; then
        ip route show > "$routing_table"
    elif route -n >/dev/null 2>&1; then
        route -n > "$routing_table"
    else
        netstat -rn > "$routing_table" 2>/dev/null || : > "$routing_table"
    fi
    : > "$filtered"
else
    echo "  + arp -a | sort > $arp_table"
    echo "  + <routing table> > $routing_table"
fi

if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: no networks swept, no files written."
    exit 0
fi

# Report the hosts seen on each network, tagging each ARP line with the
# network it belongs to.
for entry in $networks; do
    cidr="${entry#*=}"
    label="${entry%%=*}"
    [ "$label" = "$cidr" ] && label="network"

    # Match on the network prefix, i.e. the CIDR minus its last octet.
    prefix="${cidr%.*/*}."

    echo ""
    echo "---------------- ${label} network ($cidr) ----------------"
    if grep -F "$prefix" "$arp_table" | sort | tee -a "$filtered" | grep -q .; then
        :
    else
        echo "  (no hosts answered)"
    fi
done

echo ""
echo "Wrote:"
echo "  $arp_table"
echo "  $routing_table"
echo "  $filtered"
exit 0
