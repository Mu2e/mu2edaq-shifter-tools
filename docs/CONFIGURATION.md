# Configuration

Every setting in this toolkit resolves the same way:

```
command line  >  environment  >  .env  >  config file  >  built-in default
```

Both halves of the toolkit implement it: `daq-common.sh` for the shell
commands and `mu2edaq_shifter_tools.config` for the Python ones, so a
shell command and a Python command resolve a setting identically.
`tests/test_config.py` and `tests/test_shell.py` assert each tier
individually.

Two details worth knowing:

- An exported-but-empty variable counts as **absent**, so it does not
  mask the lower tiers.
- A falsey command line value such as `0` counts as **present**, because
  zero is a legitimate port offset.

## Where configuration lives

### Config file search path

Files are looked up by name on a search path, first match winning, so a
checkout, a packaged install and a per-user override can coexist:

| Order | Directory | Typical use |
|---|---|---|
| 1 | `$MU2EDAQ_CONFIG_DIR` | explicit override |
| 2 | `./config` | running from a checkout |
| 3 | `$MU2EDAQ_ROOT/config` | the installation root |
| 4 | `~/.config/mu2edaq` | per-user |
| 5 | `/etc/mu2edaq` | site-wide |

Ask what is in effect, and where it looked:

```sh
daq-read-config config-file
daq-read-config config-path
```

### The installation root

`MU2EDAQ_ROOT` anchors `config/` and `data/`. It is resolved as:

1. `$MU2EDAQ_ROOT`, if set
2. the first ancestor directory containing
   `config/daq-operations.example.yaml` — true in a checkout and in a
   CMake install
3. `~/daq-shifter-tools`

Step 2 fails for a command installed into `~/bin`, since it cannot walk
up to the checkout. That is why `install-login.sh` records the root in
`~/.mu2edaq/env`.

### `.env` files

Read in this order, an earlier file winning, and all of them ranking
below the real environment:

1. `$MU2EDAQ_DOTENV`
2. `~/.mu2edaq/env` — written by `install-login.sh`
3. `$MU2EDAQ_ROOT/.env`
4. `./.env`

`.env.example` documents every variable, all commented out;
`bootstrap.sh` copies it to `.env` on first run. An `export` prefix and
one layer of matching quotes are tolerated; blanks, `#` comments and
keys that are not shell identifiers are ignored.

The Python loader deliberately does *not* write into `os.environ` — the
values are passed to `resolve()`, which ranks them below the
environment. Mutating the environment would invert that ordering.

## YAML or environment?

Not every command reads YAML, and that is deliberate.

| Command group | Config source |
|---|---|
| Partition lifecycle (`start-daq.sh`, `stop-daq.sh`, `daq-status.sh`, `setup-online.sh`, `create-environment.sh`, `send-run-control-command.sh`) | `daq-operations.yaml`, read through `daq-read-config` |
| `daq-open-tunnels` | `tunnels.yaml` |
| `daq-install-tools` | `current_release.yaml` |
| `daq-cluster-cp` | `data/daq_nodes.json` |
| Tunnels and VNC (`daq-tunnels.sh`, `manage-vnc-servers.sh`, `start-novnc-connection.sh`, `daq-network-verify.sh`) | command line, environment, `.env` — **no YAML** |

The last row is the deliberate exception. Those commands run on a
shifter's laptop, where the point is to reach the control room from
outside it. Giving them YAML config would mean giving them a Python
dependency to parse it, and they currently need nothing but `bash` and
`ssh`. They stay config-driven through environment variables and `.env`,
which is pure shell.

## `daq-operations.yaml`

Partitions, the environments inside them, and their ports. Ships as
`config/daq-operations.example.yaml`, with
`config/daq-operations.yaml` a symlink to it so a fresh checkout runs.
Replace the symlink with a real file for a deployment.

```yaml
partitions:
  partition_0:                 # any name; make it memorable
    environments:
      tracker:
        test_rel_path: "/home/mu2edaq/tracker/test_rel_v9_00_00"
        setup_cmd: "/home/mu2edaq/tracker/test_rel_v9_00_00/setup_ots.sh tracker"
        port_offset: 10
      trigger:
        test_rel_path: "/home/mu2edaq/test_rel_v9_00_00"
        setup_cmd: "/home/mu2edaq/test_rel_v9_00_00/setup_ots.sh trigger"
        port_offset: 20
    base_release: "/mu2e/releases/v9_00_00"
    active_environments:       # which ones start-daq.sh brings up
      - "tracker"
      - "trigger"
    ots_port_offset: 10000

resource_manager_port: 1973    # Mu2e is E-973
```

| Key | Meaning |
|---|---|
| `environments.<name>.test_rel_path` | the environment's test release directory; `create-environment.sh` builds it, `setup-online.sh` cds into it |
| `environments.<name>.setup_cmd` | sourced by `setup-online.sh`; may carry arguments |
| `environments.<name>.port_offset` | the environment's offset within the partition |
| `base_release` | spack upstream that `create-environment.sh` builds against |
| `active_environments` | the environments `start-daq.sh` starts and `stop-daq.sh` stops; defaults to all of them if absent |
| `ots_port_offset` | partition-wide port base |
| `resource_manager_port` | ResourceManager port, if one is ever run |

An environment's gateway port is `ots_port_offset + port_offset`, which
is how ots derives it:

```sh
daq-read-config -z partition_0 -e trigger gateway-port    # 10020
```

## `tunnels.yaml`

Read by `daq-open-tunnels`. Ships as `config/tunnels.example.yaml`.
The local port of each entry is `base_port + port`, where `base_port`
defaults to **uid + 973** so concurrent users on a shared machine do
not collide without having to coordinate.

