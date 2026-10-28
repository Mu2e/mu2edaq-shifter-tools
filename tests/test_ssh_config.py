"""Tests for the client-side ssh setup: install-ssh-config.sh, the
config/ssh-config-mu2e.in template it renders, and daq-ssh-check.sh.

Everything runs against files in a temporary directory with HOME pointed
there, so the developer's own ~/.ssh is never read or written. Host
resolution uses "ssh -G -F <file>", which reads only that file and opens
no connection.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALLER = REPO_ROOT / "install-ssh-config.sh"
CHECK = REPO_ROOT / "scripts" / "daq-ssh-check.sh"
TEMPLATE = REPO_ROOT / "config" / "ssh-config-mu2e.in"
SSH = shutil.which("ssh")

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash is not available")
needs_ssh = pytest.mark.skipif(SSH is None, reason="ssh is not available")


def install(tmp_path: Path, *args: str, ssh_config: Path | None = None):
    """Run the installer non-interactively with every path under tmp_path."""
    home = tmp_path / "home"
    (home / ".ssh").mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("MU2EDAQ_", "NOVNC_"))}
    env["HOME"] = str(home)
    cmd = [
        str(INSTALLER),
        "-y",
        "-c", str(ssh_config or home / ".ssh" / "config"),
        "-o", str(home / ".ssh" / "config_mu2e"),
        "-e", str(home / ".mu2edaq" / "env"),
    ] + list(args)
    result = subprocess.run(
        cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env
    )
    return result, home


def resolve(config: Path, host: str) -> dict:
    out = subprocess.run(
        [SSH, "-G", "-F", str(config), host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    ).stdout.decode()
    settings = {}
    for line in out.splitlines():
        key, _, value = line.partition(" ")
        settings.setdefault(key, value)
    return settings


def test_template_has_no_catch_all_and_no_global_overrides():
    text = TEMPLATE.read_text()
    hosts = [line.split()[1:] for line in text.splitlines() if line.startswith("Host ")]
    patterns = {p for line in hosts for p in line}
    assert "*" not in patterns
    assert "mu2e-*" not in patterns, "a catch-all mu2e-* block shadows the specific families"
    for keyword in ("StrictHostKeyChecking", "ForwardAgent", "Cipher "):
        assert keyword not in text, f"{keyword} must be left to the user's own config"


def test_fresh_install_writes_fragment_include_and_env(tmp_path):
    result, home = install(tmp_path, "-U", "jdoe")
    assert result.returncode == 0, result.stdout.decode()
    fragment = home / ".ssh" / "config_mu2e"
    assert "@MU2E_" not in fragment.read_text()
    assert oct(fragment.stat().st_mode & 0o777) == "0o600"
    first_lines = (home / ".ssh" / "config").read_text().splitlines()[:3]
    assert "Include ~/.ssh/config_mu2e" in first_lines
    env_text = (home / ".mu2edaq" / "env").read_text()
    assert "NOVNC_USER=jdoe" in env_text
    assert "MU2EDAQ_KRB5_PRINCIPAL=jdoe@FNAL.GOV" in env_text


def test_second_run_changes_nothing(tmp_path):
    install(tmp_path, "-U", "jdoe")
    result, home = install(tmp_path, "-U", "jdoe")
    assert result.returncode == 0
    assert not list((home / ".ssh").glob("*.bak.*")), "an unchanged rerun must not back up files"
    assert not list((home / ".mu2edaq").glob("*.bak.*"))
    assert (home / ".ssh" / "config").read_text().count("Include ~/.ssh/config_mu2e") == 1


def test_existing_config_is_backed_up_and_kept_below_the_include(tmp_path):
    home = tmp_path / "home"
    (home / ".ssh").mkdir(parents=True)
    (home / ".ssh" / "config").write_text("Host myhost\n    User me\n")
    result, home = install(tmp_path, "-U", "jdoe")
    assert result.returncode == 0
    text = (home / ".ssh" / "config").read_text()
    assert text.index("Include ~/.ssh/config_mu2e") < text.index("Host myhost")
    assert len(list((home / ".ssh").glob("config.bak.*"))) == 1


def test_include_inside_a_host_block_is_reported(tmp_path):
    home = tmp_path / "home"
    (home / ".ssh").mkdir(parents=True)
    (home / ".ssh" / "config").write_text("Host other\n    User me\nInclude ~/.ssh/config_mu2e\n")
    result, _ = install(tmp_path, "-U", "jdoe")
    assert result.returncode != 0
    assert "Move the Include above line 1" in result.stdout.decode()


def test_other_env_keys_are_preserved(tmp_path):
    env_file = tmp_path / "home" / ".mu2edaq" / "env"
    env_file.parent.mkdir(parents=True)
    env_file.write_text("NOVNC_PASSWORD_FILE=/x/y\nNOVNC_USER=old\n")
    result, _ = install(tmp_path, "-U", "jdoe")
    assert result.returncode == 0
    text = env_file.read_text()
    assert "NOVNC_PASSWORD_FILE=/x/y" in text
    assert "NOVNC_USER=jdoe" in text and "NOVNC_USER=old" not in text


@pytest.mark.parametrize("bad", ["x;rm", "Upper", "a b", "-x"])
def test_invalid_account_names_are_rejected(tmp_path, bad):
    result, home = install(tmp_path, "-U", "jdoe", "-D", bad)
    assert result.returncode != 0
    assert not (home / ".ssh" / "config_mu2e").exists()


def test_dry_run_changes_nothing(tmp_path):
    result, home = install(tmp_path, "-U", "jdoe", "-n")
    assert result.returncode == 0
    assert list((home / ".ssh").iterdir()) == []
    assert not (home / ".mu2edaq").exists()


@needs_ssh
@pytest.mark.parametrize(
    "host, user, jump",
    [
        ("mu2egateway01.fnal.gov", "mu2edaq", None),
        ("mu2egateway01", "mu2edaq", None),
        ("mu2e-mgr-01.fnal.gov", "mu2edaq", "mu2egateway01.fnal.gov"),
        ("mu2e-mgr-01", "mu2edaq", "mu2egateway01.fnal.gov"),
        ("mu2e-trk-01.fnal.gov", "mu2edaq", "mu2egateway01.fnal.gov"),
        ("mu2e-dl-01.fnal.gov", "mu2edaq", "mu2egateway01.fnal.gov"),
        ("mu2e-dcs-01.fnal.gov", "mu2edcs", "mu2egateway01.fnal.gov"),
        ("mu2e-mc1-cr-01.fnal.gov", "mu2eshift", "mu2egateway01.fnal.gov"),
        ("mu2e-mc1-worker-05", "mu2eshift", "g2gateway01.fnal.gov"),
        ("g2gateway01.fnal.gov", "mu2eshift", None),
        ("mu2edaq09.fnal.gov", "mu2edaq", "mu2edaq-gateway.fnal.gov"),
    ],
)
def test_rendered_fragment_routes_each_host_family(tmp_path, host, user, jump):
    _, home = install(tmp_path, "-U", "jdoe", "-I")
    settings = resolve(home / ".ssh" / "config_mu2e", host)
    assert settings["user"] == user
    assert settings.get("proxyjump") == jump
    assert settings["gssapiauthentication"] == "yes"
    assert settings["hostname"].endswith(".fnal.gov")


@needs_ssh
def test_account_answers_reach_the_fragment(tmp_path):
    _, home = install(tmp_path, "-U", "jdoe", "-I", "-D", "mu2etrk", "-S", "mu2ecr01", "-C", "mu2edcs2")
    fragment = home / ".ssh" / "config_mu2e"
    assert resolve(fragment, "mu2e-mgr-01.fnal.gov")["user"] == "mu2etrk"
    assert resolve(fragment, "mu2e-mc1-worker-01")["user"] == "mu2ecr01"
    assert resolve(fragment, "mu2e-dcs-01.fnal.gov")["user"] == "mu2edcs2"


@needs_ssh
def test_check_flags_a_proxyjump_through_the_teststand_gateway(tmp_path):
    bad = tmp_path / "bad_config"
    bad.write_text(
        "Host mu2e-*\n    ProxyJump mu2edaq@mu2edaq-gateway.fnal.gov\n"
        "    GSSAPIAuthentication yes\n"
    )
    env = {k: v for k, v in os.environ.items() if not k.startswith("MU2EDAQ_")}
    env["HOME"] = str(tmp_path)
    result = subprocess.run(
        [str(CHECK), "-s", "-F", str(bad), "-H", "mu2e-mgr-01.fnal.gov"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
    )
    output = result.stdout.decode()
    assert result.returncode == 1, output
    assert "expected mu2egateway01" in output


@needs_ssh
def test_check_accepts_the_rendered_fragment_statically(tmp_path):
    _, home = install(tmp_path, "-U", "jdoe", "-I")
    env = {k: v for k, v in os.environ.items() if not k.startswith("MU2EDAQ_")}
    env["HOME"] = str(tmp_path)
    result = subprocess.run(
        [str(CHECK), "-s", "-F", str(home / ".ssh" / "config_mu2e"),
         "-H", "mu2egateway01.fnal.gov mu2e-mgr-01.fnal.gov mu2e-mc1-worker-05"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
    )
    output = result.stdout.decode()
    # The Kerberos step depends on the machine running the tests, so only
    # the ssh-settings lines are asserted.
    settings = [line for line in output.splitlines() if "fnal.gov:" in line or "worker" in line]
    assert settings and all(line.startswith("PASS") for line in settings), output
