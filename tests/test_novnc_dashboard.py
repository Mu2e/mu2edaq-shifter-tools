"""Tests for the noVNC session dashboard built by start-novnc-connection.sh.

The renderer is a Python heredoc inside the script. These tests extract that
exact text and run it against a session-list page served from a file:// URL,
so what is tested is what ships. No tunnel, portal or browser is involved.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "start-novnc-connection.sh"
SHIPPED = REPO_ROOT / "config" / "novnc-sessions.yaml"

PORTAL = """<!DOCTYPE html><html><body><ul>
<li><a href="/novnc/vnc.html?path=/novnc/websockify?token=aaa">mu2ecr01</a></li>
<li><a href="/novnc/vnc.html?path=/novnc/websockify?token=bbb">mu2edcs</a></li>
<li><a href="/novnc/vnc.html?path=/novnc/websockify?token=ccc">mu2eshift</a></li>
<li><a href="/novnc/vnc.html?path=/novnc/websockify?token=ddd">mu2etrig</a></li>
</ul></body></html>
"""


def renderer_source() -> str:
    text = SCRIPT.read_text()
    function = text[text.index("render_dashboard() {") :]
    match = re.search(r"<<'PY'\n(.*?)\nPY\n", function, re.S)
    assert match, "render_dashboard heredoc not found"
    return match.group(1)


def render(tmp_path, sessions="", host="mu2e-mgr-01.fnal.gov", password="", env=None):
    portal = tmp_path / "portal.html"
    portal.write_text(PORTAL)
    out = tmp_path / "dashboard.html"
    result = subprocess.run(
        [sys.executable, "-", portal.as_uri(), str(out), password, str(sessions), host],
        input=renderer_source().encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    page = out.read_text() if out.exists() else ""
    return result, page


def card_names(page: str) -> list:
    return re.findall(r'<div class="card-name">([^<]*)</div>', page)


def write_sessions(tmp_path, body: str) -> Path:
    path = tmp_path / "novnc-sessions.yaml"
    path.write_text(body)
    return path


def test_without_a_sessions_file_cards_follow_the_portal(tmp_path):
    result, page = render(tmp_path)
    assert result.returncode == 0, result.stderr.decode()
    assert card_names(page) == ["mu2ecr01", "mu2edcs", "mu2eshift", "mu2etrig"]
    assert page.count("no description configured") == 4
    assert page.count('<div class="card-host">mu2e-mgr-01.fnal.gov</div>') == 4


def test_sessions_file_sets_order_host_display_and_description(tmp_path):
    sessions = write_sessions(
        tmp_path,
        """
sessions:
  - account: mu2eshift
    display: 2
    description: Shift main desktop.
  - account: mu2etrig
    host: other-host.fnal.gov
    description: Trigger <desk> & co.
""",
    )
    result, page = render(tmp_path, sessions)
    assert result.returncode == 0, result.stderr.decode()
    # Listed sessions first in file order, then the rest in portal order.
    assert card_names(page) == ["mu2eshift", "mu2etrig", "mu2ecr01", "mu2edcs"]
    assert '<div class="card-host">mu2e-mgr-01.fnal.gov:2</div>' in page
    assert '<div class="card-host">other-host.fnal.gov</div>' in page
    assert "Shift main desktop." in page
    assert "Trigger &lt;desk&gt; &amp; co." in page, "descriptions must be HTML-escaped"
    assert page.count("no description configured") == 2


def test_an_entry_the_portal_does_not_offer_is_reported_and_skipped(tmp_path):
    sessions = write_sessions(
        tmp_path,
        "sessions:\n  - {account: mu2eghost, description: x}\n  - {account: mu2edcs}\n",
    )
    result, page = render(tmp_path, sessions)
    assert result.returncode == 0
    assert "mu2eghost" not in card_names(page)
    assert card_names(page)[0] == "mu2edcs"
    assert "'mu2eghost', which the portal does not offer" in result.stderr.decode()


@pytest.mark.parametrize(
    "body, message",
    [
        ("sessions: [unclosed\n", "cannot read"),
        ("just a string\n", "has no 'sessions:' list"),
        ("sessions:\n  - {description: no account}\n", "has no 'account'"),
    ],
)
def test_a_bad_sessions_file_warns_but_still_renders(tmp_path, body, message):
    result, page = render(tmp_path, write_sessions(tmp_path, body))
    assert result.returncode == 0
    assert message in result.stderr.decode()
    assert card_names(page) == ["mu2ecr01", "mu2edcs", "mu2eshift", "mu2etrig"]


def test_without_pyyaml_the_file_is_ignored_with_a_warning(tmp_path):
    # A yaml.py that refuses to import stands in for a missing PyYAML.
    shadow = tmp_path / "shadow"
    shadow.mkdir()
    (shadow / "yaml.py").write_text("raise ImportError('no PyYAML here')\n")
    env = dict(os.environ, PYTHONPATH=str(shadow))
    sessions = write_sessions(tmp_path, "sessions:\n  - {account: mu2etrig}\n")
    result, page = render(tmp_path, sessions, env=env)
    assert result.returncode == 0, result.stderr.decode()
    assert "PyYAML is not installed" in result.stderr.decode()
    assert card_names(page) == ["mu2ecr01", "mu2edcs", "mu2eshift", "mu2etrig"]


def test_password_links_still_autoconnect(tmp_path):
    result, page = render(tmp_path, password="s3cret&x")
    assert result.returncode == 0
    assert "password=s3cret%26x&amp;autoconnect=true" in page


def test_shipped_sessions_file_is_well_formed():
    data = yaml.safe_load(SHIPPED.read_text())
    accounts = [entry["account"] for entry in data["sessions"]]
    assert len(accounts) == len(set(accounts)), "duplicate account in the shipped file"
    for entry in data["sessions"]:
        assert entry.get("description"), f"{entry['account']} has no description"
        assert isinstance(entry.get("display"), int)


def test_dry_run_names_the_sessions_file_and_rejects_a_missing_one(tmp_path):
    env = {
        k: v for k, v in os.environ.items() if not k.startswith(("MU2EDAQ_", "NOVNC_"))
    }
    env["HOME"] = str(tmp_path)
    ok = subprocess.run(
        [str(SCRIPT), "-n", "-p", "45000", "-c", str(SHIPPED)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(tmp_path),
    )
    assert ok.returncode == 0, ok.stdout.decode()
    assert f"sessions -> {SHIPPED}" in ok.stdout.decode()

    missing = subprocess.run(
        [str(SCRIPT), "-n", "-c", str(tmp_path / "nope.yaml")],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(tmp_path),
    )
    assert missing.returncode != 0
    assert "sessions file not found" in missing.stdout.decode()


def test_default_sessions_file_is_found_from_the_checkout(tmp_path):
    env = {
        k: v for k, v in os.environ.items() if not k.startswith(("MU2EDAQ_", "NOVNC_"))
    }
    env["HOME"] = str(tmp_path)
    result = subprocess.run(
        [str(SCRIPT), "-n", "-p", "45000"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(tmp_path),
    )
    assert result.returncode == 0, result.stdout.decode()
    assert "sessions -> " in result.stdout.decode()
    assert result.stdout.decode().rstrip().endswith("config/novnc-sessions.yaml")
