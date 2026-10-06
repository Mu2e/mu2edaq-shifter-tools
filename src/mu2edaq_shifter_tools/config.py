"""Configuration handling for the Mu2e DAQ shifter tools.

Every setting in this toolkit is resolved with the same precedence:

    command line  >  environment  >  .env file  >  config file  >  default

:func:`resolve` implements exactly that, and the command line tools feed
their parsed options into it. The YAML side is the DAQ operations file
(``daq-operations.yaml``), which describes partitions, the environments
inside them, and the ports they use.

Config files are looked for on a search path rather than at one fixed
location, so a checkout, a CMake install, and a per-user override can
coexist::

    $MU2EDAQ_CONFIG_DIR      explicit override
    ./config                 the current working directory
    <root>/config            the installation root
    ~/.config/mu2edaq        per-user
    /etc/mu2edaq             site-wide

``<root>`` is ``$MU2EDAQ_ROOT`` if set, otherwise the directory found by
walking up from this module looking for ``config/daq-operations.example.yaml``.

See mu2edaq_shifter_tools_config(3).
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence

import yaml

#: Name of the DAQ operations configuration file.
OPERATIONS_CONFIG = "daq-operations.yaml"

#: Name of the SSH tunnel definition file.
TUNNELS_CONFIG = "tunnels.yaml"

#: Marker used to identify the installation root.
ROOT_MARKER = Path("config") / "daq-operations.example.yaml"

#: Prefix for every environment variable this toolkit reads.
ENV_PREFIX = "MU2EDAQ_"


class ConfigError(Exception):
    """Raised when configuration is missing, unreadable, or inconsistent."""


# --------------------------------------------------------------------------
# Locating things
# --------------------------------------------------------------------------


def repo_root() -> Path:
    """Return the root of the shifter-tools installation.

    ``$MU2EDAQ_ROOT`` wins if it is set. Otherwise walk up from this
    module looking for :data:`ROOT_MARKER`, which exists both in a git
    checkout and in a CMake install tree. Falls back to
    ``~/daq-shifter-tools``, the conventional deployment path on the DAQ
    cluster.
    """
    env_root = os.environ.get(ENV_PREFIX + "ROOT")
    if env_root:
        return Path(env_root).expanduser()

    here = Path(__file__).resolve()
    # .../<root>/src/mu2edaq_shifter_tools/config.py -> walk up to <root>
    for candidate in here.parents:
        if (candidate / ROOT_MARKER).exists():
            return candidate

    return Path.home() / "daq-shifter-tools"


def config_search_path() -> List[Path]:
    """Return the directories searched for configuration files, in order."""
    path: List[Path] = []
    explicit = os.environ.get(ENV_PREFIX + "CONFIG_DIR")
    if explicit:
        path.append(Path(explicit).expanduser())
    path.append(Path.cwd() / "config")
    path.append(repo_root() / "config")
    path.append(Path.home() / ".config" / "mu2edaq")
    path.append(Path("/etc/mu2edaq"))

    # Preserve order while dropping duplicates, which are common when the
    # cwd happens to be the installation root.
    seen = set()
    unique: List[Path] = []
    for entry in path:
        key = str(entry)
        if key not in seen:
            seen.add(key)
            unique.append(entry)
    return unique


def data_dir() -> Path:
    """Return the directory holding the static data files."""
    explicit = os.environ.get(ENV_PREFIX + "DATA_DIR")
    if explicit:
        return Path(explicit).expanduser()
    return repo_root() / "data"


def data_file(name: str) -> Path:
    """Return the path to a static data file, e.g. ``daq_nodes.json``.

    :raises ConfigError: if the file does not exist.
    """
    candidate = data_dir() / name
    if not candidate.is_file():
        raise ConfigError(f"data file not found: {candidate}")
    return candidate


def find_config_file(name: str, explicit: Optional[str] = None) -> Path:
    """Locate a configuration file by name.

    :param name: file name to look for, e.g. ``daq-operations.yaml``.
    :param explicit: a path given on the command line or in the
        environment. Used as-is (with ``~`` expanded) and required to
        exist.
    :raises ConfigError: if nothing was found.
    """
    if explicit:
        candidate = Path(explicit).expanduser()
        if candidate.is_file():
            return candidate
        raise ConfigError(f"config file not found: {candidate}")

    for directory in config_search_path():
        candidate = directory / name
        if candidate.is_file():
            return candidate

    searched = "\n  ".join(str(p) for p in config_search_path())
    raise ConfigError(f"no {name} found on the config search path:\n  {searched}")


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------


def load_config(path: os.PathLike) -> Dict[str, Any]:
    """Load a YAML (or JSON, which is a subset of YAML) config file."""
    try:
        with open(path, "r") as stream:
            loaded = yaml.safe_load(stream)
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"cannot parse {path}: {exc}") from exc

    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise ConfigError(f"{path}: expected a mapping at the top level")
    return loaded


def dotenv_files(explicit: Optional[str] = None) -> List[Path]:
    """Return the ``.env`` files to read, highest precedence first.

    With no explicit path the order is ``$MU2EDAQ_DOTENV``,
    ``~/.mu2edaq/env`` (written by ``install-login.sh``), ``<root>/.env``,
    then ``./.env``. Only files that exist are returned.
    """
    if explicit:
        candidate = Path(explicit).expanduser()
        return [candidate] if candidate.is_file() else []

    candidates: List[Path] = []
    env_value = os.environ.get(ENV_PREFIX + "DOTENV")
    if env_value:
        candidates.append(Path(env_value).expanduser())
    candidates.append(Path.home() / ".mu2edaq" / "env")
    candidates.append(repo_root() / ".env")
    candidates.append(Path.cwd() / ".env")

    found: List[Path] = []
    seen = set()
    for candidate in candidates:
        key = str(candidate)
        if key not in seen and candidate.is_file():
            seen.add(key)
            found.append(candidate)
    return found


def find_dotenv(explicit: Optional[str] = None) -> Optional[Path]:
    """Return the highest-precedence ``.env`` file, or ``None``."""
    files = dotenv_files(explicit)
    return files[0] if files else None


def load_dotenv(explicit: Optional[str] = None) -> Dict[str, str]:
    """Parse the ``.env`` files into one dict.

    Every file from :func:`dotenv_files` is read, and an earlier file's
    value wins over a later one's.

    This deliberately does *not* touch :data:`os.environ`: the caller
    passes the result to :func:`resolve`, which ranks it below the real
    environment. Lines may use an optional ``export`` prefix and one
    layer of matching quotes; blanks and ``#`` comments are ignored.
    """
    values: Dict[str, str] = {}
    for path in dotenv_files(explicit):
        for key, value in _parse_dotenv(path).items():
            values.setdefault(key, value)
    return values


def _parse_dotenv(path: Path) -> Dict[str, str]:
    """Parse a single ``.env`` file."""
    values: Dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key.replace("_", "").isalnum() or key[0].isdigit():
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    return values


# --------------------------------------------------------------------------
# Precedence
# --------------------------------------------------------------------------


def resolve(
    cli: Any = None,
    env_var: Optional[str] = None,
    dotenv: Optional[Mapping[str, str]] = None,
    config: Optional[Mapping[str, Any]] = None,
    config_key: Optional[str] = None,
    default: Any = None,
    environ: Optional[Mapping[str, str]] = None,
) -> Any:
    """Resolve one setting using the project-wide precedence.

    ``command line > environment > .env > config file > default``

    :param cli: the value parsed from the command line, or ``None`` if
        the option was not given.
    :param env_var: environment variable to consult, e.g.
        ``MU2EDAQ_PARTITION``.
    :param dotenv: mapping from :func:`load_dotenv`.
    :param config: mapping from :func:`load_config`.
    :param config_key: dotted key to look up in ``config``, e.g.
        ``defaults.partition``.
    :param default: value used when nothing else supplied one.
    :param environ: environment to read; defaults to :data:`os.environ`
        (injectable for tests).
    """
    if cli is not None:
        return cli

    env = os.environ if environ is None else environ
    if env_var and env.get(env_var):
        return env[env_var]

    if env_var and dotenv and dotenv.get(env_var):
        return dotenv[env_var]

    if config is not None and config_key:
        found = _dig(config, config_key)
        if found is not None:
            return found

    return default


def _dig(mapping: Mapping[str, Any], dotted: str) -> Any:
    """Look up a dotted key in a nested mapping, or return ``None``."""
    node: Any = mapping
    for part in dotted.split("."):
        if not isinstance(node, Mapping) or part not in node:
            return None
        node = node[part]
    return node


# --------------------------------------------------------------------------
# The DAQ operations configuration
# --------------------------------------------------------------------------


class Operations:
    """Typed accessors over the DAQ operations configuration.

    ::

        ops = Operations.load()
        for env in ops.active_environments("partition_0"):
            print(env, ops.gateway_port("partition_0", env))
    """

    def __init__(self, data: Mapping[str, Any], path: Optional[Path] = None) -> None:
        self._data = dict(data)
        self.path = path

    @classmethod
    def load(cls, explicit: Optional[str] = None) -> "Operations":
        """Load the operations config, honouring ``$MU2EDAQ_CONFIG``."""
        if explicit is None:
            explicit = os.environ.get(ENV_PREFIX + "CONFIG") or None
        if explicit is None:
            dotenv = load_dotenv()
            explicit = dotenv.get(ENV_PREFIX + "CONFIG") or None
        path = find_config_file(OPERATIONS_CONFIG, explicit)
        return cls(load_config(path), path)

    # -- raw access --------------------------------------------------------

    @property
    def data(self) -> Dict[str, Any]:
        """The parsed configuration as a plain dict."""
        return self._data

    def partitions(self) -> List[str]:
        """Return the configured partition names."""
        partitions = self._data.get("partitions") or {}
        if not isinstance(partitions, Mapping):
            raise ConfigError("'partitions' must be a mapping")
        return list(partitions.keys())

    def partition(self, name: str) -> Dict[str, Any]:
        """Return one partition's configuration."""
        partitions = self._data.get("partitions") or {}
        if name not in partitions:
            known = ", ".join(self.partitions()) or "(none)"
            raise ConfigError(f"partition {name!r} not found; known: {known}")
        return dict(partitions[name])

    def environments(self, partition: str) -> List[str]:
        """Return every environment defined in a partition."""
        envs = self.partition(partition).get("environments") or {}
        return list(envs.keys())

    def environment(self, partition: str, name: str) -> Dict[str, Any]:
        """Return one environment's configuration."""
        envs = self.partition(partition).get("environments") or {}
        if name not in envs:
            known = ", ".join(envs.keys()) or "(none)"
            raise ConfigError(
                f"environment {name!r} not found in partition "
                f"{partition!r}; known: {known}"
            )
        return dict(envs[name])

    def active_environments(self, partition: str) -> List[str]:
        """Return the partition's active environments.

        Defaults to every defined environment when the partition does not
        list ``active_environments`` explicitly.
        """
        config = self.partition(partition)
        active = config.get("active_environments")
        if active is None:
            return self.environments(partition)
        if isinstance(active, str):
            return [active]
        return list(active)

    # -- derived values ----------------------------------------------------

    def base_release(self, partition: str) -> str:
        """Return the partition's base release path."""
        value = self.partition(partition).get("base_release")
        if not value:
            raise ConfigError(f"no base_release configured for {partition!r}")
        return str(value)

    def test_rel_path(self, partition: str, environment: str) -> str:
        """Return an environment's test release directory."""
        value = self.environment(partition, environment).get("test_rel_path")
        if not value:
            raise ConfigError(
                f"no test_rel_path configured for {partition}/{environment}"
            )
        return str(value)

    def setup_cmd(self, partition: str, environment: str) -> str:
        """Return an environment's setup command."""
        value = self.environment(partition, environment).get("setup_cmd")
        if not value:
            raise ConfigError(f"no setup_cmd configured for {partition}/{environment}")
        return str(value)

    def ots_port_offset(self, partition: str) -> int:
        """Return the partition-wide ots port offset (default 0)."""
        return int(self.partition(partition).get("ots_port_offset", 0) or 0)

    def port_offset(self, partition: str, environment: str) -> int:
        """Return an environment's port offset within its partition."""
        return int(self.environment(partition, environment).get("port_offset", 0) or 0)

    def gateway_port(self, partition: str, environment: str) -> int:
        """Return an environment's gateway port.

        This is the partition's ``ots_port_offset`` plus the
        environment's ``port_offset``, which is how ots itself derives
        the port.
        """
        return self.ots_port_offset(partition) + self.port_offset(
            partition, environment
        )

    def resource_manager_port(self) -> int:
        """Return the ResourceManager port (default 1973, Mu2e is E-973)."""
        return int(self._data.get("resource_manager_port", 1973) or 1973)


