#!/usr/bin/env bash
#
# get_krb_daq_principle.sh
#
# Determine the Kerberos principal for the current DAQ group account
# (mu2eshift, mu2edaq, mu2edcs, ...) from its deployed keytab.
#
# The keytabs are deployed one-per-account, named <user>.keytab, into
# the keytab directory (default ~/.krb5). This script looks up the
# keytab matching the current user and pulls the FNAL.GOV principal
# out of it. If the current user does not match one of the keytabs,
# it falls back to the default mu2edaq identity:
#
#     mu2edaq/mu2edaq/mu2e.fnal.gov@FNAL.GOV   (from mu2edaq.keytab)
#
# It then runs `kinit -kt` to actually obtain a Kerberos ticket for
# that principal from its keytab.
#
# On success it exports:
#     KRB5_PRINCIPAL  - the principal string
#     KRB5_KEYTAB     - path to the keytab the principal came from
#
# The keytab directory can be overridden (CLI > environment > default):
#     --keytab-dir DIR   command-line option
#     KRB5_KEYTAB_DIR    environment variable
#
# Intended to be sourced (so the exports persist), but also runs
# standalone to print the principal.

_gkdp_main() {
    local keytab_dir="${KRB5_KEYTAB_DIR:-$HOME/.krb5}"
    local default_keytab="mu2edaq.keytab"
    local default_principal="mu2edaq/mu2edaq/mu2e.fnal.gov@FNAL.GOV"

    # Parse options; command line overrides the environment/default.
    while [ -n "${1-}" ]; do
        case "$1" in
            -d|--keytab-dir) shift; keytab_dir="${1-}";;
            -h|--help)
                echo "usage: get_krb_daq_principle.sh [-d|--keytab-dir DIR]"
                return 0;;
            *)
                echo "get_krb_daq_principle.sh: unknown option: $1" >&2
                return 1;;
        esac
        shift
    done

    local user keytab principal
    user=$(id -un)
    keytab="$keytab_dir/${user}.keytab"

    if [ -f "$keytab" ]; then
        # Pull the first FNAL.GOV principal out of this user's keytab.
        principal=$(klist -k "$keytab" 2>/dev/null \
                        | awk '/FNAL.GOV/ {print $2; exit}')
    fi

    if [ -z "$principal" ]; then
        # Current user does not match a keytab (or it was unreadable):
        # fall back to the default mu2edaq identity.
        keytab="$keytab_dir/$default_keytab"
        principal="$default_principal"
    fi

    export KRB5_PRINCIPAL="$principal"
    export KRB5_KEYTAB="$keytab"

    if [ -n "$VERBOSE" ]; then
        echo "DAQ Kerberos principal: $KRB5_PRINCIPAL"
        echo "Using keytab:           $KRB5_KEYTAB"
    fi

    local rc
    if [ -f "$KRB5_KEYTAB" ]; then
        # Obtain the actual ticket from the keytab for this principal.
        if [ -n "$VERBOSE" ]; then
            kinit -kt "$KRB5_KEYTAB" "$KRB5_PRINCIPAL"
        else
            kinit -kt "$KRB5_KEYTAB" "$KRB5_PRINCIPAL" 2>/dev/null
        fi
        rc=$?
    else
        [ -n "$VERBOSE" ] && \
            echo "get_krb_daq_principle.sh: warning: keytab not found, cannot kinit: $KRB5_KEYTAB" >&2
        rc=1
    fi

    # "<label>: " then Pass (green) / Fail (red).
    if [ "$rc" -eq 0 ]; then
        printf '%s: \033[32mPass\033[0m\n' "Configuring Kerberos Ticket"
    else
        printf '%s: \033[31mFail\033[0m\n' "Configuring Kerberos Ticket"
    fi
    return $rc
}

_gkdp_main "$@"
_gkdp_rc=$?
unset -f _gkdp_main
# Propagate the status whether we were sourced (return) or run (exit).
return $_gkdp_rc 2>/dev/null || exit $_gkdp_rc
