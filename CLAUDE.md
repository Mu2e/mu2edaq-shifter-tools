# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Operator tooling for the Mu2e DAQ (`Mu2e/mu2edaq-shifter-tools`, public).
There is **no compiled code**: it is bash and Python commands that a shifter or a
script invokes. CMake exists for packaging and CTest only. The Python half is a
real package under `src/`, installed from `pyproject.toml`.

Read `docs/ARCHITECTURE.md` before making structural changes; it records why the
pieces are shaped the way they are.

## Commands

```sh
./bootstrap.sh --dev --editable       # venv/ + deps + pytest + daq-* on PATH
source venv/bin/activate

python -m pytest                      # all tests (offline, no cluster needed)
python -m pytest tests/test_config.py  # one file
python -m pytest -k precedence         # one pattern
python -m pytest tests/test_shell.py::test_dotenv_does_not_override_the_environment

cmake -S . -B build && ctest --test-dir build --output-on-failure
cmake --install build                  # needs -DCMAKE_INSTALL_PREFIX

./install-login.sh --dry-run           # what an account install would change
git diff --check                       # CI fails on trailing whitespace
man -M "$PWD/man" daq-read-config      # -M must be absolute (see below)
```

Every command takes `--help`. Everything that touches a live host takes
`--dry-run`; use it when verifying a change.

## Architecture

### The one rule: no shell script parses YAML

Shell commands call `daq-read-config` once per value, selecting it with a
*command verb* (`active-envs`, `directory`, `setup`, `gateway-port`, ...).
**Adding a configuration field means adding a verb to
`src/mu2edaq_shifter_tools/read_config.py`** — in the `VERBS` table and the
dispatch below it, plus an `Operations` accessor if it needs derivation. Never
add a YAML parser to a script.

`daq-read-config` text output is deliberately bare and lists are space-separated
on one line, because callers capture it with command substitution.
`tests/test_read_config.py` asserts the exact output shape; if you change it,
you will break the shell commands.

### Two mirrored configuration layers

`scripts/daq-common.sh` (shell) and `src/mu2edaq_shifter_tools/config.py`
(Python) implement the same precedence, search path and root discovery, so a
shell command and a Python command resolve a setting identically:

```
command line > environment > .env > config file > default
```

Keep them in step. An empty environment value counts as absent; a falsey CLI
value like `0` counts as present. `load_dotenv()` must not write to
`os.environ` — that would invert the ordering.

`daq-common.sh` replaced four verbatim copies of an artdaq-style `expr` option
parser. Do not reintroduce per-script parsers; follow the shape documented in
`daq-common.sh(3)`.

### Root discovery

`MU2EDAQ_ROOT` → else walk up for `config/daq-operations.example.yaml` → else
`~/daq-shifter-tools`. The walk fails for a command installed in `~/bin`, which
is why `install-login.sh` records the root in `~/.mu2edaq/env` (a `.env` file, so
it still ranks below the real environment).

### tmux windows are addressed by name

`start-daq.sh` creates `daq-<partition>` with windows named
`daq-<partition>-<environment>`. `stop-daq.sh` and `daq-status.sh` look them up
by name. The original scripts used positional indices re-derived from
`active-envs`, and killed the wrong window whenever the orderings disagreed —
do not go back to indices.

`scripts/setup-online.sh` **must be sourced**; it cds and defines the ots
environment in the caller's shell, then unsets all its own variables.

### Kerberos → git ordering is load-bearing

`login/bash_profile` runs: `get_krb_principal.sh` (human's ticket) →
`set_git_env.sh` (git identity from it) → `kdestroy` → `get_krb_daq_principal.sh`
(group keytab). Moving step 4 earlier attributes every commit to the group
account; dropping `kdestroy` leaves the human's ticket exposed to the group
account.

### `scripts/` is what lands on the PATH

`install-login.sh` installs `login/*` → `~/.<name>`, `scripts/*` → `~/bin`, and
the top-level `start-daq.sh`/`stop-daq.sh` → `~/bin`. A helper shifters should
invoke by name belongs in `scripts/`.

### Three unrelated port schemes

- `daq-open-tunnels`: local port = `uid + 973` + per-entry offset.
- `scripts/daq-tunnels.sh`: fixed service table + `--offset`; `!` marks a port
  that takes no offset.
- The DAQ itself: `ots_port_offset + port_offset`, exposed as `gateway-port`.

### Tunnel commands track pids

Both record the ssh pids they start and stop exactly those. `daq-tunnels.sh`
previously used `pkill -f "ssh.*mu2e-"`, which killed the operator's own
interactive sessions to any Mu2e host. `--all-matching` still offers that, but
it is not the default. It also opens two ssh processes so one dead forward
cannot take the other group down.

## Conventions

- Config in `config/` as YAML; static inventories in `data/` as JSON; man pages
  in `man/man1` and `man/man3`; markdown in `docs/`.
- Commands are `<verb>-<noun>.sh`. The start/stop pair lives at the top level.
- The tunnel and VNC commands (`daq-tunnels.sh`, `manage-vnc-servers.sh`,
  `start-novnc-connection.sh`, `daq-network-verify.sh`) have **no Python
  dependency** and are config-driven through env/`.env` only. Preserve that —
  they run from a shifter's laptop.
- Portability: system bash on macOS is 3.2, so no `mapfile`, and expand possibly
  empty arrays as `${a[@]+"${a[@]}"}`. Python targets 3.9.
- Python is `black`-formatted. No linter is configured; do not add one.
- Version appears in `pyproject.toml`, `src/mu2edaq_shifter_tools/__init__.py`
  and `CMakeLists.txt` — keep all three in step. Git tags use `tNN.NN.NN`.
- CI runs the Mu2e reusable `git-whitespace` and `mu2e-format-single-pkg`
  workflows; trailing whitespace fails the build.

## Adding a command

New shell command → `scripts/`, source `daq-common.sh`, set `DAQ_PROG`, call
`daq_load_dotenv`. New Python command → a module plus a `[project.scripts]`
entry. Either way: write the man page, and add it to `SHELL_COMMANDS` in
`tests/test_docs.py` and `MU2EDAQ_SCRIPTS` in `CMakeLists.txt`.
`tests/test_docs.py` fails on a command without a man page, an orphan man page,
a missing man section, a command absent from the README, or a `MU2EDAQ_*`
variable missing from `.env.example`.

## Gotchas

- `man -M man <page>` renders an **empty page** on macOS: man chdirs, then zcat
  cannot resolve the relative path. Always pass an absolute `-M` path.
- `${var#~/}` tilde-expands the *pattern* in bash, so stripping a literal `~/`
  needs `${var#'~/'}`. This was the original config-path bug.
- `config/daq-operations.yaml` and `config/tunnels.yaml` are tracked symlinks to
  their `.example` counterparts so a fresh checkout runs. Do not commit a real
  file over them; `config/current_release.yaml` is gitignored instead.
- `tests/conftest.py` clears every `MU2EDAQ_*` variable per test. If a test
  depends on the ambient environment, it is wrong.

## Not implemented

- `scripts/send-run-control-command.sh` exits 3. Options, config and port
  resolution are complete and tested; the otsdaq gateway UDP payload format is
  not transcribed. Notes are at the bottom of the file.
- ResourceManager does not exist — nothing prevents two partitions claiming the
  same DTC. Design sketch in `docs/ARCHITECTURE.md`.
- `config/tunnels.example.yaml` has a real port collision (`gateway01` and
  `gateway02` both at offset 3203), reproduced from the original
  `tunnels.json`. `daq-open-tunnels` warns; it is not a bug in the code.
