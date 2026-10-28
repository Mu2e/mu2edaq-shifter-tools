#!/usr/bin/env bash
#
# install-ssh-config.sh
#
# CLIENT SIDE: run this on your own laptop or workstation (macOS, Linux,
# or Windows under Git Bash/WSL), never on a DAQ host. The DAQ-host
# counterpart is install-login.sh.
#
# Install the Mu2e DAQ ssh client configuration for the current user:
#
#   * config/ssh-config-mu2e.in -> ~/.ssh/config_mu2e   (rendered with
#                                                       your account names)
#   * "Include ~/.ssh/config_mu2e" at the top of ~/.ssh/config
#   * personal settings          -> ~/.mu2edaq/env      (NOVNC_USER,
#                                                       MU2EDAQ_KRB5_PRINCIPAL)
#
# It asks for the values that differ per person (your Fermilab username
# and the shared accounts your principal is authorised for), offering a
# default for each. Values given on the command line or in the
# environment are not asked for; -y accepts every default without asking.
#
# Any existing file that would change is first backed up to
# <file>.bak.<timestamp>. Running it again with the same answers changes
# nothing.
#
# Configuration precedence: command line > environment > .env > prompt
# (whose default comes from ~/.mu2edaq/env, then klist, then built-ins).
#
#   -U, --fnal-user NAME    Fermilab username      (env MU2EDAQ_FNAL_USER)
#   -D, --daq-user NAME     shared DAQ account     (env MU2EDAQ_SSH_DAQ_USER,
#                                                   default mu2edaq)
#   -S, --shift-user NAME   shared shift account   (env MU2EDAQ_SSH_SHIFT_USER,
#                                                   default mu2eshift)
#   -C, --dcs-user NAME     DCS account            (env MU2EDAQ_SSH_DCS_USER,
#                                                   default mu2edcs)
#   -c, --ssh-config FILE   ssh config to edit     (env MU2EDAQ_SSH_CONFIG,
#                                                   default ~/.ssh/config)
#   -o, --output FILE       rendered fragment      (env MU2EDAQ_SSH_FRAGMENT,
#                                                   default ~/.ssh/config_mu2e)
#   -e, --env-file FILE     personal settings file (env MU2EDAQ_CLIENT_ENV,
#                                                   default ~/.mu2edaq/env)
#   -I, --no-include        do not edit the ssh config
#   -y, --yes               accept defaults, never prompt
#   -n, --dry-run           show what would be done, change nothing
#   -h, --help              show this help and exit
#
# See install-ssh-config.sh(1) and daq-ssh-check.sh(1).

set -u

DAQ_PROG="install-ssh-config.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Load the .env tier if the shared library is reachable.
for lib in "$SCRIPT_DIR/scripts/daq-common.sh" "$HOME/bin/daq-common.sh"; do
    # shellcheck source=scripts/daq-common.sh
    [ -f "$lib" ] && { . "$lib"; break; }
done
command -v daq_load_dotenv >/dev/null 2>&1 && daq_load_dotenv

# A checkout keeps the template beside this script; a CMake install puts
# it under <prefix>/share/mu2edaq/config, which MU2EDAQ_ROOT points at.
TEMPLATE=""
for candidate in "$SCRIPT_DIR/config" "${MU2EDAQ_ROOT:-/nonexistent}/config" \
                 "$SCRIPT_DIR/../share/mu2edaq/config"; do
    if [ -f "$candidate/ssh-config-mu2e.in" ]; then
        TEMPLATE="$candidate/ssh-config-mu2e.in"
        break
    fi
done

fnal_user="${MU2EDAQ_FNAL_USER:-}"
daq_user="${MU2EDAQ_SSH_DAQ_USER:-}"
shift_user="${MU2EDAQ_SSH_SHIFT_USER:-}"
dcs_user="${MU2EDAQ_SSH_DCS_USER:-}"
ssh_config="${MU2EDAQ_SSH_CONFIG:-$HOME/.ssh/config}"
fragment="${MU2EDAQ_SSH_FRAGMENT:-$HOME/.ssh/config_mu2e}"
env_file="${MU2EDAQ_CLIENT_ENV:-$HOME/.mu2edaq/env}"
do_include=1
assume_yes=0
dry_run=0

USAGE="\
usage: $(basename "$0") [-U fnal_user] [-D daq_user] [-S shift_user] [-C dcs_user]
                         [-c ssh_config] [-o fragment] [-e env_file] [-I] [-y] [-n]

