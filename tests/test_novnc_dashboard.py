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


def render(
    tmp_path,
    sessions="",
    host="mu2e-mgr-01.fnal.gov",
    password="",
    env=None,
    tunnel=("", "", "", ""),
    native="",
):
    """tunnel is (ssh user, jump host, remote port, ssh pid); native is the
    "account=local_port:display ..." map the script passes."""
    portal = tmp_path / "portal.html"
    portal.write_text(PORTAL)
    out = tmp_path / "dashboard.html"
    result = subprocess.run(
        [sys.executable, "-", portal.as_uri(), str(out), password, str(sessions), host]
        + list(tunnel)
        + [native],
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
    assert re.search(
        r"^sessions -> .*config/novnc-sessions\.yaml$", result.stdout.decode(), re.M
    ), result.stdout.decode()


def plan_source() -> str:
    text = SCRIPT.read_text()
    function = text[text.index("plan_native_forwards() {") :]
    return re.search(r"<<'PY'\n(.*?)\nPY\n", function, re.S).group(1)


def plan(sessions, host="mu2e-mgr-01.fnal.gov", avoid="0", env=None):
    result = subprocess.run(
        [sys.executable, "-", str(sessions), host, avoid],
        input=plan_source().encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    rows = [line.split() for line in result.stdout.decode().splitlines()]
    return result, rows


def test_native_forwards_are_planned_for_sessions_with_a_display_on_this_host(tmp_path):
    sessions = write_sessions(
        tmp_path,
        """
sessions:
  - {account: mu2eshift, display: 2}
  - {account: mu2edcs, display: 1, host: mu2e-mgr-01.fnal.gov}
  - {account: mu2etrig}
  - {account: elsewhere, display: 4, host: other.fnal.gov}
  - {account: bad, display: "two"}
""",
    )
    result, rows = plan(sessions)
    assert result.returncode == 0, result.stderr.decode()
    assert [(r[0], r[1]) for r in rows] == [("mu2eshift", "2"), ("mu2edcs", "1")]
    ports = [r[2] for r in rows]
    assert all(p.isdigit() for p in ports) and len(set(ports)) == len(ports)


def test_no_native_forwards_without_pyyaml(tmp_path):
    shadow = tmp_path / "shadow"
    shadow.mkdir()
    (shadow / "yaml.py").write_text("raise ImportError('no PyYAML here')\n")
    env = dict(os.environ, PYTHONPATH=str(shadow))
    sessions = write_sessions(
        tmp_path, "sessions:\n  - {account: mu2eshift, display: 2}\n"
    )
    result, rows = plan(sessions, env=env)
    assert result.returncode == 0
    assert rows == []
    assert "no native VNC links" in result.stderr.decode()


def test_cards_offer_native_vnc_and_show_their_tunnel(tmp_path):
    sessions = write_sessions(
        tmp_path,
        "sessions:\n  - {account: mu2eshift, display: 2}\n  - {account: mu2etrig}\n",
    )
    result, page = render(
        tmp_path,
        sessions,
        tunnel=("anorman", "mu2egateway01.fnal.gov", "443", "4242"),
        native="mu2eshift=61002:2",
    )
    assert result.returncode == 0, result.stderr.decode()
    # Native link and its forward on the card that has one.
    assert 'href="vnc://localhost:61002"' in page
    assert "open vnc://localhost:61002" in page
    assert (
        "<code>localhost:61002</code> &rarr; <code>mu2e-mgr-01.fnal.gov:5902</code>"
        in page
    )
    # The session without a display gets a disabled button saying why.
    assert page.count('class="btn btn-off"') == 3  # mu2etrig, mu2ecr01, mu2edcs
    assert "no display configured" in page
    # Tunnel panel.
    assert "<code>anorman@mu2e-mgr-01.fnal.gov</code>" in page
    assert "via <code>mu2egateway01.fnal.gov</code>" in page
    assert "pid 4242" in page
    assert "-J mu2egateway01.fnal.gov" in page and "-L 61002:localhost:5902" in page
    # Every card still has its noVNC browser link.
    assert page.count("Browser (noVNC)") == 4


def test_a_malformed_native_map_is_ignored(tmp_path):
    result, page = render(tmp_path, native="mu2eshift=notaport:2 =1:2 mu2edcs=61001:x")
    assert result.returncode == 0
    assert "vnc://" not in page


def test_dry_run_lists_the_native_forwards(tmp_path):
    env = {
        k: v for k, v in os.environ.items() if not k.startswith(("MU2EDAQ_", "NOVNC_"))
    }
    env["HOME"] = str(tmp_path)
    # The python3 that runs the tests has PyYAML; put it first on PATH.
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "")
    sessions = write_sessions(
        tmp_path, "sessions:\n  - {account: mu2eshift, display: 2}\n"
    )
    result = subprocess.run(
        [str(SCRIPT), "-n", "-p", "45000", "-c", str(sessions)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(tmp_path),
    )
    out = result.stdout.decode()
    assert result.returncode == 0, out
    assert re.search(r"-L 45000:localhost:443 -L \d+:localhost:5902 ", out), out
    assert re.search(
        r"native mu2eshift -> vnc://localhost:\d+ \(mu2e-mgr-01.fnal.gov:5902\)", out
    )

    off = subprocess.run(
        [str(SCRIPT), "-n", "-p", "45000", "-c", str(sessions), "--no-native"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(tmp_path),
    )
    assert "5902" not in off.stdout.decode()
