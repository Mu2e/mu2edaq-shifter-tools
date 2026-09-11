"""Copy files to the same location on many DAQ cluster nodes at once.

The node inventory lives in ``data/daq_nodes.json``, grouped by
subsystem (``daq``, ``trk``, ``crv``, ``calo``). Copies run in parallel
over a thread pool, one ``scp`` per file per host.

See daq-cluster-cp(1).
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import click

from . import config as cfg

#: Name of the node inventory in the data directory.
NODES_FILE = "daq_nodes.json"

#: Subsystem groups, in the order they are reported.
GROUPS = ("daq", "trk", "crv", "calo")


def load_nodes(explicit: Optional[str] = None) -> Dict[str, List[str]]:
    """Load the node inventory.

    :param explicit: path to an alternative inventory file.
    :raises cfg.ConfigError: if the file is missing or malformed.
    """
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise cfg.ConfigError(f"node inventory not found: {path}")
    else:
        path = cfg.data_file(NODES_FILE)

    try:
        with open(path, "r") as stream:
            loaded = json.load(stream)
    except OSError as exc:
        raise cfg.ConfigError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise cfg.ConfigError(f"cannot parse {path}: {exc}") from exc

    if not isinstance(loaded, dict):
        raise cfg.ConfigError(f"{path}: expected an object of node groups")
    return {str(k): list(v) for k, v in loaded.items()}


def select_hosts(
    nodes: Dict[str, List[str]], groups: Sequence[str], want_all: bool
) -> List[str]:
    """Return the hosts for the requested groups, de-duplicated.

    With no group selected and ``want_all`` false the result is empty;
    the caller decides whether that is an error. Order follows
    :data:`GROUPS` so the output is stable.
    """
    chosen = set(nodes.keys()) if want_all else set(groups)
    hosts: List[str] = []
    seen = set()
    ordered = [g for g in GROUPS if g in chosen]
    ordered += [g for g in sorted(chosen) if g not in GROUPS]
    for group in ordered:
        for host in nodes.get(group, []):
            if host not in seen:
                seen.add(host)
                hosts.append(host)
    return hosts


def copy_to_host(
    files: Sequence[str],
    host: str,
    user: Optional[str],
    destination: str,
    verbose: bool,
    dry_run: bool,
) -> int:
    """scp every file to one host in a single invocation.

    Returns the ``scp`` exit status, or 0 for a dry run. Passing all the
    files at once means one ssh handshake per host instead of one per
    file.
    """
    target = f"{user}@{host}:{destination}" if user else f"{host}:{destination}"
    command = ["scp", "-B", "-q", *files, target]

    if dry_run:
        click.echo(f"  + {shlex.join(command)}")
        return 0

    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
        )
    except OSError as exc:
        click.echo(f"  {host}: cannot run scp: {exc}", err=True)
        return 1

    if completed.returncode != 0:
        detail = (completed.stdout or "").strip()
        click.echo(
            f"  {host}: FAILED (exit {completed.returncode})"
            + (f": {detail}" if detail else ""),
            err=True,
        )
    elif verbose:
        click.echo(f"  {host}: ok")
    return completed.returncode


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.option("--daq", "-d", is_flag=True, help="Copy to the DAQ nodes.")
@click.option("--trk", "-t", is_flag=True, help="Copy to the tracker nodes.")
@click.option("--crv", "-C", is_flag=True, help="Copy to the CRV nodes.")
@click.option("--calo", "-c", is_flag=True, help="Copy to the calorimeter nodes.")
@click.option("--all", "-a", "want_all", is_flag=True, help="Copy to every node.")
@click.option(
    "--user",
    "-u",
    default=None,
    help="ssh username (env MU2EDAQ_CLUSTER_USER; default: your local user).",
)
@click.option(
    "--nodes-file",
    default=None,
    help=f"Alternative node inventory (default: {NODES_FILE} from the data directory).",
)
@click.option(
    "--jobs",
    "-j",
    type=int,
    default=None,
    help="Parallel copies (env MU2EDAQ_CLUSTER_JOBS, default 16).",
)
@click.option("--verbose", "-v", is_flag=True, help="Report each successful copy.")
@click.option(
    "--dry-run", "-n", is_flag=True, help="Print the scp commands, copy nothing."
)
@click.version_option(package_name="mu2edaq-shifter-tools", prog_name="daq-cluster-cp")
@click.argument("files", nargs=-1, required=True, type=click.Path())
@click.argument("destination", nargs=1)
def main(
    daq: bool,
    trk: bool,
    crv: bool,
    calo: bool,
    want_all: bool,
    user: Optional[str],
    nodes_file: Optional[str],
    jobs: Optional[int],
    verbose: bool,
    dry_run: bool,
    files: Sequence[str],
    destination: str,
) -> None:
    """Copy FILES to DESTINATION on every selected cluster node.

    With no group flag, --all is assumed.
    """
    dotenv = cfg.load_dotenv()

    resolved_user = cfg.resolve(
        cli=user,
        env_var=cfg.ENV_PREFIX + "CLUSTER_USER",
        dotenv=dotenv,
        default=os.environ.get("USER"),
    )
    resolved_jobs = int(
        cfg.resolve(
            cli=jobs,
            env_var=cfg.ENV_PREFIX + "CLUSTER_JOBS",
            dotenv=dotenv,
            default=16,
        )
    )

    missing = [f for f in files if not Path(f).exists()]
    if missing:
        click.echo("daq-cluster-cp: no such file(s): " + ", ".join(missing), err=True)
        sys.exit(2)

    try:
        nodes = load_nodes(nodes_file)
    except cfg.ConfigError as exc:
        click.echo(f"daq-cluster-cp: {exc}", err=True)
        sys.exit(1)

    groups = [
        name
        for name, selected in (
            ("daq", daq),
            ("trk", trk),
            ("crv", crv),
            ("calo", calo),
        )
        if selected
    ]
    # Selecting nothing means everything, as it always has.
    if not groups and not want_all:
        want_all = True

    hosts = select_hosts(nodes, groups, want_all)
    if not hosts:
        click.echo("daq-cluster-cp: no hosts selected", err=True)
        sys.exit(1)

    click.echo(
        f"Copying {len(files)} file(s) to {destination} on {len(hosts)} host(s)"
        + (f" as {resolved_user}" if resolved_user else "")
    )
    if verbose or dry_run:
        click.echo("Hosts: " + " ".join(hosts))

    failures = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=resolved_jobs) as pool:
        futures = {
            pool.submit(
                copy_to_host,
                list(files),
                host,
                resolved_user,
                destination,
                verbose,
                dry_run,
            ): host
            for host in hosts
        }
        for future in concurrent.futures.as_completed(futures):
            if future.result() != 0:
                failures += 1

    if dry_run:
        click.echo("Dry run: nothing was copied.")
        return

    if failures:
        click.echo(f"\n{failures} of {len(hosts)} host(s) failed.", err=True)
        sys.exit(1)
    click.echo(f"\nAll {len(hosts)} host(s) succeeded.")


if __name__ == "__main__":
    main()
