# mu2edaq-shifter-tools — interfaces

What this package exposes and what it reaches. Every claim carries the
`file:line` it was read from on branch `mu2e-sept-mega-review`
(2026-10-06). Behaviour marked *verified* was observed by running the
command against a local, non-DAQ target.

## 1. Command-line contracts

All commands take `--help`. Shell commands also read `$<NAME>_OPTS`
(e.g. `START_DAQ_SH_OPTS`) through `daq_script_opts`
(`scripts/daq-common.sh:257-268`), prepended to the command line.

| Command | Runs on | Touches | `--dry-run` | Exit codes |
|---|---|---|---|---|
| `start-daq.sh` | DAQ node | tmux, `ots` | yes | 0 ok · 1 tmux/config/session exists · 2 usage |
| `stop-daq.sh` | DAQ node | tmux `send-keys "ots -k"`, `kill-session` | yes | 0 ok/declined · 1 tmux/config · 2 usage |
| `scripts/daq-status.sh` | DAQ node | tmux (read) | — | 0 · 1 (`-q`: not all RUNNING) · 2 usage |
| `scripts/setup-online.sh` (sourced) | DAQ node | `cd`, `. setup_cmd` | yes | status of `setup_cmd`; 1 missing dir; 2 usage |
| `scripts/create-environment.sh` | DAQ node | HTTPS download + spack build | yes | **0 even when the download or build fails** (*verified*); 1 config; 2 usage |
| `scripts/send-run-control-command.sh` | anywhere | nothing (stub) | yes (exit 0) | **3 on every real call** (*verified*); 1 bad verb/config; 2 usage |
| `scripts/start-tmux.sh` | anywhere | tmux | yes | 0 · 1 · 2 |
| `scripts/daq-tunnels.sh` | workstation | ssh forwards | yes | 0 · 1 no ticket/bad offset · 2 usage; `restart` is always a dry run (*verified*) |
| `scripts/start-novnc-connection.sh` | workstation | ssh forward, browser | yes | ssh status; 1 |
| `scripts/manage-vnc-servers.sh` | workstation | remote `systemctl` | yes | ssh status (0 even if a port FAILED); 1 |
| `scripts/daq-network-verify.sh` | DAQ network host | `nmap -sn`, ARP table | yes | 0 · 1 · 2 |
| `scripts/get_krb_principal.sh` (sourced) | login | reads ticket cache | — | 0 · 1 no FNAL.GOV principal · 2 |
| `scripts/set_git_env.sh` (sourced) | login | `git config --global`, `ssh-add` | — | 0 (also on git failure) · 1 no principal · 2 |
| `scripts/get_krb_daq_principal.sh` (sourced) | login | `kinit -kt` | — | `kinit` status |
| `install-login.sh` | account | dotfiles, `~/bin` | yes | 0 (also when an `install` fails) · 1 · 2 |
| `bootstrap.sh` | checkout | `venv/`, pip | — | 0 · 1 · 2; `set -euo pipefail` |
| `daq-read-config` | anywhere | reads YAML | — | 0 · 1 `ConfigError` · 2 click usage |
| `daq-open-tunnels` | workstation | ssh forwards | yes | 0 · 1 · 2 |
| `daq-cluster-cp` | DAQ node | `scp -B` in parallel | yes | 0 · 1 any host failed · 2 missing source |
| `daq-ls2json` | anywhere | reads dirs | — | 0 · 1 |
| `daq-install-tools` | DAQ node | `mkdir` | yes | 0 · 1 |

Sourced scripts use `return N 2>/dev/null || exit N`
(e.g. `scripts/setup-online.sh:168`), so they work either way, but only
sourcing leaves the environment behind.

### 1.1 send-run-control-command.sh

Resolves `host:port` and then refuses (`scripts/send-run-control-command.sh:114-124`):