```yaml
tunnels:
  - label: gateway01           # shown by "daq-open-tunnels list"
    hostname: mu2egateway01.fnal.gov
    username: mu2edaq          # default: $USER
    port: 3203                 # offset, added to base_port
    remote: localhost          # what the far end connects to
    jump: mu2egateway02.fnal.gov   # optional ProxyJump
```

A bare list is accepted as well as a `tunnels:` mapping, and because
JSON is valid YAML the historical `tunnels.json` still loads.

`daq-open-tunnels` warns when two entries resolve to the same local
port. The shipped example has this problem — `gateway01` and
`gateway02` both use offset 3203 — because it reproduces the original
`tunnels.json`. Only the first will bind. Change one of the offsets for
a real deployment.

## `current_release.yaml`

Read by `daq-install-tools`. Ships only as
`config/current_release.example.yaml` and is **not** symlinked into
place, because install paths are site-specific and creating directories
from an example would be wrong. Copy and edit it.

Versions are structured rather than free text so they can be compared
and re-rendered; the example produces `d09_00_00`.

## `data/daq_nodes.json`

The cluster host inventory, grouped by subsystem (`daq`, `trk`, `crv`,
`calo`), read by `daq-cluster-cp`. It is static data rather than
configuration, which is why it is JSON under `data/` rather than YAML
under `config/`. Override the directory with `MU2EDAQ_DATA_DIR`.

## Environment variables

`.env.example` is the authoritative list; `tests/test_docs.py` fails if
a variable the shell code reads is missing from it. Summary:

### Locations

| Variable | Effect |
|---|---|
| `MU2EDAQ_ROOT` | installation root |
| `MU2EDAQ_CONFIG_DIR` | extra directory searched first for config files |
| `MU2EDAQ_DATA_DIR` | directory holding the static data |
| `MU2EDAQ_DOTENV` | highest-precedence `.env` file |

### Partition lifecycle

| Variable | Effect |
|---|---|
| `MU2EDAQ_CONFIG` | operations YAML |
| `MU2EDAQ_PARTITION` | default partition, so `-z` can be omitted |
| `MU2EDAQ_ENVIRONMENT` | default environment, so `-e` can be omitted |
| `MU2EDAQ_STOP_TIMEOUT` | seconds `stop-daq.sh` waits for a clean shutdown |
| `MU2EDAQ_OTSDAQ_REF` | otsdaq-mu2e ref `create-environment.sh` fetches from |
| `MU2EDAQ_RC_HOST` | gateway host for `send-run-control-command.sh` |

### Tunnels

| Variable | Effect |
|---|---|
| `MU2EDAQ_TUNNELS` | tunnel definition file |
| `MU2EDAQ_TUNNEL_BASE_PORT` | local port base for `daq-open-tunnels` |
| `MU2EDAQ_TUNNEL_STATE` | where `daq-open-tunnels` records pids |
| `MU2EDAQ_TUNNEL_OFFSET` | port offset for `daq-tunnels.sh` |
| `MU2EDAQ_TUNNEL_USER`, `MU2EDAQ_TUNNEL_HOST`, `MU2EDAQ_TUNNEL_JUMP` | who and where `daq-tunnels.sh` connects |
| `MU2EDAQ_TUNNEL_STATE_SH` | where `daq-tunnels.sh` records pids |
| `MU2EDAQ_TUNNEL_SERVICES`, `MU2EDAQ_TUNNEL_EXTRA_SERVICES` | the service port tables |

### Other

| Variable | Effect |
|---|---|
| `MU2EDAQ_CLUSTER_USER`, `MU2EDAQ_CLUSTER_JOBS` | `daq-cluster-cp` |
| `MU2EDAQ_TMUX_SESSION`, `MU2EDAQ_TMUX_CWD` | `start-tmux.sh` |
| `MU2EDAQ_NETWORKS`, `MU2EDAQ_NETVERIFY_DIR` | `daq-network-verify.sh` |
| `VNC_HOST`, `VNC_USER`, `VNC_PORTS` | `manage-vnc-servers.sh` |
| `NOVNC_HOST`, `NOVNC_USER`, `NOVNC_PROXY_JUMP`, `NOVNC_LOCAL_PORT`, `NOVNC_REMOTE_PORT`, `NOVNC_PASSWORD_FILE` | `start-novnc-connection.sh` |
| `KRB5_KEYTAB_DIR` | `get_krb_daq_principal.sh` |
| `GIT_SSH_KEY` | `set_git_env.sh` |

## Options from the environment

Every shell command also accepts its whole option string from
`$<COMMAND>_OPTS`, with `.` and `-` mapped to `_` and upper-cased:

```sh
export START_DAQ_SH_OPTS="-z partition_1 -c /etc/mu2edaq/ops.yaml"
start-daq.sh                      # uses those options
start-daq.sh -z partition_0       # command line still wins
```

The pre-rename names (`START_DAQ_OPTS`, `KILL_DAQ_OPTS`) are still
honoured, but only when the modern name is unset.

## Worked example

A shifter who always works on `partition_1` and forwards ports 100
higher than the default:

```sh
# ~/.mu2edaq/env, or the repository .env
MU2EDAQ_PARTITION=partition_1
MU2EDAQ_TUNNEL_OFFSET=100
MU2EDAQ_CLUSTER_USER=mu2edaq
```

```sh
start-daq.sh                  # starts partition_1
daq-tunnels.sh start          # forwards at +100
start-daq.sh -z partition_0   # one-off override
```

## See also

- [INSTALL.md](INSTALL.md) — deployment
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together
- `daq-read-config(1)`, `daq-common.sh(3)`,
  `mu2edaq_shifter_tools_config(3)`
