#!/usr/bin/env bash
#
# daq-common.sh
#
# Shared shell library for the Mu2e DAQ shifter tools. This file is
# meant to be *sourced*, not executed:
#
#     source "$(dirname "$0")/daq-common.sh"
#
# It provides the pieces that every shifter script needs and that were
# previously copy-pasted into each one:
#
#   daq_repo_root            locate the installation root
#   daq_load_dotenv          import a .env file without clobbering the
#                            environment
#   daq_config_file          resolve a config file by name, honouring
#                            the command line > environment > .env >
#                            config directory precedence
#   daq_python               the Python interpreter to use (venv first)
#   daq_read_config          query the DAQ operations YAML
#   daq_script_opts          expand $<SCRIPTNAME>_OPTS into "$@"
#   daq_die / daq_warn       diagnostics on stderr
#   daq_status_line          Pass/Fail reporting used by the login scripts
#
# See daq-common.sh(3) for the full API description.

# Guard against double-sourcing.
[ -n "${_DAQ_COMMON_SH_LOADED:-}" ] && return 0
_DAQ_COMMON_SH_LOADED=1

# --- diagnostics ---------------------------------------------------------

daq_warn() { printf '%s: %s\n' "${DAQ_PROG:-daq}" "$*" >&2; }
daq_die()  { daq_warn "$*"; exit "${DAQ_EXIT_CODE:-1}"; }

# Print "<label>: " followed by Pass (green) or Fail (red) for the given
# exit status. Used by the login-time Kerberos/git scripts.
daq_status_line() {
    if [ "$1" -eq 0 ]; then
        printf '%s: \033[32mPass\033[0m\n' "$2"
    else
        printf '%s: \033[31mFail\033[0m\n' "$2"
    fi
}

# --- installation root ---------------------------------------------------

# Echo the root of the shifter-tools installation. Precedence:
#   MU2EDAQ_ROOT > walk up from this library looking for a marker
#   > ~/daq-shifter-tools
# The marker is config/daq-operations.example.yaml, which is present in
# a git checkout and in a CMake --prefix install.
daq_repo_root() {
    if [ -n "${MU2EDAQ_ROOT:-}" ]; then
        printf '%s\n' "$MU2EDAQ_ROOT"
        return 0
    fi

    local here dir
    here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    dir="$here"
    while [ "$dir" != "/" ]; do
        if [ -e "$dir/config/daq-operations.example.yaml" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done

    printf '%s\n' "$HOME/daq-shifter-tools"
}

# --- .env support --------------------------------------------------------

# Import KEY=VALUE lines from the .env files. Variables already present
# in the environment are left alone, so the environment outranks .env;
# and earlier files outrank later ones.
#
# Files are read in this order:
#   $1 (if given), else
#   $MU2EDAQ_DOTENV, ~/.mu2edaq/env, <root>/.env, ./.env
#
# ~/.mu2edaq/env is where install-login.sh records MU2EDAQ_ROOT, so the
# commands installed into ~/bin can find their config and data.
daq_load_dotenv() {
    local files=""
    if [ -n "${1:-}" ]; then
        files="$1"
    else
        [ -n "${MU2EDAQ_DOTENV:-}" ] && files="$files $MU2EDAQ_DOTENV"
        files="$files $HOME/.mu2edaq/env"
        files="$files $(daq_repo_root)/.env"
        files="$files ./.env"
    fi

    local file
    for file in $files; do
        [ -f "$file" ] || continue
        _daq_load_dotenv_file "$file"
    done
}

# Read one .env file. Split out so daq_load_dotenv stays readable.
_daq_load_dotenv_file() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blanks and comments.
        case "$line" in ''|\#*) continue;; esac
        # Tolerate "export KEY=VALUE".
        line="${line#export }"
        case "$line" in *=*) ;; *) continue;; esac
        key="${line%%=*}"
        value="${line#*=}"
        # Reject anything that is not a shell identifier.
        case "$key" in [!A-Za-z_]*|*[!A-Za-z0-9_]*) continue;; esac
        # Strip one layer of matching quotes.
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}";;
            \'*\') value="${value#\'}"; value="${value%\'}";;
        esac
        # Anything already in the environment wins.
        if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
            export "$key=$value"
        fi
    done < "$file"
}

# --- configuration files -------------------------------------------------

# Echo the config search path, one directory per line.
daq_config_path() {
    local root
    root="$(daq_repo_root)"
    [ -n "${MU2EDAQ_CONFIG_DIR:-}" ] && printf '%s\n' "$MU2EDAQ_CONFIG_DIR"
    printf '%s\n' "$PWD/config"
    printf '%s\n' "$root/config"
    printf '%s\n' "$HOME/.config/mu2edaq"
    printf '%s\n' "/etc/mu2edaq"
}