```
$ send-run-control-command.sh -c config/daq-operations.yaml -z partition_0 -e tracker start; echo rc=$?
Target: localhost:10010  (partition_0/tracker)                      # stdout
Command: start                                                      # stdout
send-run-control-command.sh: sending run-control commands is not implemented yet   # stderr
send-run-control-command.sh: use the otsdaq web GUI on localhost:10010 instead      # stderr
rc=3
```

`-n` prints the same two lines plus `Dry run: no datagram sent (payload
format not implemented).` and exits 0. An unknown verb exits 1 before any
target is computed. No socket is opened on any path; the intended
`nc -u` send exists only as a comment (`:133`). Verdict: explicit refusal,
not silent success.

The port is `ots_port_offset + port_offset`
(`src/mu2edaq_shifter_tools/config.py:421-430`): 10010 for tracker and
10020 for trigger with the shipped config. The comment that this "matches
how ots itself is configured" is not verified; every `setup_ots.sh` copy
(`otsdaq-mu2e-config/Data_*/setup_ots.sh`, `mu2edaq-operations/scripts/ops_setup_ots.sh:132-178`)
gives tracker and trigger `OTS_MAIN_PORT=3065`.

## 2. Network endpoints

Nothing in the package listens as a service. Every endpoint below is an
outbound connection or an SSH local forward bound on the operator's
loopback.

### 2.1 Tunnel → gateway table

| Command | ssh target | Jump host | Local port | Remote end | Source |
|---|---|---|---|---|---|
| `daq-tunnels.sh` group `daq` | `mu2eshift@mu2e-dcs-01.fnal.gov` | `mu2eshift@mu2egateway02.fnal.gov` | 3075 3085 3025 3045 5029 3095 30351 3065 (+offset) | `mu2e-cfo-01:<same>` | `scripts/daq-tunnels.sh:62-72,81-82,309-311` |
| | | | 5033 (+offset) | `mu2e-dl-01-data:5033` | `:68` |
| | | | 8877 (fixed) | `mu2e-dl-01:8877` | `:69` |
| `daq-tunnels.sh` group `extra` | same | same | 3000 (fixed) | `mu2e-dcs-01:3000` (Grafana) | `:74,330-332` |
| `daq-open-tunnels` `daq-gateway` | `mu2edaq@mu2edaq-gateway.fnal.gov` | none | uid+973+3201 | `localhost:<same>` on the gateway | `config/tunnels.example.yaml:23-26`, `src/mu2edaq_shifter_tools/open_tunnels.py:96-110` |
| `daq-open-tunnels` `gateway01` | `mu2edaq@mu2egateway01.fnal.gov` | none | uid+973+3203 | `localhost:<same>` | `config/tunnels.example.yaml:28-31` |
| `daq-open-tunnels` `gateway02` | `mu2edaq@mu2egateway02.fnal.gov` | none | uid+973+3203 (**collides** with gateway01) | `localhost:<same>` | `config/tunnels.example.yaml:33-36` |
| `start-novnc-connection.sh` | `$USER@mu2e-mgr-01.fnal.gov` | `mu2egateway01.fnal.gov` (default when host is mu2e-mgr-01) | free port | `localhost:443` (noVNC manager) | `scripts/start-novnc-connection.sh:53-54,313-314` |
| `manage-vnc-servers.sh` | `mu2ecr01@mu2e-mgr-01.fnal.gov` | none (relies on `~/.ssh/config`) | — | `systemctl <action> vncserver@:N` | `scripts/manage-vnc-servers.sh:134` |

`config/tunnels.yaml` is a tracked symlink to `tunnels.example.yaml`. In
every tunnel the remote port equals the local port. `jump` is unset on all
three `tunnels.yaml` entries: the gateway named in `hostname` is the ssh
target, not a ProxyJump.

**OTS :8443.** No tunnel forwards 8443 on either gateway. The shifter
site disputes whether the OTS GUI is `mu2egateway01:8443` or
`mu2egateway02:8443`; the tunnels neither confirm nor refute either. What
they do say: `daq-tunnels.sh` reaches the otsdaq GUIs on `mu2e-cfo-01`
ports 30xx/5029 via `mu2egateway02` as jump host, and
`start-novnc-connection.sh` uses `mu2egateway01` as jump host.

