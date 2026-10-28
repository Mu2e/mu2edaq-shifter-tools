#!/usr/bin/env bash
#
# daq-ssh-check.sh
#
# CLIENT SIDE: run this on your own laptop or workstation after
# install-ssh-config.sh, or whenever ssh to the DAQ stops working.
#
# Check, in order, everything the DAQ ssh paths depend on and report
# PASS/FAIL for each:
#
#   1. a Kerberos ticket exists, and its default principal is the one
#      recorded by install-ssh-config.sh (MU2EDAQ_KRB5_PRINCIPAL)
#   2. ssh resolves each host to the right user, ProxyJump and GSSAPI
#      settings (static, from "ssh -G"; no network)
#   3. a non-interactive login to each host succeeds (live)
#   4. optionally, the noVNC portal on mu2e-mgr-01 answers on 443
#
# Configuration precedence: command line > environment > .env > default.
#
#   -H, --hosts "H1 H2"  hosts to check, in order   (env MU2EDAQ_SSH_CHECK_HOSTS,
#                        default "mu2egateway01.fnal.gov mu2e-mgr-01.fnal.gov")
#   -F, --config FILE    ssh config to evaluate     (env MU2EDAQ_SSH_CONFIG,
#                                                    default ssh's own)
#   -t, --timeout SEC    ssh ConnectTimeout         (env MU2EDAQ_SSH_CHECK_TIMEOUT,
#                                                    default 15)
#   -s, --static         skip the live logins (steps 3 and 4)
#   -P, --portal         also check the noVNC portal (step 4)
#   -h, --help           show this help and exit
#
# Exit status: 0 when every check passed, 1 when any failed, 2 on usage error.
#
# See daq-ssh-check.sh(1).

set -u

DAQ_PROG="daq-ssh-check.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$HOME/bin/daq-common.sh"; do
    # shellcheck source=scripts/daq-common.sh
    [ -f "$lib" ] && { . "$lib"; break; }
done
command -v daq_load_dotenv >/dev/null 2>&1 && daq_load_dotenv

hosts="${MU2EDAQ_SSH_CHECK_HOSTS:-mu2egateway01.fnal.gov mu2e-mgr-01.fnal.gov}"
ssh_config="${MU2EDAQ_SSH_CONFIG:-}"
timeout="${MU2EDAQ_SSH_CHECK_TIMEOUT:-15}"
expect_principal="${MU2EDAQ_KRB5_PRINCIPAL:-}"
live=1
portal=0
portal_host="mu2e-mgr-01.fnal.gov"

USAGE="\
usage: $(basename "$0") [-H \"host ...\"] [-F ssh_config] [-t seconds] [-s] [-P]

CLIENT SIDE: check Kerberos and the ssh paths to the Mu2e DAQ hosts.

  -H, --hosts \"H1 H2\"  hosts to check (default: mu2egateway01 mu2e-mgr-01)
  -F, --config FILE    ssh config file to evaluate (default: ssh's own)
  -t, --timeout SEC    ssh ConnectTimeout (default 15)
  -s, --static         resolve settings only; no live logins
  -P, --portal         also check the noVNC portal on $portal_host
  -h, --help           show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -H|--hosts)   shift; hosts="${1:-}";;
        -F|--config)  shift; ssh_config="${1:-}";;
        -t|--timeout) shift; timeout="${1:-}";;
        -s|--static)  live=0;;
        -P|--portal)  portal=1;;
        -h|--help)    printf '%s' "$USAGE"; exit 0;;
        *)            echo "Unknown option: $1" >&2
                      printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

case "$timeout" in ''|*[!0-9]*) echo "ERROR: --timeout must be a whole number" >&2; exit 2;; esac
[ -n "$hosts" ] || { echo "ERROR: no hosts to check" >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo "FAIL  ssh is not installed" >&2; exit 1; }

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
info() { printf '      %s\n' "$*"; }

# A .env value arrives with a literal "~/"; expand it here.
case "$ssh_config" in '~/'*) ssh_config="$HOME/${ssh_config#'~/'}";; esac
ssh_opts=""
[ -n "$ssh_config" ] && ssh_opts="-F $ssh_config"

