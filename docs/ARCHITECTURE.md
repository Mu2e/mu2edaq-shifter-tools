# Architecture

This toolkit is operator tooling for the Mu2e DAQ. It contains no
compiled code and no long-running service: every piece is a command a
shifter or a script invokes.

## Two independent halves

The commands fall into two groups that share only the configuration
layer:

**Partition lifecycle** — run on the DAQ cluster, manage `otsdaq`
(`ots`) instances inside tmux, and need the operations YAML:
`start-daq.sh`, `stop-daq.sh`, `daq-status.sh`, `setup-online.sh`,
`create-environment.sh`, `send-run-control-command.sh`,
`start-tmux.sh`.

**Shifter workstation plumbing** — run wherever the operator is, and
reach the control room from outside it: `daq-tunnels.sh`,
`daq-open-tunnels`, `start-novnc-connection.sh`,
`manage-vnc-servers.sh`, `daq-cluster-cp`, `daq-network-verify.sh`, and
the Kerberos/git login scripts.

Only the first group needs Python, and only because it reads YAML
through `daq-read-config`. The second group needs nothing but `bash`
and `ssh`, which is a property worth preserving — see
[CONFIGURATION.md](CONFIGURATION.md#yaml-or-environment).

## The configuration layer

```
                  command line
                       |
                  environment
                       |
                    .env files
                       |
                   config file
                       |
                    default
                       |
        +--------------+--------------+
        |                             |
  daq-common.sh              mu2edaq_shifter_tools.config
   (shell commands)              (Python commands)
        |                             |
        +----------> daq-read-config <-+
                          |
                 config/daq-operations.yaml
```

`daq-common.sh` and `mu2edaq_shifter_tools.config` are deliberate
mirrors of each other: the same precedence, the same search path, the
same root discovery. A shell command and a Python command therefore
resolve any setting identically.

### No shell script parses YAML

The shell commands do not read the operations file. They call
`daq-read-config` once per value, selecting it with a *command verb*:

```sh
daq-read-config -z partition_0 active-envs
daq-read-config -z partition_0 -e tracker directory
```

The consequence for maintenance is the one thing to remember about this
codebase: **adding a configuration field means adding a verb to
`read_config.py`**, not adding a parser to a script. `VERBS` in that
module is the single source of truth for the list, and
`daq-read-config --list-verbs` prints it.

Text output from that tool is bare — no labels, no quoting — because
callers capture it with command substitution, and a list is printed
space-separated on one line because the callers' `for` loops expect
that. `tests/test_read_config.py` asserts the exact output shape for
this reason.

### `daq-common.sh`

Sourced by every shell command. It replaced four verbatim copies of an
artdaq-style `expr`-based option parser, which is where several of the
bugs fixed in v1.1.0 were hiding.

It provides root discovery, `.env` loading, the config search,
interpreter discovery, `daq-read-config` invocation, `<COMMAND>_OPTS`
expansion, `Pass`/`Fail` reporting and a confirmation helper. Full API
in `daq-common.sh(3)`.

Scripts locate it by looking next to themselves, then in `scripts/`,
then in `~/bin` — which covers running from a checkout, running a
top-level command, and running an installed copy.

## The DAQ start/stop model

`start-daq.sh` creates one tmux session per partition, `daq-<partition>`:

```
session daq-partition_0
  window partition_0-main              a plain shell for the operator
  window daq-partition_0-tracker       source setup-online.sh; ots; exec bash
  window daq-partition_0-trigger       source setup-online.sh; ots; exec bash
```

Windows are **named**, and `stop-daq.sh` and `daq-status.sh` address
them by name. The original scripts addressed them positionally
(`daq-$partition:$ii`, re-deriving `$ii` from `active-envs`), which
meant `kill_daq` sent `ots -k` to the wrong window whenever the two
orderings disagreed. Naming removes the coupling entirely.

`ots` is followed by `exec bash` so the window survives for inspection
after `ots` exits.

`stop-daq.sh` sends `ots -k` into each window, then polls
`pane_current_command` until no pane is running `ots`, and only then
kills the session. `--kill-session` skips the wait.

`setup-online.sh` **must be sourced**: it changes directory and defines
the ots environment in the caller's shell. The login aliases define
`setup_online` as exactly that. It unsets all of its own variables
before returning, so the ots environment is the only thing it leaves
behind.

## Kerberos and git bootstrap

The installed `~/.bash_profile` runs four steps, and **the order is
load-bearing**:

```
1. get_krb_principal.sh       KRB5_PRINCIPAL <- the human's login ticket
2. set_git_env.sh             git identity + GIT_SSH_COMMAND from it
3. kdestroy                   drop the human's ticket
4. get_krb_daq_principal.sh   kinit -kt the group account's keytab
```

Why each step is where it is:

- Steps 1–2 run **before** step 4 so the git identity comes from the
  individual, not the group account. Commits made from a shared
  `mu2eshift` account are still attributed to the person who made them.
- Step 3 runs **after** step 2 so that once the git environment is set
  up, the human's credentials are no longer available to anything
  running as the group account.
- Step 4 runs **last** because it needs step 3 to have cleared the
  cache.

Moving step 4 earlier would attribute every commit to the group
account. Dropping step 3 would leave the human's ticket exposed.

`login/bashrc` additionally rewrites `KRB5CCNAME` to a randomised path
whenever the credential cache is the shared group-account one, so
shifters on the same node do not end up sharing credentials. Valid
group principals are listed in `data/mu2e_kerberos_principals.json`.

The identity is always derived from the keytab or ticket, never
hardcoded, so one set of dotfiles serves every account.

## Deployment layout

`install-login.sh` defines what "installed" means:

```
login/*          ->  ~/.<name>          mode 644
scripts/*        ->  ~/bin/<name>       mode 755
start-daq.sh     ->  ~/bin/start-daq.sh
stop-daq.sh      ->  ~/bin/stop-daq.sh
MU2EDAQ_ROOT     ->  ~/.mu2edaq/env
```

So **`scripts/` is the directory whose contents land on the `PATH`**. A
helper that shifters should be able to invoke by name belongs there.

The recorded `MU2EDAQ_ROOT` closes the one gap in root discovery: a
command sitting in `~/bin` cannot find `config/` and `data/` by walking
up from itself. It is written as a `.env` file rather than exported
from a dotfile so that it ranks below the real environment and can
still be overridden.

## Port allocation

Three unrelated schemes coexist. Check which applies before changing a
port.

| Scheme | Used by | Rule |
|---|---|---|
| uid-derived | `daq-open-tunnels` | local port = `uid + 973` + per-entry offset; keeps concurrent users apart with no coordination |
| service table | `daq-tunnels.sh` | fixed per-service base ports plus a caller-supplied `--offset`; a `!` marks a port that takes no offset |
| ots offsets | the DAQ itself | `ots_port_offset` + per-environment `port_offset`; exposed as the `gateway-port` verb |

## Tunnel process tracking

Both tunnel commands record the pid of each `ssh` they start, and stop
exactly those pids.

For `daq-tunnels.sh` this replaced `pkill -f "ssh.*mu2e-"`, which also
matched the operator's own interactive ssh sessions to any Mu2e host,
and any unrelated tunnel to a Mu2e machine. Pattern matching survives
as `--all-matching` for when the state file has been lost, but it is
no longer what `stop` does by default.

`daq-tunnels.sh` opens two ssh processes rather than one, so that a
single unavailable forward — which `ExitOnForwardFailure` turns into a
dead ssh — cannot take the other group down with it.

## Not implemented

**`send-run-control-command.sh`** has complete option handling,
configuration resolution and port calculation, and is covered by the
tests, but exits 3: the otsdaq gateway supervisor's UDP payload format
has not been transcribed. The file says so, and carries notes on what
is needed. Use the otsdaq web GUI through the forwards from
`daq-tunnels.sh` instead.

**ResourceManager** does not exist. It was sketched in the original
README and the design is recorded below, so the intent is not lost.
The empty placeholder file it had was removed in v1.1.0.

### ResourceManager design sketch

The problem it addresses: nothing currently prevents two DAQ partitions
from claiming the same DTC, or from choosing overlapping ports.

The sketch was:

- a **ResourceManager** reading a static inventory of available
  resources (DTCs and similar) and tracking which active partition has
  claimed each one, with `claim` / `release` / `status` /
  `transaction_{start,end}` operations
- a **ResourceSupervisor** inside each ots instance, talking to the
  ResourceManager to reserve fungible resources
- transaction semantics: any failure within a transaction makes every
  subsequent call in it fail until the transaction ends, which puts the
  ots state machines into their `failed` state

`resource_manager_port` (default 1973) is already reserved for it in
the operations YAML, and `daq-read-config resource-manager-port`
returns it.

## Repository conventions

- Remote is `Mu2e/mu2edaq-shifter-tools`, public.
- CI runs the Mu2e reusable `git-whitespace` and
  `mu2e-format-single-pkg` workflows on every push and PR to `main`.
  **Trailing whitespace fails the build.**
- Tags use a `tNN.NN.NN` form (`t01.00.00`).
- Python is `black`-formatted. No linter is configured, by choice.
- Anything that touches a live host gets `--dry-run`; anything that can
  interrupt data taking gets `--yes` and a confirmation prompt.

## See also

- [INSTALL.md](INSTALL.md) — deployment
- [BUILD.md](BUILD.md) — build, test, and how to extend the toolkit
- [CONFIGURATION.md](CONFIGURATION.md) — every setting and its precedence