CLIENT SIDE: install the Mu2e DAQ ssh configuration on this laptop or
workstation. Asks for your Fermilab username and the shared accounts
you use, unless they are given here or in the environment.

  -U, --fnal-user NAME   Fermilab username (principal NAME@FNAL.GOV)
  -D, --daq-user NAME    shared DAQ account   (default mu2edaq)
  -S, --shift-user NAME  shared shift account (default mu2eshift)
  -C, --dcs-user NAME    DCS account          (default mu2edcs)
  -c, --ssh-config FILE  ssh config to edit   (default ~/.ssh/config)
  -o, --output FILE      rendered fragment    (default ~/.ssh/config_mu2e)
  -e, --env-file FILE    personal settings    (default ~/.mu2edaq/env)
  -I, --no-include       do not edit the ssh config
  -y, --yes              accept defaults, never prompt
  -n, --dry-run          show what would be done, change nothing
  -h, --help             show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -U|--fnal-user)  shift; fnal_user="${1:-}";;
        -D|--daq-user)   shift; daq_user="${1:-}";;
        -S|--shift-user) shift; shift_user="${1:-}";;
        -C|--dcs-user)   shift; dcs_user="${1:-}";;
        -c|--ssh-config) shift; ssh_config="${1:-}";;
        -o|--output)     shift; fragment="${1:-}";;
        -e|--env-file)   shift; env_file="${1:-}";;
        -I|--no-include) do_include=0;;
        -y|--yes)        assume_yes=1;;
        -n|--dry-run)    dry_run=1;;
        -h|--help)       printf '%s' "$USAGE"; exit 0;;
        *)               echo "Unknown option: $1" >&2
                         printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

die() { echo "ERROR: $*" >&2; exit 1; }

# A .env value arrives with a literal "~/"; expand it here.
expand_home() {
    case "$1" in
        '~/'*) printf '%s\n' "$HOME/${1#'~/'}";;
        *)     printf '%s\n' "$1";;
    esac
}
ssh_config=$(expand_home "$ssh_config")
fragment=$(expand_home "$fragment")
env_file=$(expand_home "$env_file")

# run CMD... unless this is a dry run; always echo what is happening
run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

# Back up FILE if it exists, before it gets overwritten
backup() {
    [ -e "$1" ] && run cp -p "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"
    return 0
}

# Read KEY's value from an env-style file, or nothing
env_value() {
    [ -f "$2" ] || return 0
    sed -n "s/^\(export \)\{0,1\}$1=//p" "$2" | tail -1 | sed "s/^[\"']//; s/[\"']\$//"
}

# Account names go into an ssh config, so keep them to plain login names
valid_name() {
    case "$1" in
        # Character classes, not a-z ranges: ranges follow the locale's
        # collation order and match upper case in en_US.
        ''|[![:lower:]_]*|*[![:lower:][:digit:]_.-]*) return 1;;
    esac
    return 0
}

# ask VAR "question" default: fill VAR unless it is already set
ask() {
    local var="$1" question="$2" default="$3" answer
    [ -n "$(eval "printf '%s' \"\${$var}\"")" ] && return 0
    if [ "$assume_yes" -eq 0 ] && [ -t 0 ]; then
        while :; do
            printf '%s [%s]: ' "$question" "$default"
            IFS= read -r answer || answer=""
            [ -z "$answer" ] && answer="$default"
            valid_name "$answer" && break
            echo "  '$answer' is not a valid account name (lower-case letters, digits, . _ -)"
        done
    else
        answer="$default"
    fi
    eval "$var=\$answer"
}

[ -n "$TEMPLATE" ] || die "cannot find config/ssh-config-mu2e.in; run from a checkout or set MU2EDAQ_ROOT"

# --- Collect the personal values -------------------------------------------
klist_user=""
if command -v klist >/dev/null 2>&1; then
    klist_user=$(klist 2>/dev/null \
        | sed -n 's/^.*[Pp]rincipal: *\([^@ ]*\)@FNAL\.GOV.*$/\1/p' | head -1)
fi
saved_user=$(env_value NOVNC_USER "$env_file")
default_fnal="${saved_user:-${klist_user:-$(id -un)}}"

if [ "$assume_yes" -eq 0 ] && [ -t 0 ]; then
    echo "Mu2e DAQ ssh setup for this computer. Press Enter to accept a default."
    echo "The shared accounts must list your principal in their .k5login;"
    echo "if you are not sure, accept the default and run daq-ssh-check.sh after."
fi
ask fnal_user  "Fermilab username (Kerberos principal <name>@FNAL.GOV)" "$default_fnal"
ask daq_user   "Shared DAQ account for mu2egateway01, MC-2 hosts and teststands" mu2edaq
ask shift_user "Shared shift account for MC-1 (control room, g2gateway, workers)" mu2eshift
ask dcs_user   "Account for the DCS hosts (mu2e-dcs-*)" mu2edcs

for pair in "fnal-user:$fnal_user" "daq-user:$daq_user" \
            "shift-user:$shift_user" "dcs-user:$dcs_user"; do
    valid_name "${pair#*:}" || die "invalid --${pair%%:*} '${pair#*:}'"
done

echo ""
echo "Using: Fermilab user $fnal_user, DAQ account $daq_user," \
     "shift account $shift_user, DCS account $dcs_user"

# --- Render and install the fragment ----------------------------------------
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mu2e-ssh.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmp_dir"' EXIT

