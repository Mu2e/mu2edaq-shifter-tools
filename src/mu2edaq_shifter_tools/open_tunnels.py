"""Open, list, and tear down the SSH tunnels for the Mu2e shifter GUIs.

Tunnel definitions come from ``config/tunnels.yaml``; see that file for
the schema. Local ports are ``base_port + port``, where ``base_port``
defaults to ``uid + 973`` so that two users on the same machine do not
collide.

Running tunnels are tracked in a small state file (one CSV record per
tunnel) so that ``list`` and ``kill`` can find them again in a later
shell.

See daq-open-tunnels(1).
"""

from __future__ import annotations

import os
import shlex
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import click

from . import config as cfg

#: Fields written to the state file, in order.
STATE_FIELDS = ("pid", "hostname", "username", "local_port", "label")


def default_base_port() -> int:
    """Return the default local port base: the user's uid plus 973.

    Mu2e is Fermilab experiment E-973; adding the uid keeps concurrent
    users on a shared shifter machine out of each other's way.
    """
    return os.getuid() + 973


def default_state_file() -> Path:
    """Return the path of the tunnel state file.

    ``$MU2EDAQ_TUNNEL_STATE`` overrides it. The default lives under the
    user's home rather than the current directory, so that ``kill`` works
    from anywhere -- the old behaviour of writing ``.open_tunnel_pids``
    into ``$PWD`` meant tunnels became unfindable after a ``cd``.
    """
    override = os.environ.get(cfg.ENV_PREFIX + "TUNNEL_STATE")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".mu2edaq" / "open_tunnels"


