"""Tests for the shell half of the toolkit.

These check the things that otherwise only fail in the control room:
that every script parses, that every command answers --help, and that
daq-common.sh resolves configuration with the documented precedence.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")

#: Scripts that are executed as commands.
COMMANDS = [
    "start-daq.sh",
    "stop-daq.sh",
    "install-login.sh",
    "bootstrap.sh",
    "scripts/create-environment.sh",
    "scripts/daq-status.sh",
    "scripts/send-run-control-command.sh",
    "scripts/daq-tunnels.sh",
    "scripts/daq-network-verify.sh",
    "scripts/start-tmux.sh",
    "scripts/manage-vnc-servers.sh",
    "scripts/start-novnc-connection.sh",
]

#: Scripts that are sourced rather than executed.
SOURCED = [
    "scripts/daq-common.sh",
    "scripts/setup-online.sh",
    "scripts/get_krb_principal.sh",
    "scripts/get_krb_daq_principal.sh",
    "scripts/set_git_env.sh",
]

#: Login dotfiles, also sourced.
DOTFILES = [
    "login/aliases",
    "login/bashrc",
    "login/bash_profile",
    "login/bash_logout",
]

pytestmark = pytest.mark.skipif(BASH is None, reason="bash is not available")


@pytest.mark.parametrize("script", COMMANDS + SOURCED + DOTFILES)
def test_script_parses(script):
    """Every shell file must survive "bash -n"."""
    path = REPO_ROOT / script
    assert path.is_file(), f"{script} is missing"
    result = subprocess.run(
        [BASH, "-n", str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    assert result.returncode == 0, result.stdout.decode()


@pytest.mark.parametrize("script", COMMANDS + SOURCED)
def test_script_is_executable(script):
    assert os.access(REPO_ROOT / script, os.X_OK), f"{script} is not executable"


@pytest.mark.parametrize(
    "script",
    [
        "start-daq.sh",
        "stop-daq.sh",
        "install-login.sh",
        "bootstrap.sh",
        "scripts/create-environment.sh",
        "scripts/daq-status.sh",
        "scripts/send-run-control-command.sh",
        "scripts/daq-network-verify.sh",
        "scripts/start-tmux.sh",
        "scripts/manage-vnc-servers.sh",
        "scripts/start-novnc-connection.sh",
    ],
)
def test_help_exits_zero_and_prints_usage(script):
    """--help must work without a config file, a cluster, or tmux."""
    result = subprocess.run(
        [str(REPO_ROOT / script), "--help"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    output = result.stdout.decode()
    assert result.returncode == 0, output
    assert "usage:" in output.lower(), output


@pytest.mark.parametrize("script", COMMANDS)
def test_unknown_option_is_rejected(script):
    """An unrecognised option must fail rather than being ignored."""
    result = subprocess.run(
        [str(REPO_ROOT / script), "--definitely-not-an-option"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode != 0, result.stdout.decode()


# --------------------------------------------------------------------------
# daq-common.sh
# --------------------------------------------------------------------------


def run_library(snippet: str, env=None, cwd=None) -> subprocess.CompletedProcess:
    """Source daq-common.sh and run a snippet against it."""
    script = f'source "{REPO_ROOT}/scripts/daq-common.sh"\n{snippet}\n'
    environment = dict(os.environ)
    for name in list(environment):
        if name.startswith("MU2EDAQ_"):
            del environment[name]
    if env:
        environment.update(env)
    return subprocess.run(
        [BASH, "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=str(cwd or REPO_ROOT),
        env=environment,
    )


def test_repo_root_finds_the_checkout():
    result = run_library("daq_repo_root")
    assert result.stdout.decode().strip() == str(REPO_ROOT)


def test_repo_root_honours_the_environment(tmp_path):
    result = run_library("daq_repo_root", env={"MU2EDAQ_ROOT": str(tmp_path)})
    assert result.stdout.decode().strip() == str(tmp_path)


def test_config_file_is_found_on_the_search_path():
    result = run_library("daq_config_file daq-operations.yaml")
    assert result.stdout.decode().strip().endswith("config/daq-operations.yaml")


def test_config_file_expands_a_tilde_in_an_explicit_path(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / "ops.yaml").write_text("partitions: {}\n")
    result = run_library(
        'daq_config_file daq-operations.yaml "~/ops.yaml"',
        env={"HOME": str(home)},
    )
    assert result.stdout.decode().strip() == str(home / "ops.yaml")


def test_config_file_reports_a_missing_explicit_path(tmp_path):
    result = run_library(
        f'daq_config_file daq-operations.yaml "{tmp_path}/nope.yaml"'
    )
    assert result.returncode != 0
    assert "not found" in result.stderr.decode()


def test_dotenv_does_not_override_the_environment(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("MU2EDAQ_PARTITION=from_dotenv\n")
    result = run_library(
        'daq_load_dotenv; printf "%s" "$MU2EDAQ_PARTITION"',
        env={
            "MU2EDAQ_DOTENV": str(env_file),
            "MU2EDAQ_PARTITION": "from_env",
        },
    )
    assert result.stdout.decode().strip() == "from_env"


def test_dotenv_supplies_unset_values(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text('export MU2EDAQ_PARTITION="from_dotenv"\n')
    result = run_library(
        'daq_load_dotenv; printf "%s" "$MU2EDAQ_PARTITION"',
        env={"MU2EDAQ_DOTENV": str(env_file)},
    )
    assert result.stdout.decode().strip() == "from_dotenv"


def test_dotenv_ignores_comments_and_junk(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# comment\n\nnot-a-setting\nBAD-KEY=1\nMU2EDAQ_PARTITION=ok\n"
    )
    result = run_library(
        'daq_load_dotenv; printf "%s" "$MU2EDAQ_PARTITION"',
        env={"MU2EDAQ_DOTENV": str(env_file)},
    )
    assert result.returncode == 0
    assert result.stdout.decode().strip() == "ok"


def test_script_opts_uses_the_modern_variable_name():
    result = run_library(
        "daq_script_opts start-daq.sh",
        env={"START_DAQ_SH_OPTS": "-z modern", "START_DAQ_OPTS": "-z legacy"},
    )
    assert result.stdout.decode().strip() == "-z modern"


def test_script_opts_falls_back_to_the_legacy_variable_name():
    result = run_library(
        "daq_script_opts start-daq.sh", env={"START_DAQ_OPTS": "-z legacy"}
    )
    assert result.stdout.decode().strip() == "-z legacy"


def test_script_opts_is_empty_when_unset():
    result = run_library("daq_script_opts start-daq.sh")
    assert result.stdout.decode().strip() == ""


def test_python_prefers_the_venv():
    result = run_library("daq_python")
    reported = result.stdout.decode().strip()
    if (REPO_ROOT / "venv" / "bin" / "python").exists():
        assert reported == str(REPO_ROOT / "venv" / "bin" / "python")
    else:
        assert reported.endswith("python3")


def test_read_config_reaches_the_python_tool():
    result = run_library("daq_read_config partitions")
    assert result.returncode == 0, result.stderr.decode()
    assert "partition_0" in result.stdout.decode()


def test_double_sourcing_is_a_no_op():
    result = run_library(
        f'source "{REPO_ROOT}/scripts/daq-common.sh"; echo "$_DAQ_COMMON_SH_LOADED"'
    )
    assert result.stdout.decode().strip() == "1"


# --------------------------------------------------------------------------
# Dry runs of the operator commands
# --------------------------------------------------------------------------


def test_start_daq_dry_run_lists_the_active_environments():
    result = subprocess.run(
        [str(REPO_ROOT / "start-daq.sh"), "-n", "-z", "partition_0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    output = result.stdout.decode()
    if "tmux is not installed" in output:
        pytest.skip("tmux is not available")
    assert result.returncode == 0, output
    assert "tracker" in output and "trigger" in output
    assert "nothing was started" in output


def test_network_verify_dry_run_needs_no_tools(tmp_path):
    result = subprocess.run(
        [str(REPO_ROOT / "scripts/daq-network-verify.sh"), "-n", "-o", str(tmp_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    output = result.stdout.decode()
    assert result.returncode == 0, output
    assert "no networks swept" in output
    assert not list(tmp_path.iterdir())


def test_install_login_dry_run_changes_nothing(tmp_path):
    result = subprocess.run(
        [
            str(REPO_ROOT / "install-login.sh"),
            "-n",
            "-d",
            str(tmp_path / "home"),
            "-b",
            str(tmp_path / "bin"),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    output = result.stdout.decode()
    assert result.returncode == 0, output
    assert not (tmp_path / "home").exists()
    assert not (tmp_path / "bin").exists()


# --------------------------------------------------------------------------
# Session and window naming
#
# start-daq.sh, stop-daq.sh and daq-status.sh must agree on the tmux
# session and window names, since that agreement is what replaced the
# fragile positional window indexing. A regression here is silent: the
# commands report "nothing to stop" and leave the DAQ running.
# --------------------------------------------------------------------------


def test_stop_daq_resolves_the_full_session_name():
    """Regression: shellcheck SC2318.

    stop_partition() built the session name with
    ``local target="$1" session="daq-$target"``. A variable assigned in a
    'local' is not visible to a later assignment in that same 'local', so
    session expanded to "daq-" and the command reported that there was
    nothing to stop while ots kept running.
    """
    result = subprocess.run(
        [str(REPO_ROOT / "stop-daq.sh"), "-n", "-y", "-z", "partition_0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    output = result.stdout.decode()
    if "tmux is not installed" in output:
        pytest.skip("tmux is not available")
    assert result.returncode == 0, output
    assert "daq-partition_0" in output, output
    # The truncated name must not appear as a whole session name.
    assert "session daq-," not in output
    assert "session daq- " not in output
    assert "no tmux session daq-\n" not in output


def test_start_and_stop_agree_on_window_names():
    """The window names start-daq.sh creates are the ones stop-daq.sh targets."""
    start = subprocess.run(
        [str(REPO_ROOT / "start-daq.sh"), "-n", "-z", "partition_0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    output = start.stdout.decode()
    if "tmux is not installed" in output:
        pytest.skip("tmux is not available")
    assert start.returncode == 0, output

    # start-daq.sh names each window daq-<partition>-<environment>.
    windows = set(re.findall(r"daq-partition_0-[a-z]+", output))
    assert windows, output

    status = subprocess.run(
        [str(REPO_ROOT / "scripts/daq-status.sh"), "-z", "partition_0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
    )
    status_windows = set(
        re.findall(r"daq-partition_0-[a-z]+", status.stdout.decode())
    )
    assert windows == status_windows, (
        f"start-daq.sh builds {windows}, daq-status.sh looks for {status_windows}"
    )
