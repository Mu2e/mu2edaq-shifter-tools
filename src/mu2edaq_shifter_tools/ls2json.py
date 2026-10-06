"""Dump directory listings to JSON.

A diagnostic helper: capture what a set of directories contained (name,
size, mtime) so two machines or two points in time can be compared with
an ordinary diff.

See daq-ls2json(1).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

import click


def describe_entry(path: Path, include_dirs: bool) -> Optional[Dict[str, Any]]:
    """Return the record for one directory entry, or None to skip it."""
    try:
        stat = path.stat()
    except OSError:
        # Broken symlink, or something removed underneath us.
        return None

    if path.is_dir():
        if not include_dirs:
            return None
        kind = "directory"
    elif path.is_file():
        kind = "file"
    else:
        kind = "other"

    return {
        "name": path.name,
        "type": kind,
        "size": stat.st_size,
        "modified_time": stat.st_mtime,
    }


def listing(
    directories: Sequence[str], include_dirs: bool = False
) -> List[Dict[str, Any]]:
    """Build the listing structure for the given directories.

    Each element is ``{"directory": ..., "files": [...]}``. A directory
    that cannot be read contributes an ``error`` key instead of
    ``files``, so a partial failure is visible in the output rather than
    silently dropped.
    """
    result: List[Dict[str, Any]] = []
    for name in directories:
        directory = Path(name).expanduser()
        item: Dict[str, Any] = {"directory": str(directory)}
        try:
            entries = sorted(directory.iterdir(), key=lambda p: p.name)
        except OSError as exc:
            item["error"] = str(exc)
            item["files"] = []
            result.append(item)
            continue

        files: List[Dict[str, Any]] = []
        for entry in entries:
            # Note the per-entry append: the original version appended
            # outside the isfile() test, which duplicated the previous
            # record for every directory it met.
            record = describe_entry(entry, include_dirs)
            if record is not None:
                files.append(record)
        item["files"] = files
        result.append(item)
    return result


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.option(
    "--output",
    "-o",
    default=None,
    help="Write JSON here (default: stdout).",
)
@click.option(
    "--include-dirs",
    "-D",
    is_flag=True,
    help="Include subdirectories in the listing, not just files.",
)
@click.option(
    "--indent",
    type=int,
    default=4,
    show_default=True,
    help="JSON indentation; 0 for one compact line.",
)
@click.option("--verbose", "-v", is_flag=True, help="Also print a summary to stderr.")
@click.version_option(package_name="mu2edaq-shifter-tools", prog_name="daq-ls2json")
@click.argument("directories", nargs=-1, type=click.Path())
def main(
    output: Optional[str],
    include_dirs: bool,
    indent: int,
    verbose: bool,
    directories: Sequence[str],
) -> None:
    """Dump the contents of DIRECTORIES to JSON.

    With no DIRECTORIES, the current directory is used.
    """
    targets = list(directories) or ["."]
    data = listing(targets, include_dirs)
    text = json.dumps(data, indent=indent or None, sort_keys=False)

    if output:
        path = Path(output).expanduser()
        try:
            path.write_text(text + "\n")
        except OSError as exc:
            click.echo(f"daq-ls2json: cannot write {path}: {exc}", err=True)
            sys.exit(1)
        click.echo(f"Wrote {path}", err=True)
    else:
        click.echo(text)

    if verbose:
        for item in data:
            if item.get("error"):
                click.echo(f"{item['directory']}: {item['error']}", err=True)
            else:
                click.echo(
                    f"{item['directory']}: {len(item['files'])} entries", err=True
                )


if __name__ == "__main__":
    main()
