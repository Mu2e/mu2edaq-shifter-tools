#!/usr/bin/env bash
#
# bootstrap.sh
#
# Set up the Python virtual environment for the Python half of
# mu2edaq-shifter-tools and install/update its dependencies.
#
# The Python utilities (daq-read-config, daq-open-tunnels,
# daq-cluster-cp, daq-ls2json, daq-install-tools) need PyYAML and click;
# "daq-open-tunnels --gui" additionally needs PyQt5.
#
# The bash utilities (start-daq.sh, stop-daq.sh, daq-status.sh,
# setup-online.sh, create-environment.sh, daq-tunnels.sh,
# start-novnc-connection.sh, manage-vnc-servers.sh, ...) run with system
# bash. Those that read the operations YAML do so by calling
# daq-read-config, so they need this venv; the VNC and tunnel scripts do
# not and work on a bare laptop.
#
# Configuration precedence: command line > environment > default.
#
#   -d, --dev       also install the test dependencies (pytest)
#   -e, --editable  install the package itself in editable mode, so the
#                   daq-* commands appear on the venv PATH
#   -G, --no-gui    skip PyQt5 (headless DAQ nodes)
#   -u, --upgrade   upgrade already-installed dependencies
#   -p, --python P  interpreter to build the venv with (env PYTHON)
#   -f, --force     delete and recreate an existing venv
#   -h, --help      show this help and exit
#
# See bootstrap.sh(1).

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
VENV="$HERE/venv"

DEV=0
EDITABLE=0
NO_GUI=0
UPGRADE=0
FORCE=0
PYTHON="${PYTHON:-python3}"

USAGE="\
usage: $(basename "$0") [-d] [-e] [-G] [-u] [-p python] [-f]

Create venv/ and install the Python dependencies.

  -d, --dev       also install pytest
  -e, --editable  pip install -e . so the daq-* commands are on the PATH
  -G, --no-gui    skip PyQt5
  -u, --upgrade   upgrade already-installed dependencies
  -p, --python P  interpreter to build the venv with (default python3)
  -f, --force     delete and recreate an existing venv
  -h, --help      show this help and exit
"

while [ -n "${1:-}" ]; do
    case "$1" in
        -d|--dev)      DEV=1;;
        -e|--editable) EDITABLE=1;;
        -G|--no-gui)   NO_GUI=1;;
        -u|--upgrade)  UPGRADE=1;;
        -f|--force)    FORCE=1;;
        -p|--python)   shift; PYTHON="${1:-}";;
        -h|--help)     printf '%s' "$USAGE"; exit 0;;
        *)             echo "Unknown option: $1" >&2
                       printf '%s' "$USAGE" >&2; exit 2;;
    esac
    shift
done

# --- interpreter check ---------------------------------------------------
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "error: $PYTHON not found. Install Python 3.9 or newer first." >&2
    exit 1
fi

PYVER="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "error: Python >= 3.9 required, found $PYVER" >&2
    exit 1
fi
echo "Using Python $PYVER at $(command -v "$PYTHON")"

# --- virtual environment -------------------------------------------------
if [ "$FORCE" = 1 ] && [ -d "$VENV" ]; then
    echo "Removing existing environment $VENV"
    rm -rf "$VENV"
fi

if [ ! -d "$VENV" ]; then
    echo "Creating virtual environment in $VENV"
    "$PYTHON" -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip >/dev/null

# Expanding an empty array under "set -u" is an error in bash 3.2 (the
# system bash on macOS), so guard every expansion with ${a[@]+...}.
PIP_FLAGS=()
[ "$UPGRADE" = 1 ] && PIP_FLAGS+=("--upgrade")

# --- dependencies --------------------------------------------------------
if [ "$NO_GUI" = 1 ]; then
    echo "Installing runtime dependencies (without PyQt5)"
    # Filter PyQt5 out of requirements.txt rather than maintaining a
    # second list.
    grep -v -i '^[[:space:]]*PyQt5' "$HERE/requirements.txt" \
        | python -m pip install ${PIP_FLAGS[@]+"${PIP_FLAGS[@]}"} -r /dev/stdin
else
    echo "Installing runtime dependencies from requirements.txt"
    python -m pip install ${PIP_FLAGS[@]+"${PIP_FLAGS[@]}"} -r "$HERE/requirements.txt"
fi

if [ "$DEV" = 1 ]; then
    echo "Installing test dependencies (pytest)"
    python -m pip install ${PIP_FLAGS[@]+"${PIP_FLAGS[@]}"} pytest
fi

if [ "$EDITABLE" = 1 ]; then
    echo "Installing mu2edaq-shifter-tools in editable mode"
    python -m pip install -e "$HERE"
fi

# --- local configuration -------------------------------------------------
# Seed a .env from the example so operators have something to edit, but
# never overwrite one that already exists.
if [ ! -f "$HERE/.env" ] && [ -f "$HERE/.env.example" ]; then
    cp "$HERE/.env.example" "$HERE/.env"
    echo "Created .env from .env.example (all values commented out)"
fi

# --- report --------------------------------------------------------------
echo ""
echo "Bootstrap complete."
echo "  Activate with:            source venv/bin/activate"
if [ "$EDITABLE" = 1 ]; then
    echo "  Python commands:          daq-read-config, daq-open-tunnels,"
    echo "                            daq-cluster-cp, daq-ls2json, daq-install-tools"
else
    echo "  Install the daq-* commands on the PATH with: ./bootstrap.sh --editable"
fi
echo "  Shell commands:           ./start-daq.sh, ./stop-daq.sh,"
echo "                            scripts/daq-status.sh, scripts/setup-online.sh, ..."
echo "  Man pages (uninstalled):  man -M \"$HERE/man\" daq-read-config"
if [ "$DEV" = 1 ]; then
    echo "  Run the tests with:       python -m pytest"
fi
