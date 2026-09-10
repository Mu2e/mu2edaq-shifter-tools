#!/usr/bin/env bash
#
# get_krb_principal.sh
#
# Export KRB5_PRINCIPAL from the Kerberos credential cache the current
# shell logged in with. Only FNAL.GOV principals are considered, since
# that is the realm the DAQ accounts live in.
#
# Intended to be SOURCED, so the export persists:
#
#     source get_krb_principal.sh
#
# It also runs standalone, in which case it just prints the principal.
#
# Configuration precedence: command line > environment > default.
#
#   -q, --quiet   do not warn when no principal can be found
#   -h, --help    show this help and exit
#
# See get_krb_principal.sh(1).

_gkp_main() {
    local quiet=0

    while [ -n "${1-}" ]; do
        case "$1" in
            -q|--quiet) quiet=1;;
            -h|--help)
                echo "usage: get_krb_principal.sh [-q|--quiet]"
                echo "Exports KRB5_PRINCIPAL from the active FNAL.GOV ticket cache."
                return 0;;
            *)  echo "get_krb_principal.sh: unknown option: $1" >&2
                return 2;;
        esac
        shift
    done

    if ! command -v klist >/dev/null 2>&1; then
        [ "$quiet" -eq 1 ] || echo "get_krb_principal.sh: klist not found" >&2
        return 1
    fi

    local principal
    # "klist -l" lists the caches; the principal is the first field.
    principal=$(klist -l 2>/dev/null | awk '/FNAL\.GOV/ {print $1; exit}')

    # Fall back to the default cache when there is no cache collection
    # (klist -l is not supported by every krb5 build).
    if [ -z "$principal" ]; then
        principal=$(klist 2>/dev/null \
                        | awk '/^Default principal:/ {print $3; exit}')
        case "$principal" in *FNAL.GOV) ;; *) principal="";; esac
    fi

    if [ -z "$principal" ]; then
        [ "$quiet" -eq 1 ] || \
            echo "get_krb_principal.sh: no FNAL.GOV principal in the ticket cache; run kinit" >&2
        return 1
    fi

    export KRB5_PRINCIPAL="$principal"
    # Only print when executed rather than sourced.
    case "${BASH_SOURCE[0]}" in
        "$0") printf '%s\n' "$KRB5_PRINCIPAL";;
    esac
    return 0
}

_gkp_main "$@"
_gkp_status=$?
unset -f _gkp_main
# Sourced scripts return; executed ones exit. Only one branch runs,
# so the other is not really unreachable.
# shellcheck disable=SC2317
return "$_gkp_status" 2>/dev/null || exit "$_gkp_status"