### 2.2 Other outbound connections

| What | Endpoint | Source |
|---|---|---|
| quick-start helper download | `https://raw.githubusercontent.com/Mu2e/otsdaq-mu2e/refs/heads/<ref>/tools/mu2e-quick-spack-start.sh` (`<ref>` default `develop`) | `scripts/create-environment.sh:117-120` |
| cluster copy | `scp -B -q <files> <user>@<host>:<dest>` for hosts in `data/daq_nodes.json` | `src/mu2edaq_shifter_tools/cluster_cp.py:95` |
| network sweep | `nmap -sn` 192.168.6.0/24 (control), 192.168.7.0/24 (data), 192.168.157.0/24 (ipmi) | `scripts/daq-network-verify.sh:43,114` |
| Kerberos | `kinit -kt ~/.krb5/<user>.keytab`, fallback `mu2edaq/mu2edaq/mu2e.fnal.gov@FNAL.GOV` | `scripts/get_krb_daq_principal.sh:48-49` |
| pip | `bootstrap.sh` installs from the package index; `start-daq.sh` runs it automatically when PyYAML/click are missing | `start-daq.sh:83-95` |

### 2.3 Example ssh client configuration

`config/ssh-config-mu2e.example` is documentation, not read by any
command. Evaluated with `ssh -G -F config/ssh-config-mu2e.example <host>`:

| Host | ProxyJump actually applied | Intended block |
|---|---|---|
| `mu2e-trk-01.fnal.gov`, `mu2e-calo-03`, `mu2e-cfo-01`, `mu2e-dl-01` | `mu2edaq@mu2edaq-gateway.fnal.gov` | `mu2egateway01.fnal.gov` (`:63-75`) |
| `mu2e-mc1-cr-01` | `mu2edaq@mu2edaq-gateway.fnal.gov` | `mu2eshift@mu2egateway01.fnal.gov` (`:58-60`) |
| `mu2edaq04.fnal.gov` | `mu2edaq@mu2edaq-gateway.fnal.gov` | same (`:48-50`) |
| `mu2egateway01.fnal.gov` | none | none |

`Host mu2e-*` (`:44-45`) precedes the specific blocks and ssh keeps the
first value it obtains. The `Host *` block also sets
`StrictHostKeyChecking no`, `ForwardAgent true` and the obsolete
`Cipher blowfish` (`:15-20`). Bootstrap's generator template
(`Bootstrap/ssh/templates/config_mu2edaq.template`) has no catch-all
`mu2e-*` block.

## 3. Files

### 3.1 Written into an account by `install-login.sh`

| Target | Source | Mode | Overwrite policy | Source line |
|---|---|---|---|---|
| `~/.aliases`, `~/.bash_logout`, `~/.bash_profile`, `~/.bashrc` | `login/*` | 644 | existing file copied to `<file>.bak.<YYYYmmddHHMMSS>` (`cp -p`), then replaced with `install` | `install-login.sh:89-100,111-115` |
| `~/bin/<name>` for all 13 files in `scripts/` (including the `daq-common.sh` library) | `scripts/*` | 755 | same | `:120-124` |
| `~/bin/start-daq.sh`, `~/bin/stop-daq.sh` | top level | 755 | same | `:127-134` |
| `~/.mu2edaq/env` | generated: `MU2EDAQ_ROOT=<checkout>` | umask | backed up, rewritten | `:140-157` |

It writes nothing else: no crontab, no symlinks, no ssh config, no keytab.
Re-running is safe but accumulates one backup per file per run; command
backups keep mode 755 and therefore sit on the `PATH`. The script exits 0
at `:168` regardless of whether an individual `install` failed.

### 3.2 Written at run time