def read_state(path: Path) -> List[Dict[str, str]]:
    """Read the tunnel state file, tolerating the legacy 4-field format."""
    if not path.is_file():
        return []
    records: List[Dict[str, str]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [item.strip() for item in line.split(",")]
        # The original file had no label column.
        while len(parts) < len(STATE_FIELDS):
            parts.append("")
        records.append(dict(zip(STATE_FIELDS, parts)))
    return records


def write_state(path: Path, records: List[Dict[str, str]]) -> None:
    """Write the tunnel state file, creating its directory if needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# pid, hostname, username, local_port, label"]
    lines += [
        ", ".join(str(record.get(field, "")) for field in STATE_FIELDS)
        for record in records
    ]
    path.write_text("\n".join(lines) + "\n")


def process_alive(pid: str) -> bool:
    """Return True if the given pid is a live process owned by this user."""
    try:
        os.kill(int(pid), 0)
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        # It exists but belongs to somebody else.
        return True
    return True


def ssh_command(
    tunnel: Dict[str, Any], base_port: int, username: Optional[str]
) -> List[str]:
    """Build the ssh command line for one tunnel definition."""
    offset = int(tunnel["port"])
    local_port = base_port + offset
    user = username or tunnel.get("username") or os.environ.get("USER") or ""
    remote_host = tunnel.get("remote", "localhost")
    target = f"{user}@{tunnel['hostname']}" if user else str(tunnel["hostname"])

    command = ["ssh", "-N", "-o", "ExitOnForwardFailure=yes"]
    if tunnel.get("jump"):
        command += ["-J", str(tunnel["jump"])]
    command += ["-L", f"{local_port}:{remote_host}:{local_port}", target]
    return command


def describe(record: Dict[str, str], colour: bool = True) -> str:
    """Format one state record for the ``list`` output."""
    alive = process_alive(record["pid"])
    if colour:
        status = "\033[92mACTIVE\033[0m" if alive else "\033[91mNOT ACTIVE\033[0m"
    else:
        status = "ACTIVE" if alive else "NOT ACTIVE"
    label = record.get("label") or "-"
    return (
        f"{label:<16} pid {record['pid']:<8} "
        f"{record['username']}@{record['hostname']} "
        f"localhost:{record['local_port']}  {status}"
    )


def show_gui(records: List[Dict[str, str]]) -> int:
    """Show the tunnel list in a Qt dialog.

    PyQt is imported lazily: the tunnel machinery itself is headless, and
    a shifter on a text-only session should not need Qt installed.
    """
    try:
        from PyQt5.QtWidgets import QApplication, QMessageBox
    except ImportError:
        click.echo(
            "daq-open-tunnels: PyQt5 is not installed; "
            "run bootstrap.sh or drop --gui",
            err=True,
        )
        return 1

    app = QApplication(sys.argv[:1])
    box = QMessageBox()
    box.setWindowTitle("Active SSH Tunnels")
    if records:
        body = "\n".join(describe(r, colour=False) for r in records)
        box.setText("Active SSH tunnels:\n\n" + body)
    else:
        box.setText("No tunnels are recorded.")
    box.setStandardButtons(QMessageBox.Ok)
    box.exec_()
    del app
    return 0


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.option(
    "--config",
    "-c",
    "config_file",
    default=None,
    help="Tunnel definitions to read (default: tunnels.yaml on the search path).",
)
@click.option(
    "--state-file",
    "-s",
    default=None,
    help="Where to record running tunnels (env MU2EDAQ_TUNNEL_STATE).",
)
@click.option(
    "--base-port",
    "-b",
    type=int,
    default=None,
    help="Local port base (env MU2EDAQ_TUNNEL_BASE_PORT, default uid + 973).",
)
@click.option(
    "--user",
    "-u",
    default=None,
    help="Override the ssh username for every tunnel.",
)
@click.option("--gui", is_flag=True, help="Show the list in a Qt window.")
@click.option(
    "--dry-run", "-n", is_flag=True, help="Print what would happen, change nothing."
)
@click.version_option(
    package_name="mu2edaq-shifter-tools", prog_name="daq-open-tunnels"
)
@click.argument("action", type=click.Choice(["open", "kill", "list"]), default="list")
def main(
    config_file: Optional[str],
    state_file: Optional[str],
    base_port: Optional[int],
    user: Optional[str],
    gui: bool,
    dry_run: bool,
    action: str,
) -> None:
    """Manage the shifter SSH tunnels.

    ACTION is one of open, kill, or list (the default).
    """
    dotenv = cfg.load_dotenv()

    state_path = Path(
        cfg.resolve(
            cli=state_file,
            env_var=cfg.ENV_PREFIX + "TUNNEL_STATE",
            dotenv=dotenv,
            default=str(default_state_file()),
        )
    ).expanduser()

    resolved_base = int(
        cfg.resolve(
            cli=base_port,
            env_var=cfg.ENV_PREFIX + "TUNNEL_BASE_PORT",
            dotenv=dotenv,
            default=default_base_port(),
        )
    )

    if action == "list":
        records = read_state(state_path)
        if gui:
            sys.exit(show_gui(records))
        if not records:
            click.echo(f"No tunnels recorded in {state_path}.")
            return
        click.echo(f"Tunnels recorded in {state_path}:")
        for record in records:
            click.echo("  " + describe(record))
        return

    if action == "kill":
        records = read_state(state_path)
        if not records:
            click.echo(f"No tunnels recorded in {state_path}.")
            return
        remaining: List[Dict[str, str]] = []
        for record in records:
            pid = record["pid"]
            if not process_alive(pid):
                click.echo(f"  pid {pid} is already gone")
                continue
            if dry_run:
                click.echo(f"  + kill {pid} ({record['hostname']})")
                remaining.append(record)
                continue
            try:
                os.kill(int(pid), signal.SIGTERM)
                click.echo(f"  killed pid {pid} ({record['hostname']})")
            except (ValueError, OSError) as exc:
                click.echo(f"  could not kill pid {pid}: {exc}", err=True)
                remaining.append(record)
        if not dry_run:
            write_state(state_path, remaining)
        return

    # action == "open"
    try:
        tunnels = cfg.load_tunnels(
            cfg.resolve(
                cli=config_file,
                env_var=cfg.ENV_PREFIX + "TUNNELS",
                dotenv=dotenv,
                default=None,
            )
        )
    except cfg.ConfigError as exc:
        click.echo(f"daq-open-tunnels: {exc}", err=True)
        sys.exit(1)

    # Two definitions resolving to the same local port cannot both be
    # forwarded; with ExitOnForwardFailure the second ssh just dies, which
    # is hard to spot in a wall of output. Say so up front.
    by_port: Dict[int, List[str]] = {}
    for tunnel in tunnels:
        local = resolved_base + int(tunnel["port"])
        by_port.setdefault(local, []).append(
            str(tunnel.get("label") or tunnel["hostname"])
        )
    for local, labels in sorted(by_port.items()):
        if len(labels) > 1:
            click.echo(
                f"warning: local port {local} is claimed by "
                f"{len(labels)} tunnels ({', '.join(labels)}); "
                "only the first will bind",
                err=True,
            )

    existing = [r for r in read_state(state_path) if process_alive(r["pid"])]
    if existing:
        click.echo(
            f"{len(existing)} tunnel(s) already running; "
            f"run 'daq-open-tunnels kill' first if you want to replace them."
        )

    records = list(existing)
    for tunnel in tunnels:
        command = ssh_command(tunnel, resolved_base, user)
        local_port = resolved_base + int(tunnel["port"])
        label = tunnel.get("label") or tunnel["hostname"]

        if dry_run:
            click.echo(f"  + {shlex.join(command)}")
            continue

        try:
            process = subprocess.Popen(command)
        except OSError as exc:
            click.echo(f"daq-open-tunnels: cannot start ssh: {exc}", err=True)
            sys.exit(1)

        click.echo(
            f"  {label}: localhost:{local_port} -> "
            f"{tunnel['hostname']} (pid {process.pid})"
        )
        records.append(
            {
                "pid": str(process.pid),
                "hostname": str(tunnel["hostname"]),
                "username": str(
                    user or tunnel.get("username") or os.environ.get("USER", "")
                ),
                "local_port": str(local_port),
                "label": str(label),
            }
        )

    if dry_run:
        click.echo("Dry run: no tunnels were opened.")
        return

    write_state(state_path, records)
    click.echo(f"\nRecorded {len(records)} tunnel(s) in {state_path}.")


if __name__ == "__main__":
    main()
