#!/usr/bin/env bash
#
# set_git_env.sh
#
# Configure the git/GitHub environment for the current DAQ account from
# $KRB5_PRINCIPAL:
#
#   * git user.email is set to the full principal, user.name to the
#     part before the @
#   * GIT_SSH_COMMAND is pointed at the per-user key
#     ~/.ssh/id_<user>_rsa
#   * that key is added to the ssh-agent, but only on a terminal (so
#     there is somewhere to type the passphrase) and only when an agent
#     is actually available
#
# Intended to be SOURCED, so GIT_SSH_COMMAND persists:
#
#     source set_git_env.sh
#
# Requires KRB5_PRINCIPAL, which get_krb_principal.sh exports.
#
# Configuration precedence: command line > environment > default.
#
#   -k, --key FILE   private key to use   (env GIT_SSH_KEY,
#                                          default ~/.ssh/id_<user>_rsa)
#   -l, --local      write the git identity to the repository config
#                    instead of --global
#   -v, --verbose    print the underlying detail (also env VERBOSE=1)
#   -h, --help       show this help and exit
#
# See set_git_env.sh(1).

_sge_main() {
    local key="${GIT_SSH_KEY:-}"
    local scope="--global"
    local verbose="${VERBOSE:-}"

    while [ -n "${1-}" ]; do
        case "$1" in
            -k|--key)     shift; key="${1-}";;
            -l|--local)   scope="--local";;
            -v|--verbose) verbose=1;;
            -h|--help)
                echo "usage: set_git_env.sh [-k key] [-l] [-v]"
                echo "Configures git identity and GIT_SSH_COMMAND from \$KRB5_PRINCIPAL."
                return 0;;
            *)  echo "set_git_env.sh: unknown option: $1" >&2; return 2;;
        esac
        shift
    done

    # Load the shared Pass/Fail reporter if it is reachable; fall back to
    # a local copy so this script still works standalone.
    if ! command -v daq_status_line >/dev/null 2>&1; then
        local here
        here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
        for lib in "$here/daq-common.sh" "$HOME/bin/daq-common.sh"; do
            [ -f "$lib" ] && { . "$lib"; break; }
        done
    fi
    if ! command -v daq_status_line >/dev/null 2>&1; then
        daq_status_line() {
            if [ "$1" -eq 0 ]; then printf '%s: \033[32mPass\033[0m\n' "$2"
            else printf '%s: \033[31mFail\033[0m\n' "$2"; fi
        }
    fi

    if [ -z "${KRB5_PRINCIPAL:-}" ]; then
        daq_status_line 1 "Configuring Git User Information"
        echo "  --> KRB5_PRINCIPAL is not set; source get_krb_principal.sh first <--" >&2
        return 1
    fi

    local user="${KRB5_PRINCIPAL%%@*}"

    git config $scope user.email "$KRB5_PRINCIPAL" \
        && git config $scope user.name "$user"
    daq_status_line $? "Configuring Git User Information"
    [ -n "$verbose" ] && git config $scope --list | grep '^user\.'

    [ -z "$key" ] && key="$HOME/.ssh/id_${user}_rsa"
    export GIT_SSH_COMMAND="ssh -i $key"
    [ -f "$key" ]
    daq_status_line $? "Configuring Git SSH Command"
    if [ -n "$verbose" ]; then
        echo "  GIT_SSH_COMMAND=$GIT_SSH_COMMAND"
        [ -f "$key" ] || echo "  --> $key not found <--"
    fi

    # Add the key to the agent only when we can prompt for a passphrase
    # and an agent exists to hold it.
    if [ -f "$key" ] && [ -t 0 ] && [ -n "${SSH_AUTH_SOCK:-}" ]; then
        local key_fp
        key_fp=$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}')
        if [ -n "$key_fp" ] && ssh-add -l 2>/dev/null | grep -q -- "$key_fp"; then
            [ -n "$verbose" ] && echo "  key already loaded in ssh-agent, skipping ssh-add"
        elif [ -n "$verbose" ]; then
            ssh-add "$key"
        else
            ssh-add -q "$key"
        fi
    fi

    return 0
}

_sge_main "$@"
_sge_status=$?
unset -f _sge_main
return "$_sge_status" 2>/dev/null || exit "$_sge_status"