# --- 1. Kerberos --------------------------------------------------------------
echo "== Kerberos"
if ! command -v klist >/dev/null 2>&1; then
    fail "klist not found; install the Kerberos client tools"
elif ! klist -s 2>/dev/null; then
    fail "no valid Kerberos ticket; run: kinit ${expect_principal:-<you>@FNAL.GOV}"
else
    principal=$(klist 2>/dev/null | sed -n 's/^.*[Pp]rincipal: *\([^ ]*\).*$/\1/p' | head -1)
    if [ -n "$expect_principal" ] && [ "$principal" != "$expect_principal" ]; then
        fail "default ticket is $principal, expected $expect_principal"
        info "macOS keeps several tickets; switch with: kswitch -p $expect_principal"
    else
        pass "ticket for ${principal:-unknown principal}"
    fi
fi

# --- 2. Resolved ssh settings -------------------------------------------------
echo "== ssh settings (ssh -G)"
for host in $hosts; do
    # shellcheck disable=SC2086
    settings=$(ssh -G $ssh_opts "$host" 2>&1) || { fail "$host: ssh -G failed: $settings"; continue; }
    user=$(printf '%s\n' "$settings" | sed -n 's/^user //p')
    jump=$(printf '%s\n' "$settings" | sed -n 's/^proxyjump //p')
    gssapi=$(printf '%s\n' "$settings" | sed -n 's/^gssapiauthentication //p')
    problems=""
    [ "$gssapi" = "yes" ] || problems="$problems GSSAPIAuthentication is '${gssapi:-no}';"
    case "$host" in
        mu2egateway0*)
            [ "$user" = "$(id -un)" ] && problems="$problems user is your local name '$user' (no Include of config_mu2e?);";;
        mu2e-mgr-*|mu2e-trk*|mu2e-calo*|mu2e-dl-*|mu2e-cfo*|mu2e-dcs-*|mu2e-mc1-cr-*)
            case "$jump" in
                *mu2egateway0*) ;;
                '') problems="$problems no ProxyJump;";;
                *)  problems="$problems ProxyJump is '$jump', expected mu2egateway01;";;
            esac;;
        mu2e-mc1-worker-*)
            case "$jump" in *g2gateway0*) ;; *) problems="$problems ProxyJump is '${jump:-none}', expected g2gateway01;";; esac;;
    esac
    if [ -z "$problems" ]; then
        pass "$host: user $user${jump:+, via $jump}, GSSAPI on"
    else
        fail "$host:$problems"
    fi
done

# --- 3. Live logins -----------------------------------------------------------
if [ "$live" -eq 1 ]; then
    echo "== live login (BatchMode, ${timeout}s timeout)"
    for host in $hosts; do
        # shellcheck disable=SC2086
        out=$(ssh $ssh_opts -o BatchMode=yes -o ConnectTimeout="$timeout" "$host" \
              'echo "$(id -un)@$(hostname -s)"' 2>&1 </dev/null)
        if [ $? -eq 0 ]; then
            pass "$host: logged in as $(printf '%s\n' "$out" | tail -1)"
        else
            fail "$host: $(printf '%s\n' "$out" | tail -1)"
            case "$out" in
                *"Permission denied"*) info "your principal is probably not in that account's .k5login";;
                *"Could not resolve"*) info "DNS: are you on the Fermilab network or VPN?";;
            esac
        fi
    done

    # --- 4. noVNC portal ------------------------------------------------------
    if [ "$portal" -eq 1 ]; then
        echo "== noVNC portal on $portal_host"
        # shellcheck disable=SC2086
        code=$(ssh $ssh_opts -o BatchMode=yes -o ConnectTimeout="$timeout" "$portal_host" \
               'curl -sk -o /dev/null -w "%{http_code}" https://localhost/' 2>/dev/null </dev/null)
        if [ "$code" = "200" ]; then
            pass "https://localhost/ on $portal_host answers 200"
        else
            fail "https://localhost/ on $portal_host answered '${code:-nothing}'"
        fi
    fi
fi

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
    exit 0
fi
echo "$failures check(s) failed."
exit 1