# daq_config_file NAME [EXPLICIT]
#
# Resolve a configuration file. If EXPLICIT is non-empty it is used
# as-is (with ~ expanded) and must exist. Otherwise NAME is looked for
# in each directory of daq_config_path in order. Echoes the path, or
# fails with status 1 and a message on stderr.
daq_config_file() {
    local name="$1" explicit="${2:-}" dir candidate

    if [ -n "$explicit" ]; then
        # Expand a leading ~ ourselves: a quoted "~/x" is not expanded
        # by the shell, and this was a long-standing bug in the old
        # scripts, whose default config path was the literal string
        # "~/daq-shifter-tools/daq-operations.yaml".
        case "$explicit" in "~/"*) explicit="$HOME/${explicit#'~/'}";; esac
        if [ -f "$explicit" ]; then
            printf '%s\n' "$explicit"
            return 0
        fi
        daq_warn "config file not found: $explicit"
        return 1
    fi

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        candidate="$dir/$name"
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done <<< "$(daq_config_path)"

    daq_warn "no $name found on the config search path:"
    daq_config_path | sed 's/^/  /' >&2
    return 1
}

# --- Python --------------------------------------------------------------

# Echo the Python interpreter to use: the project venv if it has been
# bootstrapped, else PYTHON from the environment, else python3.
daq_python() {
    local root
    root="$(daq_repo_root)"
    if [ -x "$root/venv/bin/python" ]; then
        printf '%s\n' "$root/venv/bin/python"
    elif [ -n "${PYTHON:-}" ]; then
        printf '%s\n' "$PYTHON"
    else
        printf '%s\n' "python3"
    fi
}

# Verify the Python utilities can run, i.e. that PyYAML and click are
# importable. Returns non-zero with advice if the venv is missing.
daq_require_python_deps() {
    local py
    py="$(daq_python)"
    if "$py" -c 'import yaml, click' >/dev/null 2>&1; then
        return 0
    fi
    if PYTHONPATH="$(daq_repo_root)/src${PYTHONPATH:+:$PYTHONPATH}" \
        "$py" -c 'import yaml, click' >/dev/null 2>&1; then
        return 0
    fi
    daq_warn "PyYAML and click are required; run $(daq_repo_root)/bootstrap.sh"
    return 1
}

# Run a module from the mu2edaq_shifter_tools package. Prefers an
# installed console script, then falls back to running the package out
# of the source tree so an un-installed checkout still works.
# Usage: daq_run_tool MODULE CONSOLE_SCRIPT [ARGS...]
daq_run_tool() {
    local module="$1" console="$2"; shift 2
    local root py
    root="$(daq_repo_root)"
    py="$(daq_python)"

    if [ -x "$root/venv/bin/$console" ]; then
        "$root/venv/bin/$console" "$@"
    elif command -v "$console" >/dev/null 2>&1; then
        "$console" "$@"
    else
        PYTHONPATH="$root/src${PYTHONPATH:+:$PYTHONPATH}" \
            "$py" -m "mu2edaq_shifter_tools.$module" "$@"
    fi
}

# daq_read_config [ARGS...] -- query the operations YAML.
daq_read_config() {
    daq_run_tool read_config daq-read-config "$@"
}

# --- option handling -----------------------------------------------------

# Echo the contents of $<SCRIPTNAME>_OPTS for the calling script, so
# options can be supplied from the environment as well as the command
# line. start-daq.sh reads $START_DAQ_SH_OPTS, and for backwards
# compatibility with the pre-rename scripts also $START_DAQ_OPTS.
daq_script_opts() {
    local prog="${1:-${DAQ_PROG:-$(basename "$0")}}"
    local modern legacy
    modern="$(printf '%s' "$prog" | tr 'a-z.-' 'A-Z__')_OPTS"
    legacy="$(printf '%s' "${prog%.sh}" | tr 'a-z.-' 'A-Z__')_OPTS"
    local value
    value="$(eval "printf '%s' \"\${$modern:-}\"")"
    if [ -z "$value" ] && [ "$modern" != "$legacy" ]; then
        value="$(eval "printf '%s' \"\${$legacy:-}\"")"
    fi
    printf '%s\n' "$value"
}

# Confirm a disruptive action unless assume_yes is set. Usage:
#   daq_confirm "$assume_yes" "Restart the VNC servers on host?" || exit 0
daq_confirm() {
    local assume_yes="$1" prompt="$2" reply
    [ "$assume_yes" = "1" ] && return 0
    printf '%s [y/N] ' "$prompt"
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}
