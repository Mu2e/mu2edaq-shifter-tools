#!/usr/bin/env bash
#
# setup-online.sh
#
# Set up the shell for one DAQ environment inside one partition: obtain
# Kerberos credentials, configure the git/GitHub environment, then cd
# into the environment's test release and source its setup command.
#
# This script MUST BE SOURCED, not executed -- it changes the current
# directory and defines the ots environment in the calling shell:
#
#     source setup-online.sh -z partition_0 -e tracker
#
# The login aliases define "setup_online" as exactly that.
#
# Configuration precedence: command line > environment > .env > config file.
#
#   -c, --config FILE       operations YAML   (env MU2EDAQ_CONFIG,
#                                              default: daq-operations.yaml
#                                              from the config search path)
#   -z, --partition NAME    partition         (env MU2EDAQ_PARTITION,
#                                              default partition_0)
#   -e, --environment NAME  environment       (env MU2EDAQ_ENVIRONMENT,
#                                              default: the partition's
#                                              first active environment)
#   -n, --dry-run           print what would happen, change nothing
#   -h, --help              show this help and exit
#
# See setup-online.sh(1).

# --- locate and load the shared library ---------------------------------
_so_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for _so_lib in "$_so_dir/daq-common.sh" "$_so_dir/scripts/daq-common.sh" \
               "$HOME/bin/daq-common.sh"; do
    # shellcheck source=scripts/daq-common.sh
    [ -f "$_so_lib" ] && { . "$_so_lib"; break; }
done
if [ -z "${_DAQ_COMMON_SH_LOADED:-}" ]; then
    echo "setup-online.sh: cannot find daq-common.sh" >&2
    # Sourced scripts return; executed ones exit. Only one branch runs,
    # so the other is not really unreachable.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

DAQ_PROG="setup-online.sh"
daq_load_dotenv

_so_config="${MU2EDAQ_CONFIG:-}"
_so_partition="${MU2EDAQ_PARTITION:-partition_0}"
_so_environment="${MU2EDAQ_ENVIRONMENT:-}"
_so_dry_run=0
_so_help=0
_so_status=0

_so_usage="\
usage: setup-online.sh [-c config] [-z partition] [-e environment] [-n]

Source this script to set up one DAQ environment in the calling shell.

  -c, --config FILE       operations YAML to read
  -z, --partition NAME    partition to set up (default partition_0)
  -e, --environment NAME  environment to set up
  -n, --dry-run           show what would be done, change nothing
  -h, --help              show this help and exit
"

# Options may also be supplied via $SETUP_ONLINE_SH_OPTS.
# The command substitution is deliberately unquoted: $<COMMAND>_OPTS
# holds a list of options that must be split into separate words.
# shellcheck disable=SC2046
eval set -- $(daq_script_opts setup-online.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -c|--config)      shift; _so_config="${1:-}";;
        -z|--partition)   shift; _so_partition="${1:-}";;
        -e|--environment) shift; _so_environment="${1:-}";;
        -n|--dry-run)     _so_dry_run=1;;
        -h|--help|-\?)    _so_help=1;;
        --debug)          set -x;;
        -*)               daq_warn "unknown option: $1"; _so_help=1; _so_status=2;;
        *)                daq_warn "unexpected argument: $1"; _so_help=1; _so_status=2;;
    esac
    shift
done

if [ "$_so_help" -eq 1 ]; then
    printf '%s' "$_so_usage"
    unset _so_dir _so_lib _so_config _so_partition _so_environment \
          _so_dry_run _so_help _so_usage
    # Sourced scripts return; executed ones exit. Only one branch runs,
    # so the other is not really unreachable.
    # shellcheck disable=SC2317
    return "${_so_status:-0}" 2>/dev/null || exit "${_so_status:-0}"
fi

# --- credentials and git environment ------------------------------------
# Retrieve the user's Kerberos credentials, then key the GitHub
# environment off the resulting principal. After this the shell can
# reach GitHub.
if [ "$_so_dry_run" -eq 0 ]; then
    # shellcheck source=scripts/get_krb_principal.sh
    [ -f "$_so_dir/get_krb_principal.sh" ] && . "$_so_dir/get_krb_principal.sh"
    # shellcheck source=scripts/set_git_env.sh
    [ -f "$_so_dir/set_git_env.sh" ]       && . "$_so_dir/set_git_env.sh"
else
    echo "  + source $_so_dir/get_krb_principal.sh"
    echo "  + source $_so_dir/set_git_env.sh"
fi

# --- resolve the environment from the operations YAML -------------------
_so_config_file="$(daq_config_file daq-operations.yaml "$_so_config")" || {
    unset _so_dir _so_lib _so_config _so_partition _so_environment \
          _so_dry_run _so_help _so_usage _so_config_file
    # Sourced scripts return; executed ones exit. Only one branch runs,
    # so the other is not really unreachable.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
}

# With no -e, take the first active environment of the partition so that
# "source setup-online.sh" alone does something useful.
if [ -z "$_so_environment" ]; then
    _so_environment="$(daq_read_config --config "$_so_config_file" \
                          --partition "$_so_partition" active-envs | awk '{print $1}')"
    [ -n "$_so_environment" ] && \
        echo "setup-online.sh: defaulting to environment $_so_environment"
fi

_so_dir_target="$(daq_read_config --config "$_so_config_file" \
                     --partition "$_so_partition" \
                     --environment "$_so_environment" directory)" || _so_dir_target=""
_so_setup_cmd="$(daq_read_config --config "$_so_config_file" \
                    --partition "$_so_partition" \
                    --environment "$_so_environment" setup)" || _so_setup_cmd=""

if [ -z "$_so_dir_target" ]; then
    daq_warn "no test release directory for $_so_partition/$_so_environment"
    _so_status=1
elif [ ! -d "$_so_dir_target" ]; then
    daq_warn "test release directory does not exist: $_so_dir_target"
    daq_warn "run create-environment.sh -z $_so_partition -e $_so_environment first"
    _so_status=1
elif [ "$_so_dry_run" -eq 1 ]; then
    echo "  + cd $_so_dir_target"
    echo "  + source $_so_setup_cmd"
else
    cd "$_so_dir_target" || _so_status=1
    if [ "$_so_status" -eq 0 ]; then
        # setup_cmd may carry arguments (e.g. "setup_ots.sh tracker"),
        # so it is deliberately left unquoted here. It lives in the test
        # release, outside this repository, so it cannot be followed.
        # shellcheck disable=SC2086
        # shellcheck source=/dev/null
        . $_so_setup_cmd
        _so_status=$?
    fi
fi

# Leave the caller's shell clean: the environment we just set up is the
# only thing that should persist.
unset _so_dir _so_lib _so_config _so_partition _so_environment _so_dry_run \
      _so_help _so_usage _so_config_file _so_dir_target _so_setup_cmd
# Sourced scripts return; executed ones exit. Only one branch runs,
# so the other is not really unreachable.
# shellcheck disable=SC2317
return "${_so_status:-0}" 2>/dev/null || exit "${_so_status:-0}"
