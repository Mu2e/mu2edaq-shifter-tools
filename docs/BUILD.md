# Building and testing

This project ships no compiled code. It is bash and Python, so "build"
means two things: creating the Python virtual environment, and running
the CMake packaging/install targets.

CMake is used anyway so the toolkit presents the same interface as the
rest of the Mu2e software, and so that CTest can drive the test suite.

## Quick reference

```sh
./bootstrap.sh --dev --editable            # venv + deps + pytest + commands on PATH
python -m pytest                           # run the tests
python -m pytest tests/test_config.py      # one file
python -m pytest -k precedence             # one pattern
python -m pytest tests/test_config.py::test_resolve_command_line_beats_everything

cmake -S . -B build                        # configure
cmake --build build --target venv          # bootstrap through CMake
ctest --test-dir build --output-on-failure # tests through CTest
cmake --install build                      # install
```

## The Python environment

`bootstrap.sh` creates `venv/` in the repository root and installs
`requirements.txt` into it. It checks for Python >= 3.9 before creating
anything, and seeds a `.env` from `.env.example` if none exists.

| Flag | Effect |
|---|---|
| `-d`, `--dev` | also install `pytest` |
| `-e`, `--editable` | `pip install -e .`, putting the `daq-*` commands on the venv `PATH` |
| `-G`, `--no-gui` | skip PyQt5, for headless DAQ nodes |
| `-u`, `--upgrade` | pass `--upgrade` to pip |
| `-p`, `--python P` | interpreter to build the venv with |
| `-f`, `--force` | delete and recreate `venv/` |

`start-daq.sh` runs `bootstrap.sh` automatically if it finds the
dependencies missing, so a fresh checkout can be started without any
preparation.

## Dependencies

Runtime, from `requirements.txt`:

- **PyYAML** — the config files
- **click** — the command line interfaces
- **PyQt5** — `daq-open-tunnels --gui` only, and optional

`pyproject.toml` keeps PyQt5 as the `gui` extra rather than a hard
dependency, so the package installs on a node with no Qt. Development
adds only `pytest`, as the `dev` extra.

## The test suite

```
tests/conftest.py         fixtures; neutralises the ambient environment
tests/test_config.py      precedence, search path, Operations accessors
tests/test_read_config.py every daq-read-config verb and its output shape
tests/test_tools.py       cluster_cp, ls2json, install_daq_tools, open_tunnels
tests/test_shell.py       shell syntax, --help, and daq-common.sh behaviour
tests/test_docs.py        man page coverage, rendering, and README/.env drift
```

Every test runs offline. Nothing contacts a DAQ node, a gateway, or
GitHub; the commands that would are exercised through their `--dry-run`
paths. `conftest.py` clears every `MU2EDAQ_*` variable and points
`MU2EDAQ_DOTENV` at a non-existent file for each test, so a developer's
own `.env` cannot change the results.

### What the shell tests check

`tests/test_shell.py` covers the failures that otherwise only appear in
the control room:

- every script survives `bash -n`
- every script is executable
- every command answers `--help` with a usage message and exit 0,
  without a config file, a cluster, or tmux
- every command rejects an unknown option instead of ignoring it
- `daq-common.sh` resolves the root, the config file and the `.env`
  files with the documented precedence
- `--dry-run` really changes nothing, asserted by checking the target
  directory is still empty afterwards

### What the doc tests check

`tests/test_docs.py` is there to stop documentation drift:

- every shell command and every console script has a man page
- there are no orphan man pages for commands that no longer exist
- every page has `NAME`, `SYNOPSIS`, `DESCRIPTION` and `SEE ALSO`,
  a `.TH` header whose section matches its directory, and a `NAME` line
  matching its filename
- every page renders through `man` without error
- the README mentions every command
- every `MU2EDAQ_*` variable the shell code reads is documented in
  `.env.example`

That last one has already caught variables added to a script but not
documented.

## CMake targets

```sh
cmake -S . -B build -DCMAKE_INSTALL_PREFIX=$HOME/daq-tools
```

| Target | Effect |
|---|---|
| `venv` | run `bootstrap.sh --dev` |
| `install` | install commands, man pages, config, data, login files, docs |
| `test` (via `ctest`) | the pytest suite plus a `bash -n` check per script |

CTest registers one `pytest` test plus one `shellsyntax_<name>` test per
script, so a syntax error is reported against the specific file.

Options are listed in [INSTALL.md](INSTALL.md#useful-cmake-options).
The configure step prints a summary of what it will install and warns
if Python >= 3.9 was not found.

## Continuous integration

Two reusable Mu2e workflows run on every push and pull request to
`main`, plus nightly:

- `.github/workflows/git-whitespace.yml` — **trailing whitespace fails
  the build.** Check before pushing with `git diff --check`.
- `.github/workflows/mu2e-format-single-pkg.yml` — formatting check.

Two more add new issues and pull requests to Mu2e project 6.

The Python code is `black`-formatted. Keep new code consistent with it;
no linter is configured, and none should be added without being asked.

## Versioning

The version appears in three places and they must agree:

- `pyproject.toml` — `version = "1.1.0"`
- `src/mu2edaq_shifter_tools/__init__.py` — `__version__`
- `CMakeLists.txt` — the `project(... VERSION ...)` line

Git tags in this repository use a `tNN.NN.NN` form (`t01.00.00`), not a
bare `major.minor.patch`.

## Adding to the toolkit

**A new configuration field.** Add a verb to
`src/mu2edaq_shifter_tools/read_config.py`, in the `VERBS` table and in
the dispatch below it, plus an accessor on `Operations` if it needs
derivation. Do not add a YAML parser to a shell script.

**A new shell command.** Put it in `scripts/` so `install-login.sh`
places it on the `PATH`. Source `daq-common.sh`, set `DAQ_PROG`, call
`daq_load_dotenv`, and follow the option-parsing shape documented in
`daq-common.sh(3)`. Add it to `SHELL_COMMANDS` in `tests/test_docs.py`
and to `MU2EDAQ_SCRIPTS` in `CMakeLists.txt`, and write its man page —
the tests will fail until you do.

**A new Python command.** Add the module under
`src/mu2edaq_shifter_tools/`, an entry in `[project.scripts]`, and a
man page. `tests/test_docs.py` reads the entry points straight out of
`pyproject.toml`, so it will require the page automatically.

**Anything that touches a live host.** Give it `--dry-run`, and if it
can interrupt data taking, `--yes` and a confirmation prompt via
`daq_confirm`.

## See also

- [INSTALL.md](INSTALL.md) — deployment
- [CONFIGURATION.md](CONFIGURATION.md) — settings and precedence
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together
