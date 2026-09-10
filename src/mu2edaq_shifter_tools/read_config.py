"""Query the DAQ operations configuration from the shell.

The shell scripts in this toolkit do not parse YAML themselves; they
call this tool once per value they need, selecting the value with a
*command verb*::

    daq-read-config -z partition_0 active-envs
    daq-read-config -z partition_0 -e tracker directory

Adding a new configuration field therefore means adding a verb here,
not adding a parser to the calling script.

See daq-read-config(1).
"""

from __future__ import annotations

import json
import sys
from typing import Any, Dict, List, Optional

import click

from . import config as cfg

#: Every supported command verb, with a one-line description. Keep this
#: table and the click help text in sync; daq-read-config(1) is
#: generated from it.
VERBS: Dict[str, str] = {
    "print": "the whole configuration, as YAML-ish text or JSON",
    "config-file": "path of the configuration file actually used",
    "config-path": "the configuration search path, one entry per line",
    "partitions": "names of every configured partition",
    "environments": "every environment defined in the partition",
    "active-envs": "the partition's active environments",
    "base-release": "the partition's base release path",
    "directory": "the environment's test release directory",
    "setup": "the environment's setup command",
    "port-offset": "the environment's port offset",
    "ots-port-offset": "the partition's ots port offset",
    "gateway-port": "ots_port_offset + port_offset for the environment",
    "resource-manager-port": "the ResourceManager port",
}

#: Verbs that need --environment.
ENV_VERBS = frozenset(
    {"directory", "setup", "port-offset", "gateway-port"}
)


def _verb_help() -> str:
    width = max(len(v) for v in VERBS)
    lines = ["Command verbs:"]
    lines += [f"  {verb:<{width}}  {text}" for verb, text in VERBS.items()]
    return "\n".join(lines)


def _emit(value: Any, as_json: bool) -> None:
    """Print one resolved value.

    Text output is deliberately bare -- no labels, no quoting -- because
    the shell scripts capture it with command substitution. Lists are
    printed space-separated on a single line, which is what the callers'
    ``for`` loops expect.
    """
    if as_json:
        click.echo(json.dumps(value, indent=2, sort_keys=True, default=str))
        return

    if isinstance(value, (list, tuple)):
        click.echo(" ".join(str(item) for item in value))
    elif isinstance(value, dict):
        click.echo(json.dumps(value, indent=2, sort_keys=True, default=str))
    else:
        click.echo(str(value))


@click.command(
    context_settings={"help_option_names": ["-h", "--help"]},
    epilog=_verb_help(),
)
@click.option(
    "--config",
    "-c",
    "config_file",
    default=None,
    help=(
        "Operations YAML to read. Defaults to $MU2EDAQ_CONFIG, then "
        "daq-operations.yaml from the config search path."
    ),
)
@click.option(
    "--partition",
    "-z",
    default=None,
    help="Partition to query (default $MU2EDAQ_PARTITION, else partition_0).",
)
@click.option(
    "--environment",
    "-e",
    default=None,
    help="Environment to query (default $MU2EDAQ_ENVIRONMENT).",
)
@click.option(
    "--json",
    "as_json",
    is_flag=True,
    default=False,
    help="Emit JSON instead of bare text.",
)
@click.option(
    "--list-verbs",
    is_flag=True,
    default=False,
    help="List the supported command verbs and exit.",
)
@click.version_option(package_name="mu2edaq-shifter-tools", prog_name="daq-read-config")
@click.argument("verb", type=str, default="print", required=False)
def main(
    config_file: Optional[str],
    partition: Optional[str],
    environment: Optional[str],
    as_json: bool,
    list_verbs: bool,
    verb: str,
) -> None:
    """Read one value out of the DAQ operations configuration.

    VERB selects which value to print; see the list below.
    """
    if list_verbs:
        for name, text in VERBS.items():
            click.echo(f"{name}\t{text}")
        return

    verb = verb.lower()
    if verb not in VERBS:
        known = ", ".join(sorted(VERBS))
        raise click.UsageError(f"unrecognized verb {verb!r}; expected one of: {known}")

    dotenv = cfg.load_dotenv()

    # command line > environment > .env > default
    partition = cfg.resolve(
        cli=partition,
        env_var=cfg.ENV_PREFIX + "PARTITION",
        dotenv=dotenv,
        default="partition_0",
    )
    environment = cfg.resolve(
        cli=environment,
        env_var=cfg.ENV_PREFIX + "ENVIRONMENT",
        dotenv=dotenv,
        default=None,
    )
    config_file = cfg.resolve(
        cli=config_file,
        env_var=cfg.ENV_PREFIX + "CONFIG",
        dotenv=dotenv,
        default=None,
    )

    try:
        # These two verbs answer questions about the search itself and so
        # must work even when no config file exists yet.
        if verb == "config-path":
            _emit([str(p) for p in cfg.config_search_path()] if as_json
                  else "\n".join(str(p) for p in cfg.config_search_path()),
                  as_json)
            return

        ops = cfg.Operations.load(config_file)

        if verb == "config-file":
            _emit(str(ops.path), as_json)
            return
        if verb == "print":
            _emit(ops.data, as_json)
            return
        if verb == "partitions":
            _emit(ops.partitions(), as_json)
            return
        if verb == "resource-manager-port":
            _emit(ops.resource_manager_port(), as_json)
            return
        if verb == "environments":
            _emit(ops.environments(partition), as_json)
            return
        if verb == "active-envs":
            _emit(ops.active_environments(partition), as_json)
            return
        if verb == "base-release":
            _emit(ops.base_release(partition), as_json)
            return
        if verb == "ots-port-offset":
            _emit(ops.ots_port_offset(partition), as_json)
            return

        # Everything below needs an environment. Fall back to the
        # partition's first active environment so the common case of a
        # single-environment partition needs no -e.
        if verb in ENV_VERBS and not environment:
            active = ops.active_environments(partition)
            if not active:
                raise cfg.ConfigError(
                    f"verb {verb!r} needs --environment and partition "
                    f"{partition!r} has no active environments"
                )
            environment = active[0]

        if verb == "directory":
            _emit(ops.test_rel_path(partition, environment), as_json)
        elif verb == "setup":
            _emit(ops.setup_cmd(partition, environment), as_json)
        elif verb == "port-offset":
            _emit(ops.port_offset(partition, environment), as_json)
        elif verb == "gateway-port":
            _emit(ops.gateway_port(partition, environment), as_json)

    except cfg.ConfigError as exc:
        click.echo(f"daq-read-config: {exc}", err=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