| Path | Writer | Content |
|---|---|---|
| `~/.mu2edaq/daq_tunnels` | `daq-tunnels.sh` | `pid, group, host, offset` per ssh |
| `~/.mu2edaq/open_tunnels` | `daq-open-tunnels` | `pid, hostname, username, local_port, label` |
| `~/.gitconfig` (`user.name`, `user.email`) | `set_git_env.sh` (`--global` default, `scripts/set_git_env.sh:48,90-91`) | principal and its user part |
| `$TMPDIR/tmp.*/dashboard.html` | `start-novnc-connection.sh` | session links, with the VNC password as a query parameter when `~/.novnc_password` exists; removed on exit |
| `<outdir>/{arp_table,routing_table,filtered_arp_table}.txt` | `daq-network-verify.sh` | sweep results |
| `.env` in the checkout | `bootstrap.sh` (from `.env.example`, first run only) | commented defaults |

### 3.3 Read

`config/daq-operations.yaml`, `config/tunnels.yaml`,
`config/current_release.yaml`, `data/daq_nodes.json`,
`data/mu2e_kerberos_principals.json` (reference only), `.env` files
(`$MU2EDAQ_DOTENV`, `~/.mu2edaq/env`, `<root>/.env`, `./.env`, first file
wins per key, all below the real environment —
`scripts/daq-common.sh:95-136`, `src/mu2edaq_shifter_tools/config.py:168-218`).

## 4. `daq-read-config` verbs

`src/mu2edaq_shifter_tools/read_config.py:29-46`. Text output is bare;
lists are one space-separated line; dicts print as JSON.

| Verb | Needs `-e` | Value |
|---|---|---|
| `print` (default) | | whole file |
| `config-file`, `config-path` | | resolution |
| `partitions`, `environments`, `active-envs` | | names |
| `base-release`, `ots-port-offset` | | partition fields |
| `directory`, `setup`, `port-offset`, `gateway-port` | yes (defaults to first active env) | environment fields |
| `resource-manager-port` | | `resource_manager_port`, default 1973 |

Shell consumers: `active-envs` (start/stop/status/setup-online),
`partitions` (stop `-A`, status), `directory` and `setup` (setup-online,
create-environment), `base-release` (create-environment), `gateway-port`
(send-run-control-command). **Nobody consumes `resource-manager-port`**,
and no socket is ever opened to it. The resource manager in this
superproject binds 8080 (`mu2edaq-resource-manager/docs/INTERFACES.md`
§1.2); that defect is the resource-manager review's staged RM-008, to be
filed here.

## 5. Contracts this package assumes of others

| Assumption | Holds? | Evidence |
|---|---|---|
| `setup_cmd` subsystem names are accepted by the release's `setup_ots.sh` | not for `calorimeter`: every copy accepts only `calo` | `config/daq-operations.example.yaml:14`; `otsdaq-mu2e-config/Data_shift/setup_ots.sh:91` |
| `ots` runs in the foreground of its tmux pane, so `pane_current_command` reads `ots*` | not verified against a live ots | `scripts/daq-status.sh:98-99`, `stop-daq.sh:145-146` |
| gateway port = `ots_port_offset + port_offset` | not verified; disagrees with `OTS_MAIN_PORT` tables | §1.1 |
| `ssh-selector` and `~/config/mu2e_daq.yaml` exist in the account | `ssh-selector` from mu2edaq-cluster-tools; the config path is installed by neither package | `login/aliases:13-14`; `mu2edaq-cluster-tools/install.sh:119` |
| `data/daq_nodes.json` names the cluster nodes | no: `mu2etrk01..09`, `mu2ecalo01..08`, `mu2ecrv01..08`, `mu2edaq01..13`; 30/38 did not resolve from the reviewer's workstation; MC-2 nodes are `mu2e-trk-NN` (18), `mu2e-calo-NN` (14) | `data/daq_nodes.json:3,18,29,39` |

## 6. Login sequence (group accounts)

`login/bash_profile:24-36`: `get_krb_principal.sh` → `set_git_env.sh` →
`kdestroy` → `get_krb_daq_principal.sh`. `login/bashrc:61-76` replaces a
shared credential cache with a random per-session one, but only for
uid 51937 (`mu2eshift`), and its second test compares against
`/tmp/krb5cc_55438`.
