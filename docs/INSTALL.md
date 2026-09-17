# Installing the Mu2e DAQ shifter tools

There are three ways to install this toolkit, for three different
situations:

| Situation | Method |
|---|---|
| A shifter account on the DAQ cluster | [Account install](#1-account-install) with `install-login.sh` |
| A packaged deployment under a prefix | [CMake install](#2-cmake-install) |
| Development on a laptop | [Checkout only](#3-checkout-only) with `bootstrap.sh` |

All three need Python 3.9 or newer. The shell commands additionally
need `bash`, `ssh`, and — for the partition lifecycle — `tmux`.

## Prerequisites

| Requirement | Needed by | Notes |
|---|---|---|
| Python >= 3.9 | the `daq-*` commands, and every shell command that reads the operations YAML | AL9 ships 3.9; `bootstrap.sh` checks the version |
| bash | every shell command | bash 3.2 is enough, so the macOS system shell works |
| tmux | `start-daq.sh`, `stop-daq.sh`, `daq-status.sh`, `start-tmux.sh` | not needed for the tunnel or VNC commands |
| ssh, scp | the tunnel, VNC and cluster-copy commands | |
| Kerberos (`kinit`, `klist`) | the login environment and `daq-tunnels.sh` | |
| nmap | `daq-network-verify.sh` | optional; `--skip-scan` avoids it |
| PyQt5 | `daq-open-tunnels --gui` only | optional; skip with `bootstrap.sh --no-gui` |
| CMake >= 3.16 | the packaged install only | |

## 1. Account install

This is how a shifter account on the DAQ cluster is set up. It deploys
the login dotfiles and puts every command on the `PATH`.

```sh
git clone git@github.com:Mu2e/mu2edaq-shifter-tools.git ~/daq-shifter-tools
cd ~/daq-shifter-tools
./bootstrap.sh                 # create venv/ and install dependencies
./install-login.sh --dry-run   # inspect what would change
./install-login.sh             # do it
```

`install-login.sh` installs:

- `login/*` into `$HOME` with a leading dot, so `login/bashrc` becomes
  `~/.bashrc` — mode 644
- `scripts/*` into `~/bin` — mode 755
- `start-daq.sh` and `stop-daq.sh` into `~/bin`
- `MU2EDAQ_ROOT=<checkout>` into `~/.mu2edaq/env`

That last file is what lets a command in `~/bin` find `config/` and
`data/`: it cannot locate them by walking up from itself. Values in it
rank below the real environment, so exporting `MU2EDAQ_ROOT` still
wins.

Every file that would be overwritten is first copied to
`<file>.bak.<timestamp>`, so an existing `~/.bashrc` is never lost.

`~/bin` is added to `PATH` by the installed `~/.bash_profile`, so log
out and back in, then check:

```sh
which start-daq.sh
daq-status.sh
```

### What the installed login does

The installed `~/.bash_profile` runs the Kerberos and git bootstrap in
a fixed order. See [ARCHITECTURE.md](ARCHITECTURE.md#kerberos-and-git-bootstrap)
before changing it — the ordering is what attributes commits to the
individual shifter rather than to the group account.

### Upgrading an existing account

Pull and re-run the installer; it is idempotent apart from the backups:

```sh
cd ~/daq-shifter-tools && git pull
./bootstrap.sh --upgrade
./install-login.sh
```

One stale file may be left behind from a checkout older than v1.1.0:
`~/bin/get_krb_daq_principle.sh`, whose name was a misspelling of
*principal*. It is inert and can be deleted.

## 2. CMake install

Use this to deploy a versioned copy under a prefix, for example into a
release area shared by several accounts.

```sh
cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/mu2e/daq-tools/v1.1.0
cmake --build build --target venv
ctest --test-dir build --output-on-failure
cmake --install build
```

The resulting tree:

```
<prefix>/bin                              shell commands and Python entry points
<prefix>/lib/pythonX.Y/site-packages      the Python package (see PYTHONPATH below)
<prefix>/share/man/man1                   command man pages
<prefix>/share/man/man3                   API man pages
<prefix>/share/mu2edaq/mu2edaq-env.sh     generated environment script
<prefix>/share/mu2edaq/config             config examples
<prefix>/share/mu2edaq/data               static data
<prefix>/share/mu2edaq/login              login dotfiles
<prefix>/share/doc/mu2edaq-shifter-tools  this documentation
```

### Setting up the environment

The install generates an environment script. Source it rather than
setting the variables by hand:

```sh
source /mu2e/daq-tools/v1.1.0/share/mu2edaq/mu2edaq-env.sh
```

It exports `MU2EDAQ_ROOT` and prepends to `PATH`, `MANPATH` and
`PYTHONPATH`, and is idempotent so sourcing it twice is harmless.

`PYTHONPATH` is the part that is easy to miss. The Python package is
installed with `pip install --prefix`, which places it in
`<prefix>/lib/pythonX.Y/site-packages` — a directory that is **not** on
a system interpreter's default `sys.path`. Without that entry the
`daq-*` console scripts fail with `ModuleNotFoundError`, and the shell
commands that call `daq-read-config` fail with them. The generated
script hardcodes the correct interpreter version, so it stays right.

The equivalent by hand, if you must:

```sh
export MU2EDAQ_ROOT=/mu2e/daq-tools/v1.1.0/share/mu2edaq
export PATH=/mu2e/daq-tools/v1.1.0/bin:$PATH
export MANPATH=/mu2e/daq-tools/v1.1.0/share/man:$MANPATH
export PYTHONPATH=/mu2e/daq-tools/v1.1.0/lib/python3.9/site-packages:$PYTHONPATH
```

Only the `*.example*` config files are installed, so an upgrade never
overwrites a live `daq-operations.yaml`. Copy the example into place on
first install:

```sh
cp $MU2EDAQ_ROOT/config/daq-operations.example.yaml \
   $MU2EDAQ_ROOT/config/daq-operations.yaml
```

### Useful CMake options

| Option | Default | Effect |
|---|---|---|
| `MU2EDAQ_INSTALL_SHELL_TOOLS` | `ON` | install the bash commands |
| `MU2EDAQ_INSTALL_PYTHON` | `ON` | `pip install` the package into the prefix |
| `MU2EDAQ_WITH_GUI` | `ON` | include the PyQt5 extra |
| `MU2EDAQ_SHAREDIR` | `share/mu2edaq` | where config, data and login files go |

## 3. Checkout only

For development, or to use the tools from a laptop without installing
anything:

```sh
git clone git@github.com:Mu2e/mu2edaq-shifter-tools.git
cd mu2edaq-shifter-tools
./bootstrap.sh --dev --editable
source venv/bin/activate
```

`--editable` puts the `daq-*` commands on the venv's `PATH`. Without
it they still work, because the shell wrappers fall back to running the
package straight out of `src/`.

Run the commands from the checkout:

```sh
./start-daq.sh --dry-run
scripts/daq-status.sh
daq-read-config partitions
```

Man pages can be read without installing them:

```sh
man -M "$PWD/man" daq-read-config
man ./man/man1/start-daq.sh.1
```

Give `-M` an absolute path: macOS `man` changes directory before
decompressing, so a relative one renders an empty page.

## Platform notes

**Linux** is the deployment target and everything works there.

**macOS** runs the whole toolkit except the parts that need cluster
services. Note that the system `bash` is 3.2, so the scripts avoid
`mapfile` and unguarded empty-array expansion; if you add to them, keep
that constraint. `daq-network-verify.sh` picks `netstat -rn` when `ip`
and `route -n` are unavailable.

**Windows** is supported only for the Python entry points, and only
under a POSIX shell for the rest. Configure with
`-DMU2EDAQ_INSTALL_SHELL_TOOLS=OFF` to install just the `daq-*`
commands; use WSL, Git Bash or MSYS2 for the shell commands. The
partition lifecycle needs `tmux` and is not usable on native Windows.

## Verifying an install

```sh
daq-read-config config-file          # which config is in effect
daq-read-config config-path          # where it looked
daq-read-config partitions           # can it parse the config
daq-status.sh                        # cross-check against tmux
./bootstrap.sh --dev && python -m pytest
```

## Uninstalling

A CMake install can be removed with the manifest it wrote:

```sh
xargs rm -f < build/install_manifest.txt
```

An account install has no uninstaller. Remove `~/bin/*.sh`,
`~/.mu2edaq/`, and restore the `~/.bashrc.bak.*` backups you want back.

## See also

- [BUILD.md](BUILD.md) — build targets, tests, packaging
- [CONFIGURATION.md](CONFIGURATION.md) — every setting and its precedence
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together
