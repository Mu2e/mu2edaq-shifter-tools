#!/usr/bin/env bash
#
# create-environment.sh
#
# Create or update the spack test release for one DAQ environment. On a
# missing test release the mu2e-quick-spack-start.sh helper is fetched
# from Mu2e/otsdaq-mu2e and run against the partition's base release; on
# an existing one it is re-run with --develop to update it.
#
# Configuration precedence: command line > environment > .env > config file.
#
#   -c, --config FILE       operations YAML  (env MU2EDAQ_CONFIG,
#                                             default: daq-operations.yaml
#                                             from the config search path)
#   -z, --partition NAME    partition        (env MU2EDAQ_PARTITION,
#                                             default partition_0)
#   -e, --environment NAME  environment to create (required)
#   -u, --update-only       do not create a missing test release
#   -b, --branch REF        otsdaq-mu2e ref to fetch the helper from
#                           (env MU2EDAQ_OTSDAQ_REF, default develop)
#   -n, --dry-run           print what would happen, change nothing
#   -h, --help              show this help and exit
#
# See create-environment.sh(1).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for lib in "$SCRIPT_DIR/daq-common.sh" "$SCRIPT_DIR/scripts/daq-common.sh" \
           "$HOME/bin/daq-common.sh"; do
    # shellcheck source=scripts/daq-common.sh
    [ -f "$lib" ] && { . "$lib"; break; }
done
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] || {
    echo "create-environment.sh: cannot find daq-common.sh" >&2; exit 1; }

DAQ_PROG="create-environment.sh"
daq_load_dotenv

QUICK_START_SCRIPT="mu2e-quick-spack-start.sh"

config="${MU2EDAQ_CONFIG:-}"
partition="${MU2EDAQ_PARTITION:-partition_0}"
environment="${MU2EDAQ_ENVIRONMENT:-}"
otsdaq_ref="${MU2EDAQ_OTSDAQ_REF:-develop}"
update_only=0
dry_run=0

USAGE="\
usage: $(basename "$0") [-c config] [-z partition] -e environment [-u] [-b ref] [-n]

Create or update the spack test release for one DAQ environment.

  -c, --config FILE       operations YAML to read
  -z, --partition NAME    partition (default partition_0)
  -e, --environment NAME  environment to create (required)
  -u, --update-only       do not create a missing test release
  -b, --branch REF        otsdaq-mu2e ref for $QUICK_START_SCRIPT (default develop)
  -n, --dry-run           show what would be done, change nothing
  -h, --help              show this help and exit
"

# Options may also be supplied via $CREATE_ENVIRONMENT_SH_OPTS.
# The command substitution is deliberately unquoted: $<COMMAND>_OPTS
# holds a list of options that must be split into separate words.
# shellcheck disable=SC2046
eval set -- $(daq_script_opts create-environment.sh) '"$@"'

while [ -n "${1:-}" ]; do
    case "$1" in
        -c|--config)      shift; config="${1:-}";;
        -z|--partition)   shift; partition="${1:-}";;
        -e|--environment) shift; environment="${1:-}";;
        -b|--branch)      shift; otsdaq_ref="${1:-}";;
        -u|--update-only) update_only=1;;
        -n|--dry-run)     dry_run=1;;
        -h|--help|-\?)    printf '%s' "$USAGE"; exit 0;;
        --debug)          set -x;;
        *)                daq_warn "unknown option: $1"
                          printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

[ -n "$environment" ] || {
    daq_warn "an environment is required (-e)"
    printf '%s' "$USAGE" >&2; exit 2; }

config_file="$(daq_config_file daq-operations.yaml "$config")" || exit 1

dir="$(daq_read_config --config "$config_file" --partition "$partition" \
          --environment "$environment" directory)" \
    || daq_die "cannot read the test release path for $partition/$environment"
[ -n "$dir" ] || daq_die "no test_rel_path configured for $partition/$environment"

run() {
    echo "  + $*"
    [ "$dry_run" -eq 1 ] && return 0
    "$@"
}

if [ ! -d "$dir" ]; then
    if [ "$update_only" -eq 1 ]; then
        daq_die "test release $dir does not exist and --update-only was given"
    fi

    base_release="$(daq_read_config --config "$config_file" \
                       --partition "$partition" base-release)" \
        || daq_die "cannot read the base release for $partition"
    [ -n "$base_release" ] || daq_die "no base_release configured for $partition"

    echo "Creating test release $dir from base release $base_release"
    run mkdir -p "$dir"
    if [ "$dry_run" -eq 0 ]; then
        cd "$dir" || daq_die "cannot cd to $dir"
    fi
    run curl -fsSL -O \
        "https://raw.githubusercontent.com/Mu2e/otsdaq-mu2e/refs/heads/$otsdaq_ref/tools/$QUICK_START_SCRIPT"
    run chmod +x "$QUICK_START_SCRIPT"
    run "./$QUICK_START_SCRIPT" --develop --upstream "$base_release"
else
    echo "Updating existing test release $dir"
    if [ "$dry_run" -eq 0 ]; then
        cd "$dir" || daq_die "cannot cd to $dir"
    fi
    [ -x "./$QUICK_START_SCRIPT" ] || [ "$dry_run" -eq 1 ] || \
        daq_die "$dir/$QUICK_START_SCRIPT is missing; remove the directory to recreate it"
    run "./$QUICK_START_SCRIPT" --develop
fi

[ "$dry_run" -eq 1 ] && echo "Dry run: nothing was created."
exit 0
