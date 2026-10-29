# Installing the Mu2e DAQ shifter tools

## Two places, two installers

This toolkit is installed in **two different places**, and each place
has its own installer. Do not run one place's installer in the other.

| | **Client side** | **Remote side** |
|---|---|---|
| Where | **your own laptop or workstation** (macOS, Linux, Windows with Git Bash or WSL) | **a shared account on a DAQ host** (`mu2eshift`, `mu2edaq`, ... on `mu2e-mgr-01` and the other cluster nodes) |
| Who runs it | each person, once per computer | an expert, once per account per host |
| Installer | [`install-ssh-config.sh`](#0-client-side-your-computer) | [`install-login.sh`](#1-remote-side-account-install-on-a-daq-host) |
| What it changes | `~/.ssh/config_mu2e`, one `Include` line in `~/.ssh/config`, `~/.mu2edaq/env` (your username) | the account's `~/.bashrc`, `~/.bash_profile`, `~/.aliases`, `~/.bash_logout`, `~/bin/*`, `~/.mu2edaq/env` (`MU2EDAQ_ROOT`) |
| Asks for personal information | yes: your Fermilab username and the shared accounts you use | no |
| Then you run | `scripts/daq-ssh-check.sh`, `scripts/start-novnc-connection.sh`, `scripts/daq-tunnels.sh` | `start-daq.sh`, `stop-daq.sh`, `daq-status.sh`, ... |

`~/.mu2edaq/env` exists on both sides and holds different settings on
each; that is intended, since they are different computers.

`install-login.sh` copies all of `scripts/` into the account's `~/bin`,
so the client-side commands also land on the DAQ hosts. They are meant
to be run from your computer.

### Which command runs where

| Command | Client side (your computer) | Remote side (DAQ host) |
|---|:---:|:---:|
| `install-ssh-config.sh` | **yes** | no |
| `scripts/daq-ssh-check.sh` | **yes** | no |
| `scripts/start-novnc-connection.sh` | **yes** | no |
| `scripts/daq-tunnels.sh`, `daq-open-tunnels` | **yes** | no |
| `scripts/manage-vnc-servers.sh` | **yes** (ssh's to the manager host) | no |
| `install-login.sh` | no | **yes** |
| `start-daq.sh`, `stop-daq.sh`, `scripts/daq-status.sh` | no | **yes** |
| `scripts/setup-online.sh`, `scripts/create-environment.sh`, `scripts/start-tmux.sh` | no | **yes** |
| `scripts/get_krb_principal.sh`, `scripts/set_git_env.sh`, `scripts/get_krb_daq_principal.sh` | no | **yes** (sourced by the login) |
| `scripts/daq-network-verify.sh`, `daq-cluster-cp`, `daq-ls2json` | no | **yes** (cluster network) |

Besides those two installers there are two other ways to install, used
less often:

| Situation | Method |
|---|---|
| A packaged deployment under a prefix | [CMake install](#2-cmake-install) |
| Development | [Checkout only](#3-checkout-only) with `bootstrap.sh` |

The Python commands need Python 3.9 or newer. The shell commands need
`bash` and `ssh`; the partition lifecycle on the remote side also
needs `tmux`. The client side needs no Python except for the noVNC
dashboard, which uses `python3` and, for session descriptions, PyYAML;
both are optional.

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

## 0. Client side: your computer

> **Run on: your own laptop or workstation.** Not on a DAQ host.

This sets up the ssh paths everything else depends on: the MC-2 gateway
`mu2egateway01` and the hosts behind it (including the noVNC manager
`mu2e-mgr-01`), the MC-1 control room and workers behind `g2gateway01`,
and the teststands behind `mu2edaq-gateway`. It needs `bash`, `ssh` and
the Kerberos client (`kinit`, `klist`). Python is not needed.

**Step 1: get a checkout** (anywhere; it is not installed into `~/bin`):

```sh
git clone https://github.com/Mu2e/mu2edaq-shifter-tools.git
cd mu2edaq-shifter-tools
```

**Step 2: install the ssh configuration.** The installer asks for:

| Prompt | Default | Why |
|---|---|---|
| Fermilab username | from `klist`, else your local login | your principal `<name>@FNAL.GOV`; also your login for the noVNC portal |
| Shared DAQ account | `mu2edaq` | login on `mu2egateway01`, MC-2 hosts, teststands |
| Shared shift account | `mu2eshift` | login on MC-1 control room, `g2gateway01`, workers |
| DCS account | `mu2edcs` | login on `mu2e-dcs-*` |

Your principal must be in the `.k5login` of each shared account you
use. If you are not sure, accept the defaults; step 4 will tell you.

```sh
./install-ssh-config.sh --dry-run    # show what would change
./install-ssh-config.sh              # asks, then installs
```

It writes `~/.ssh/config_mu2e` (mode 600), adds
`Include ~/.ssh/config_mu2e` as the first line of `~/.ssh/config`, and
records your username in `~/.mu2edaq/env`. Changed files are backed up
to `<file>.bak.<timestamp>`, and a rerun with the same answers changes
nothing. To run it unattended, give every value: `./install-ssh-config.sh
-y -U jdoe`. Nothing is set for `Host *`; host-key checking and agent
and X11 forwarding stay as your own configuration has them.

If `~/.ssh/config` already has an `Include` of `config_mu2e` inside a
`Host` or `Match` block, the installer prints which line to move it
above and exits 1. ssh would otherwise apply it only to that block's
hosts.

**Step 3: get a ticket.**

```sh
kinit jdoe@FNAL.GOV
```

On macOS, `kinit` for a second principal makes that one the default.
`klist -l` lists them all and `kswitch -p jdoe@FNAL.GOV` switches back.

**Step 4: check.**

```sh
scripts/daq-ssh-check.sh        # ticket, resolved settings, live logins
scripts/daq-ssh-check.sh -P     # also the noVNC portal on mu2e-mgr-01
```

Every line should read `PASS`. A `Permission denied` on a live login
means your principal is not in that account's `.k5login`; ask the
account's owner to add it, or rerun step 2 with an account you are
authorised for.

**Step 5: use it.** For the VNC desktops on `mu2e-mgr-01`:

```sh
scripts/start-novnc-connection.sh
```

This opens `ssh -J mu2egateway01 -L <free>:localhost:443
<you>@mu2e-mgr-01` and a browser page with one card per session. Expect
a certificate warning, because the portal certificate is not issued for
`localhost`. Each session asks for that account's VNC password.

Each card shows the login account, the host and display it runs on, and
a description of what the desktop is for. The descriptions and the card
order come from `config/novnc-sessions.yaml`, and the list order is the
card order. To use your own order without editing the checkout, copy it
to `~/.config/mu2edaq/novnc-sessions.yaml`, or pass `--sessions FILE`.
Reading it needs PyYAML in the `python3` on your PATH:

```sh
python3 -m pip install --user pyyaml      # once; macOS /usr/bin/python3 lacks it
scripts/start-novnc-connection.sh -n      # shows which sessions file is used
```

Without PyYAML the dashboard still opens, in portal order and with no
descriptions. See `novnc-sessions.yaml(5)`.

Each card also has a **Native VNC** button. For every session with a
`display` in that file, the same ssh forwards a free local port to the
session's VNC port (5900 + display), and the button opens
`vnc://localhost:<port>`, which macOS hands to Screen Sharing. The card
shows that forward and the `open vnc://localhost:<port>` command, and a
panel at the top shows the whole tunnel and its equivalent `ssh` command.
The forwards close when you press Ctrl-C in the terminal running the
script. Use `--no-native` to skip them.

The file arranges the cards in labeled groups (`groups:`), drawn with a
separator between them. A session on a host other than the portal's,
such as the MC-1 control room consoles, gets a card with no browser
link and, once it has a `display`, a native link through its own ssh
to that host.

A session marked `rdp: true` (the MC-1 consoles, which serve a headless
GNOME session over RDP) gets a **Native RDP** button. It opens Windows App
(Microsoft's free RDP client, App Store) with
`rdp://full%20address=s:localhost:<port>&username=s:<user>`, through a
forward of a free local port to the host's port 3389. Each card's tunnel
details also give `open <session>.rdp` for a generated `.rdp` file. Windows
App asks for the RDP password, which is gnome-remote-desktop's own, not
the account's.

## 1. Remote side: account install on a DAQ host

> **Run on: the DAQ host, logged in as the shared account being set up**
> (for example `ssh mu2eshift@mu2e-mgr-01.fnal.gov`). Not on your laptop:
> it replaces `~/.bashrc` and `~/.bash_profile`.

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