sed -e "s/@MU2E_DAQ_USER@/$daq_user/g" \
    -e "s/@MU2E_SHIFT_USER@/$shift_user/g" \
    -e "s/@MU2E_DCS_USER@/$dcs_user/g" \
    "$TEMPLATE" > "$tmp_dir/fragment" || die "could not render $TEMPLATE"

fragment_dir=$(dirname -- "$fragment")
echo "Installing the ssh fragment as $fragment"
[ -d "$fragment_dir" ] || run mkdir -m 700 -p "$fragment_dir"
if [ -f "$fragment" ] && cmp -s "$tmp_dir/fragment" "$fragment"; then
    echo "  = already up to date"
else
    backup "$fragment"
    run install -m 600 "$tmp_dir/fragment" "$fragment"
fi

# --- Include it from the ssh config -----------------------------------------
# The Include must sit before the first Host/Match line: inside a block it
# only applies to hosts matching that block.
status=0
if [ "$do_include" -eq 1 ]; then
    case "$fragment" in
        "$HOME/.ssh/"*) include_path="~/.ssh/${fragment#"$HOME/.ssh/"}";;
        *)              include_path="$fragment";;
    esac
    frag_name=$(basename -- "$fragment")
    echo "Adding 'Include $include_path' to $ssh_config"

    include_line=0
    first_block=0
    if [ -f "$ssh_config" ]; then
        include_line=$(grep -nE "^[[:space:]]*Include[[:space:]].*(^|[/[:space:]])$frag_name([[:space:]]|\$)" \
            "$ssh_config" | head -1 | cut -d: -f1)
        first_block=$(grep -nE '^[[:space:]]*(Host|Match)[[:space:]]' "$ssh_config" \
            | head -1 | cut -d: -f1)
        include_line=${include_line:-0}
        first_block=${first_block:-0}
    fi

    if [ "$include_line" -gt 0 ] && { [ "$first_block" -eq 0 ] || [ "$include_line" -lt "$first_block" ]; }; then
        echo "  = already included at line $include_line"
    elif [ "$include_line" -gt 0 ]; then
        echo "WARNING: $ssh_config includes $frag_name at line $include_line, inside the" >&2
        echo "         Host/Match block that starts at line $first_block, so it only applies" >&2
        echo "         to hosts that block matches. Move the Include above line $first_block." >&2
        status=1
    else
        {
            echo "# Mu2e DAQ hosts, added by mu2edaq-shifter-tools install-ssh-config.sh."
            echo "# Keep this above every Host/Match block."
            echo "Include $include_path"
            echo ""
            [ -f "$ssh_config" ] && cat "$ssh_config"
        } > "$tmp_dir/ssh_config"
        [ -d "$(dirname -- "$ssh_config")" ] || run mkdir -m 700 -p "$(dirname -- "$ssh_config")"
        if [ -f "$ssh_config" ]; then
            backup "$ssh_config"
            # Write through the existing file so a symlinked config and its
            # permissions are preserved.
            echo "  + prepend Include to $ssh_config"
            [ "$dry_run" -eq 1 ] || cat "$tmp_dir/ssh_config" > "$ssh_config"
        else
            run install -m 600 "$tmp_dir/ssh_config" "$ssh_config"
        fi
    fi
fi

# --- Record the personal settings -------------------------------------------
# start-novnc-connection.sh and daq-ssh-check.sh read these through
# daq_load_dotenv. Other keys already in the file are kept.
echo "Recording personal settings in $env_file"
{
    [ -f "$env_file" ] && grep -vE '^(export )?(NOVNC_USER|MU2EDAQ_KRB5_PRINCIPAL)=' "$env_file"
    echo "NOVNC_USER=$fnal_user"
    echo "MU2EDAQ_KRB5_PRINCIPAL=$fnal_user@FNAL.GOV"
} > "$tmp_dir/env"
if [ -f "$env_file" ] && cmp -s "$tmp_dir/env" "$env_file"; then
    echo "  = already up to date"
else
    [ -d "$(dirname -- "$env_file")" ] || run mkdir -p "$(dirname -- "$env_file")"
    backup "$env_file"
    run install -m 600 "$tmp_dir/env" "$env_file"
fi

# --- Show what ssh now makes of the main host --------------------------------
if [ "$dry_run" -eq 0 ] && [ "$do_include" -eq 1 ] && command -v ssh >/dev/null 2>&1; then
    echo ""
    echo "ssh now resolves mu2e-mgr-01.fnal.gov to:"
    ssh -G -F "$ssh_config" mu2e-mgr-01.fnal.gov 2>/dev/null \
        | grep -E '^(user|hostname|proxyjump|gssapiauthentication) ' | sed 's/^/  /'
fi

echo ""
if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: nothing was changed."
else
    echo "Done. Next: kinit $fnal_user@FNAL.GOV, then run scripts/daq-ssh-check.sh"
fi
exit "$status"
