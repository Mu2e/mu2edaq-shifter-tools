# mu2edaq-shifter-tools

Operator utilities for running the Mu2e DAQ: partition and environment
lifecycle management, SSH tunnel and VNC access to the control room,
cluster file distribution, and the Kerberos/git login environment for
the shifter accounts.

This is production infrastructure for a particle physics experiment.
Correctness and reliability matter more than convenience: anything that
touches a live host has a `--dry-run`, and anything that can interrupt
data taking asks before it does.

## Quick start

```sh
git clone git@github.com:Mu2e/mu2edaq-shifter-tools.git ~/daq-shifter-tools
cd ~/daq-shifter-tools
./bootstrap.sh                 # create venv/ and install dependencies
./install-login.sh --dry-run   # see what an account install would change
./install-login.sh             # install dotfiles and commands into ~/bin
```

Then, after a new login:

```sh
daq-status.sh                  # what is running
./start-daq.sh -z partition_0  # bring a partition up
./stop-daq.sh  -z partition_0  # take it down
```

Full instructions, including the CMake install and the platform notes,
are in [docs/INSTALL.md](docs/INSTALL.md).

## Commands

Every command supports `--help`, takes its settings as
`command line > environment > .env > config file > default`, and has a
man page.

### Partition lifecycle

Run on the DAQ cluster. These manage `otsdaq` (`ots`) instances inside
tmux and read `config/daq-operations.yaml`.

| Command | What it does |
|---|---|
| `start-daq.sh` | create a `daq-<partition>` tmux session with one window per active environment, each running `ots` |
| `stop-daq.sh` | send `ots -k` to those windows, wait for a clean exit, kill the session |
| `scripts/daq-status.sh` | report which partitions and environments are running; `--json`, and `--quiet` as a health check |
| `scripts/setup-online.sh` | **source this** to set up one environment in the current shell |
| `scripts/create-environment.sh` | create or update an environment's spack test release |
| `scripts/send-run-control-command.sh` | send a run-control state transition — **not implemented**, see below |
| `scripts/start-tmux.sh` | build the four-quadrant shifter tmux workspace |

### Workstation access

Run wherever the operator is. These need only `bash` and `ssh` — no
Python, so they work from a bare laptop.

| Command | What it does |
|---|---|
| `scripts/daq-tunnels.sh` | open, close and report the control-room GUI port forwards |
| `scripts/start-novnc-connection.sh` | tunnel to the noVNC manager and open a generated session dashboard |
| `scripts/manage-vnc-servers.sh` | start, stop or restart the `vncserver@` units on the manager host |
| `scripts/daq-network-verify.sh` | sweep the DAQ private networks and report which hosts answered |

### Login environment

Sourced from the installed `~/.bash_profile`, in this order.

| Command | What it does |
|---|---|
| `scripts/get_krb_principal.sh` | export `KRB5_PRINCIPAL` from the login ticket cache |
| `scripts/set_git_env.sh` | set the git identity and `GIT_SSH_COMMAND` from that principal |
| `scripts/get_krb_daq_principal.sh` | `kinit` the DAQ group account from its keytab |

The ordering is load-bearing — it is what attributes commits to the
individual shifter rather than to the shared group account. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#kerberos-and-git-bootstrap)
before changing it.

### Python commands

Installed by `bootstrap.sh --editable`, or by the CMake install.

| Command | What it does |
|---|---|
| `daq-read-config` | query the operations YAML; the only YAML parser in the toolkit |
| `daq-open-tunnels` | open, list and kill the tunnels defined in `config/tunnels.yaml` |
| `daq-cluster-cp` | copy files to the same path on many cluster nodes in parallel |
| `daq-ls2json` | dump directory listings to JSON, for diffing two nodes |
| `daq-install-tools` | validate a release description and prepare its install tree |

### Setup

| Command | What it does |
|---|---|
| `bootstrap.sh` | create `venv/` and install dependencies |
| `install-login.sh` | install the dotfiles and commands into an account |

## How configuration works

One rule, everywhere:

```
command line  >  environment  >  .env  >  config file  >  default
```

