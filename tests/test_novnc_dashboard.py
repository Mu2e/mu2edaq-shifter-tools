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
    remotes="",
):
    """tunnel is (ssh user, jump host, remote port, ssh pid); native is the
    "account@host=local_port:display ..." map the script passes, and
    remotes its "host|ssh_user|jump|pid ..." list of extra ssh connections."""
    portal = tmp_path / "portal.html"
    portal.write_text(PORTAL)
    out = tmp_path / "dashboard.html"
    result = subprocess.run(
        [sys.executable, "-", portal.as_uri(), str(out), password, str(sessions), host]
        + list(tunnel)
        + [native, remotes],
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
    # mu2etrig on other-host is a session of its own (no portal link), so the
    # portal's mu2etrig still follows as an unlisted portal session.
    assert card_names(page) == [
        "mu2eshift",
        "mu2etrig",
        "mu2ecr01",
        "mu2edcs",
        "mu2etrig",
    ]
    assert '<div class="card-host">mu2e-mgr-01.fnal.gov:2</div>' in page
    assert '<div class="card-host">other-host.fnal.gov</div>' in page
    assert "Shift main desktop." in page
    assert "Trigger &lt;desk&gt; &amp; co." in page, "descriptions must be HTML-escaped"
    assert (
        page.count("no description configured") == 3
    )  # the three unlisted portal cards


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
        ("just a string\n", "has no 'groups:' or 'sessions:' list"),
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
    labels = [group["label"] for group in data["groups"]]
    assert labels == ["mu2e-mgr-01 (MC-2)", "MC-1 Control Room"]
    keys = [
        (entry["account"], entry.get("host", ""))
        for g in data["groups"]
        for entry in g["sessions"]
    ]
    assert len(keys) == len(set(keys)), "duplicate account@host in the shipped file"
    for group in data["groups"]:
        for entry in group["sessions"]:
            assert entry.get("description"), f"{entry['account']} has no description"
            if "host" not in entry:  # a portal session: needs its display
                assert isinstance(entry.get("display"), int)
    mc1 = data["groups"][1]["sessions"]
    assert [e["host"] for e in mc1] == [
        "mu2e-mc1-cr-0%d.fnal.gov" % n for n in (1, 2, 3, 4)
    ]
    assert {e["account"] for e in mc1} == {"mu2eshift"}


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
  - {account: elsewhere, display: 4, host: other.fnal.gov, ssh_user: me, jump: gw.fnal.gov}
  - {account: bad, display: "two"}
""",
    )
    result, rows = plan(sessions)
    assert result.returncode == 0, result.stderr.decode()
    # account, host, display, port, ssh_user, jump
    assert [(r[0], r[1], r[2], r[4], r[5]) for r in rows] == [
        ("mu2eshift", "mu2e-mgr-01.fnal.gov", "2", "-", "-"),
        ("mu2edcs", "mu2e-mgr-01.fnal.gov", "1", "-", "-"),
        ("elsewhere", "other.fnal.gov", "4", "me", "gw.fnal.gov"),
    ]
    ports = [r[3] for r in rows]
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
        native="mu2eshift@mu2e-mgr-01.fnal.gov=61002:2",
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


def test_card_tunnel_details_are_collapsible_and_start_collapsed(tmp_path):
    result, page = render(tmp_path, native="mu2eshift@mu2e-mgr-01.fnal.gov=61002:2")
    assert result.returncode == 0, result.stderr.decode()
    sections = re.findall(r'<details class="card-tunnel"([^>]*)>', page)
    assert len(sections) == 4, "one collapsible tunnel section per card"
    assert all("open" not in attrs for attrs in sections), "must start collapsed"
    assert page.count("<summary>Tunnel details</summary>") == 4
    # The native forward lives inside the collapsed section.
    body = page[page.index('<details class="card-tunnel"') :]
    assert "open vnc://localhost:61002" in body


def test_a_malformed_native_map_is_ignored(tmp_path):
    result, page = render(
        tmp_path,
        native="mu2eshift=61002:2 mu2eshift@mu2e-mgr-01.fnal.gov=notaport:2 =1:2 mu2edcs@mu2e-mgr-01.fnal.gov=61001:x",
    )
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
        r"native mu2eshift@mu2e-mgr-01.fnal.gov -> vnc://localhost:\d+ \(mu2e-mgr-01.fnal.gov:5902\)",
        out,
    )

    off = subprocess.run(
        [str(SCRIPT), "-n", "-p", "45000", "-c", str(sessions), "--no-native"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(tmp_path),
    )
    assert "5902" not in off.stdout.decode()


GROUPED = """
groups:
  - label: Manager
    sessions:
      - {account: mu2eshift, display: 2, description: Shift main.}
      - {account: mu2edcs, display: 1}
  - label: MC-1 Control Room
    sessions:
      - {account: mu2eshift, host: mu2e-mc1-cr-01.fnal.gov, display: 2, description: Console 1.}
      - {account: mu2eshift, host: mu2e-mc1-cr-02.fnal.gov, description: Console 2.}
"""


def group_layout(page):
    """[(label, [card names])] in page order."""
    layout = []
    for section in re.findall(r'<section class="group">(.*?)</section>', page, re.S):
        label = re.search(r'<h2 class="group-label">([^<]*)</h2>', section)
        layout.append((label.group(1) if label else "", card_names(section)))
    return layout


def test_groups_render_in_order_under_their_labels(tmp_path):
    result, page = render(tmp_path, write_sessions(tmp_path, GROUPED))
    assert result.returncode == 0, result.stderr.decode()
    assert group_layout(page) == [
        ("Manager", ["mu2eshift", "mu2edcs"]),
        ("MC-1 Control Room", ["mu2eshift", "mu2eshift"]),
        # Portal sessions the file does not name get a group of their own.
        ("Other sessions on mu2e-mgr-01.fnal.gov", ["mu2ecr01", "mu2etrig"]),
    ]
    # The separator rule applies between consecutive groups.
    assert ".group + .group" in page and "border-top" in page


def test_a_flat_sessions_list_is_one_unlabeled_group(tmp_path):
    sessions = write_sessions(tmp_path, "sessions:\n  - {account: mu2etrig}\n")
    result, page = render(tmp_path, sessions)
    assert result.returncode == 0
    assert group_layout(page) == [
        ("", ["mu2etrig", "mu2ecr01", "mu2edcs", "mu2eshift"])
    ]
    assert '<h2 class="group-label">' not in page


def test_a_session_on_another_host_gets_its_own_card(tmp_path):
    result, page = render(
        tmp_path,
        write_sessions(tmp_path, GROUPED),
        native="mu2eshift@mu2e-mc1-cr-01.fnal.gov=62001:2",
        remotes="mu2e-mc1-cr-01.fnal.gov|mu2eshift|mu2egateway01.fnal.gov|777",
    )
    assert result.returncode == 0, result.stderr.decode()
    mc1 = page[page.index('<h2 class="group-label">MC-1 Control Room</h2>') :]
    first = mc1[: mc1.index('<div class="card">', mc1.index('<div class="card">') + 1)]
    # No portal link: the header is not a link and the browser button is off.
    assert '<div class="card-main">' in first
    assert '<span class="btn btn-off" title="not on the noVNC portal' in first
    # Its native link and forward, through its own ssh.
    assert 'href="vnc://localhost:62001"' in first
    assert "<code>mu2e-mc1-cr-01.fnal.gov:5902</code>" in first
    assert "own ssh to this host" in first
    # The console without a display has nothing to connect to yet.
    second = mc1[len(first) :]
    assert "no display configured" in second and "vnc://" not in second
    # The tunnel panel lists the extra ssh with its command.
    assert "<code>mu2eshift@mu2e-mc1-cr-01.fnal.gov</code>" in page
    assert "pid 777" in page
    assert (
        "ssh -N -J mu2egateway01.fnal.gov -L 62001:localhost:5902 "
        "mu2eshift@mu2e-mc1-cr-01.fnal.gov" in page
    )


def test_dry_run_opens_one_extra_ssh_per_other_host(tmp_path):
    env = {
        k: v for k, v in os.environ.items() if not k.startswith(("MU2EDAQ_", "NOVNC_"))
    }
    env["HOME"] = str(tmp_path)
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "")
    sessions = write_sessions(
        tmp_path,
        """
groups:
  - sessions:
      - {account: mu2eshift, display: 2}
      - {account: a, host: far.fnal.gov, display: 1, ssh_user: mu2eshift, jump: gw.fnal.gov}
      - {account: b, host: far.fnal.gov, display: 3}
      - {account: c, host: near.fnal.gov, display: 2}
""",
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
    lines = [line for line in out.splitlines() if line.startswith("ssh ")]
    assert len(lines) == 3, out  # the portal ssh plus one per other host
    assert re.search(
        r"-L 45000:localhost:443 -L \d+:localhost:5902 \S+@mu2e-mgr-01", lines[0]
    )
    assert re.fullmatch(
        r"ssh -N -o ExitOnForwardFailure=yes -L \d+:localhost:5901 -L \d+:localhost:5903 "
        r"-J gw\.fnal\.gov mu2eshift@far\.fnal\.gov",
        lines[1],
    ), lines[1]
    assert re.fullmatch(
        r"ssh -N -o ExitOnForwardFailure=yes -L \d+:localhost:5902 near\.fnal\.gov",
        lines[2],
    ), lines[2]
    assert "native a@far.fnal.gov -> vnc://localhost:" in out