# --------------------------------------------------------------------------
# Tunnels
# --------------------------------------------------------------------------


def load_tunnels(explicit: Optional[str] = None) -> List[Dict[str, Any]]:
    """Load the SSH tunnel definitions.

    Accepts either a bare list of tunnels or a mapping with a
    ``tunnels:`` key, and tolerates the historical JSON file since JSON
    is valid YAML.
    """
    path = find_config_file(TUNNELS_CONFIG, explicit)
    try:
        with open(path, "r") as stream:
            loaded = yaml.safe_load(stream)
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"cannot parse {path}: {exc}") from exc

    if isinstance(loaded, Mapping):
        loaded = loaded.get("tunnels")
    if not isinstance(loaded, Sequence) or isinstance(loaded, (str, bytes)):
        raise ConfigError(f"{path}: expected a list of tunnel definitions")

    tunnels: List[Dict[str, Any]] = []
    for index, entry in enumerate(loaded):
        if not isinstance(entry, Mapping):
            raise ConfigError(f"{path}: tunnel {index} is not a mapping")
        missing = [k for k in ("hostname", "port") if k not in entry]
        if missing:
            raise ConfigError(f"{path}: tunnel {index} is missing {', '.join(missing)}")
        tunnels.append(dict(entry))
    return tunnels