No shell script parses YAML. They call `daq-read-config` once per value
they need, selecting it with a *command verb*:

```sh
daq-read-config -z partition_0 active-envs        # tracker trigger
daq-read-config -z partition_0 -e tracker setup   # the setup command
daq-read-config --list-verbs                      # everything available
```

So **adding a configuration field means adding a verb to
`read_config.py`**, not adding a parser to a script. That is the one
thing to know before editing this codebase.

Config files are found on a search path (`$MU2EDAQ_CONFIG_DIR`,
`./config`, `$MU2EDAQ_ROOT/config`, `~/.config/mu2edaq`,
`/etc/mu2edaq`), so a checkout, a packaged install and a per-user
override coexist. Ask what is in effect with:

```sh
daq-read-config config-file
daq-read-config config-path
```

Everything else is in [docs/CONFIGURATION.md](docs/CONFIGURATION.md),
and `.env.example` documents every environment variable.

## Repository layout

```
CMakeLists.txt         packaging and CTest (there is no compiled code)
pyproject.toml         the Python package and its entry points
bootstrap.sh           create venv/
install-login.sh       deploy into a shifter account
start-daq.sh           \  the start/stop pair, kept at the top level
stop-daq.sh            /
config/                operations, tunnel and release YAML
data/                  static inventories (nodes, Kerberos principals)
docs/                  INSTALL, BUILD, CONFIGURATION, ARCHITECTURE
login/                 dotfiles installed as ~/.<name>
man/man1, man/man3     man pages for every command and API
scripts/               the commands installed into ~/bin
src/mu2edaq_shifter_tools/
                       the Python package
tests/                 pytest suite
web/                   web assets
core/                  core dumps
```

`scripts/` is the directory whose contents land on the `PATH`, so a
helper that shifters should invoke by name belongs there.

## Documentation

| Document | Covers |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | the three install methods, prerequisites, platform notes |
| [docs/BUILD.md](docs/BUILD.md) | venv, tests, CMake targets, CI, how to extend the toolkit |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | every setting, every file, every variable |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the pieces fit, and why they fit that way |

Man pages can be read from a checkout without installing them:

```sh
man -M "$PWD/man" start-daq.sh
man -M "$PWD/man" daq-read-config
man -M "$PWD/man" daq-common.sh   # the shared shell library, section 3
man -M "$PWD/man" mu2edaq_shifter_tools_config
```

The `-M` path must be absolute: macOS `man` changes directory before
decompressing, so a relative path silently renders an empty page. A
single page can also be opened directly:

```sh
man ./man/man1/start-daq.sh.1
```

## Testing

```sh
./bootstrap.sh --dev
python -m pytest
```

Every test runs offline; nothing contacts a DAQ node or a gateway. The
suite covers the configuration precedence on both the shell and Python
sides, every `daq-read-config` verb and its exact output shape, the
`--dry-run` paths, and documentation drift — a command without a man
page, or an environment variable missing from `.env.example`, fails the
build.

## Known gaps

- **`send-run-control-command.sh` is not implemented.** Its option
  handling and port resolution are complete and tested, but the otsdaq
  gateway UDP payload format has not been transcribed, so it exits 3.
  Drive state transitions from the otsdaq web GUI instead.
- **ResourceManager does not exist.** Nothing currently prevents two
  partitions from claiming the same DTC. The design sketch is recorded
  in
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#resourcemanager-design-sketch).
- **The shipped `tunnels.example.yaml` has a port collision**
  (`gateway01` and `gateway02` both use offset 3203), reproduced from
  the original `tunnels.json`. `daq-open-tunnels` warns about it; fix
  the offsets for a real deployment.

## Contributing

CI runs the Mu2e reusable `git-whitespace` and
`mu2e-format-single-pkg` workflows on every push and pull request to
`main`. **Trailing whitespace fails the build** — check with
`git diff --check` before pushing.

New commands go in `scripts/`, source `daq-common.sh`, get a man page,
and get an entry in `tests/test_docs.py` and `CMakeLists.txt`. See
[docs/BUILD.md](docs/BUILD.md#adding-to-the-toolkit).

## License

See [LICENSE](LICENSE).
