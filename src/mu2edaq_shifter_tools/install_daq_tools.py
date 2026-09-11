"""Validate a DAQ release description and prepare its install tree.

Reads a release YAML (``current_release.yaml`` by default) describing a
base release, a test release, and the directories the DAQ tools are
installed into, then reports the version strings it derives and checks
that every path exists. With ``--makedirs`` it creates the missing
install directories.

Release versions are written as structured fields rather than strings so
they can be compared and re-formatted::

    base_release:
      prefix: d
      major: 9
      minor: 0
      patch: 0
      suffix: ""
      path: /mu2e/releases/v9_00_00

which renders as ``d09_00_00``.

See daq-install-tools(1).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

import click

from . import config as cfg

#: Default release description file name.
DEFAULT_RELEASE_FILE = "current_release.yaml"

#: Zero-padding applied to each numeric version component.
VERSION_PAD = 2

#: Ordered version fields, with their defaults.
VERSION_SCHEMA: Dict[str, Any] = {
    "prefix": "d",
    "major": 0,
    "minor": 0,
    "patch": 0,
    "suffix": "",
}


def build_version_string(version: Mapping[str, Any]) -> str:
    """Render a version mapping as ``<prefix><major>_<minor>_<patch>[_<suffix>]``.

    Missing fields fall back to :data:`VERSION_SCHEMA`, so a release that
    only pins ``major`` still produces a usable string.
    """
    prefix = str(version.get("prefix", VERSION_SCHEMA["prefix"]))
    parts = [
        str(version.get(field, VERSION_SCHEMA[field])).rjust(VERSION_PAD, "0")
        for field in ("major", "minor", "patch")
    ]
    rendered = prefix + "_".join(parts)
    suffix = str(version.get("suffix", "") or "")
    if suffix:
        rendered = f"{rendered}_{suffix}"
    return rendered


def release_paths(config: Mapping[str, Any]) -> List[Tuple[str, Path]]:
    """Expand ``install_path`` into concrete directories.

    ``install_path.basepath`` is the root; every other key is joined onto
    it. Returns ``(label, path)`` pairs in a stable order.
    """
    install = config.get("install_path") or {}
    if not isinstance(install, Mapping):
        raise cfg.ConfigError("'install_path' must be a mapping")

    basepath = install.get("basepath")
    if not basepath:
        raise cfg.ConfigError("'install_path.basepath' is required")

    base = Path(str(basepath)).expanduser()
    paths: List[Tuple[str, Path]] = [("basepath", base)]
    for key, value in install.items():
        if key == "basepath":
            continue
        paths.append((str(key), base / str(value)))
    return paths


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.option(
    "--release-file",
    "-f",
    default=None,
    help=(
        f"Release description to read (default: {DEFAULT_RELEASE_FILE} "
        "from the config search path)."
    ),
)
@click.option(
    "--makedirs",
    "-M",
    is_flag=True,
    help="Create the install directories that do not exist yet.",
)
@click.option(
    "--override",
    "-O",
    is_flag=True,
    help="Warn instead of failing when a release path is missing.",
)
@click.option(
    "--dry-run", "-n", is_flag=True, help="Report only; never create a directory."
)
@click.version_option(
    package_name="mu2edaq-shifter-tools", prog_name="daq-install-tools"
)
def main(
    release_file: Optional[str], makedirs: bool, override: bool, dry_run: bool
) -> None:
    """Check a DAQ release description and its install tree."""
    try:
        path = cfg.find_config_file(DEFAULT_RELEASE_FILE, release_file)
        config = cfg.load_config(path)
    except cfg.ConfigError as exc:
        click.echo(f"daq-install-tools: {exc}", err=True)
        sys.exit(1)

    missing_keys = [
        key
        for key in ("base_release", "test_release", "install_path")
        if not config.get(key)
    ]
    if missing_keys:
        click.echo(
            "daq-install-tools: missing required field(s) in "
            f"{path}: {', '.join(missing_keys)}",
            err=True,
        )
        sys.exit(1)

    base_release = config["base_release"]
    test_release = config["test_release"]

    click.echo(f"Release description: {path}")
    click.echo("-" * 60)
    click.echo(f"Base release: {build_version_string(base_release)}")
    click.echo(f"        path: {base_release.get('path', '(unset)')}")
    click.echo(f"Test release: {build_version_string(test_release)}")
    click.echo(f"        path: {test_release.get('path', '(unset)')}")
    click.echo("-" * 60)

    problems = 0
    for label, release in (("base", base_release), ("test", test_release)):
        raw = release.get("path")
        if not raw:
            click.echo(f"WARNING: {label} release has no path", err=True)
            problems += 1
            continue
        if not Path(str(raw)).expanduser().exists():
            click.echo(f"WARNING: {label} release path does not exist: {raw}", err=True)
            problems += 1

    if problems and not override:
        click.echo(
            "daq-install-tools: release path(s) missing; "
            "pass --override to continue anyway",
            err=True,
        )
        sys.exit(1)

    try:
        paths = release_paths(config)
    except cfg.ConfigError as exc:
        click.echo(f"daq-install-tools: {exc}", err=True)
        sys.exit(1)

    click.echo("Install paths:")
    created = 0
    for label, target in paths:
        if target.is_dir():
            click.echo(f"  {label:<12} {target}  [ok]")
            continue
        click.echo(f"  {label:<12} {target}  [missing]")
        if not makedirs:
            continue
        if dry_run:
            click.echo(f"    + mkdir -p {target}")
            created += 1
            continue
        try:
            target.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            click.echo(f"    cannot create {target}: {exc}", err=True)
            sys.exit(1)
        click.echo(f"    created {target}")
        created += 1

    if makedirs and created:
        click.echo(
            f"\n{created} directory/ies "
            + ("would be created." if dry_run else "created.")
        )


if __name__ == "__main__":
    main()
