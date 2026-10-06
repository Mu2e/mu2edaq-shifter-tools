# Staged issues — mu2edaq-shifter-tools

Findings from the September 2026 DAQ mega-review (`mu2e-sept-mega-review`),
2026-10-06. Target repository: **`Mu2e/mu2edaq-shifter-tools`** (public,
issues enabled).

**Why staged.** Per review contract §9.1 no GitHub write was attempted. Each
block below is the issue body verbatim, fingerprint included, for the
orchestrator's filing script. Label each with `mega-review` plus the
category shown.

**Dedup.** `gh issue list -R Mu2e/mu2edaq-shifter-tools --state all --limit 300`
returned `[]` on 2026-10-06: the repository has never had an issue, so no
fingerprint or title overlap is possible. One defect in this repository was
already staged by another package's review and is **not** re-filed here:
`mu2edaq-resource-manager` RM-008 (`resource_manager_port: 1973`,
fingerprint `50f56b4c`). Supplementary evidence for it is at the end of this
file, to be added to that issue when it is filed.

14 findings: 11 × S3, 3 × S4. No S1 or S2.

---

## ST-001

**Title:** `[tunnels] daq-tunnels.sh restart always runs as a dry run`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `scripts/daq-tunnels.sh:342-343`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`restart` re-invokes the script as `"$0" ${dry_run:+-n} ${assume_yes:+-y} ... stop`
and `"$0" ${dry_run:+-n} ... start`. `dry_run` and `assume_yes` are always
`0` or `1`, never empty, so `${var:+...}` always expands: both halves run with
`-n` (and the stop half with `-y`). `restart` never stops or starts a tunnel
and exits 0.

## Evidence

```
$ grep -n 'dry_run:+' scripts/daq-tunnels.sh
342:        "$0" ${dry_run:+-n} ${assume_yes:+-y} -s "$state_file" stop
343:        "$0" ${dry_run:+-n} -o "$offset" -u "$user" -H "$host" \
$ dry_run=0; echo "[${dry_run:+-n}]"
[-n]
# run against a scratch state file and a local host (paths shortened)
$ scripts/daq-tunnels.sh -s /tmp/st -H 127.0.0.1 -J none restart; echo rc=$?
Stopping tunnels...
  no recorded tunnels in /tmp/st
...
  + ssh -f -K -N -q -o ExitOnForwardFailure=yes -L 3075:mu2e-cfo-01:3075 ... mu2eshift@127.0.0.1
...
Dry run: no tunnels were opened.
rc=0
```

No test covers `restart` (`grep -n restart tests/*.py` hits only
`manage-vnc-servers.sh`).

## Why it matters

An operator restarting dead GUI forwards gets a zero exit and the same dead
forwards. The output does say "Dry run", which is why this is S3 rather than
S2. A naive fix that only corrects `-n` would still pass `-y` and skip the
stop confirmation.

## Suggested fix

Build the flags explicitly: `[ "$dry_run" -eq 1 ] && flags+=(-n)` and likewise
for `-y`; add a `restart` case to `tests/test_shell.py` asserting the child
invocations carry no `-n` when the parent has none.

## Related

- ST-008 (same file, service table)

<!-- mega-review-fingerprint: eff36243 -->

---

## ST-002

**Title:** `[create-environment] exits 0 when the helper download or the spack build fails`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `scripts/create-environment.sh:117-132`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`curl`, `chmod` and `./mu2e-quick-spack-start.sh` are run through `run()`,
whose status is never checked, and the script ends with an unconditional
`exit 0`. A failed download, a failed spack build or a failed update all
exit 0. The man page claimed exit 1 for exactly these cases (corrected on
the review branch).

## Evidence

```
$ sed -n '117,132p' scripts/create-environment.sh
    run curl -fsSL -O \
        "https://raw.githubusercontent.com/Mu2e/otsdaq-mu2e/refs/heads/$otsdaq_ref/tools/$QUICK_START_SCRIPT"
    run chmod +x "$QUICK_START_SCRIPT"
    run "./$QUICK_START_SCRIPT" --develop --upstream "$base_release"
...
    run "./$QUICK_START_SCRIPT" --develop
...
exit 0
# scratch test release whose helper is a stub that exits 7 (paths shortened):
$ scripts/create-environment.sh -c /tmp/ops.yaml -e tracker; echo rc=$?
Updating existing test release /tmp/rel
  + ./mu2e-quick-spack-start.sh --develop
fake helper: failing
rc=0
```

## Why it matters

A wrapper or a shifter checklist that tests the status believes the test
release was built. `setup-online.sh` then sources a partial release. The
helper is also fetched unpinned from `develop` and executed, so the build is
not reproducible unless `-b <tag>` is given.

## Suggested fix

`run curl ... || daq_die "download failed"` and the same for the helper
(`DAQ_EXIT_CODE` preserved), or `set -e` around the build block. Add a test
with a stub helper that exits non-zero.

## Related

- ST-001 (same `run()` pattern)

<!-- mega-review-fingerprint: 36af0985 -->

---

## ST-003

**Title:** `[stop-daq] ots -k reaches only active_environments windows; start-daq -e windows are killed by SIGHUP`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `stop-daq.sh:119-155`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`start-daq.sh -e ENV` starts any named environment
(`start-daq.sh:69,100-104,127-134`). `stop-daq.sh` sends `ots -k` only to
windows of the partition's `active-envs` (`:119-128`), then polls every pane
for `ots` (`:145-146`). A window for a non-active environment never gets
`ots -k`, so the poll runs to the full timeout (default 30 s) and
`tmux kill-session` (`:155`) delivers SIGHUP to a running `ots`.

## Evidence

```
$ sed -n '119,128p' stop-daq.sh
    envs="$(daq_read_config --config "$config_file" \
                --partition "$target" active-envs)" || envs=""
...
    for env in $envs; do
...
            run tmux send-keys -t "$session:$window" "ots -k" Enter
$ grep -n 'environments="$environments' start-daq.sh
69:        -e|--environment) shift; environments="$environments ${1:-}";;
```

The man page said windows "added by hand" still stop correctly (corrected on
the review branch).

## Why it matters

`ots -k` is the orderly shutdown that also stops the ots-managed processes.
A SIGHUP to the front-end shell is not guaranteed to do the same, so remote
artdaq/xdaq processes of that environment can be left running and hold ports
or DTCs for the next start.

## Suggested fix

Enumerate the session's `daq-<partition>-*` windows with
`tmux list-windows -F '#{window_name}'` and send `ots -k` to each, instead of
re-deriving the list from `active-envs`.

## Related

- ST-001

<!-- mega-review-fingerprint: 92169e24 -->

---

## ST-004

**Title:** `[login] set_git_env.sh writes the operator's identity into the shared account's ~/.gitconfig`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `scripts/set_git_env.sh:48,90-91`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`set_git_env.sh` defaults to `git config --global`, which on a group account
(`mu2eshift`, `mu2edaq`, ...) is one `~/.gitconfig` shared by every session
of that account. Two operators logged in at once share whichever identity
was written last. The documentation (`docs/ARCHITECTURE.md`, the man page)
states that commits from a shared account "are still attributed to the
individual", which holds only for one concurrent login per account.

## Evidence

```
$ grep -n 'scope=\|git config $scope' scripts/set_git_env.sh
48:    local scope="--global"
90:    git config $scope user.email "$KRB5_PRINCIPAL" \
91:        && git config $scope user.name "$user"
# the same organisation's other tooling does the opposite:
$ grep -n 'git config --global' ../mu2edaq-operations/scripts/ops_setup_ots.sh
626:	# git config --global user.email $EMAIL_ADDR #DO NOT DO THIS -- this changes for all users of shared username
$ grep -n 'unset user' ../mu2edaq-operations/scripts/check_keys.sh
42:git config -f $1/.gitconfig --unset user.name
43:git config -f $1/.gitconfig --unset user.email
```

`ops_setup_ots.sh:653-656` exports `GIT_AUTHOR_*`/`GIT_COMMITTER_*` instead,
which are per shell. Where both packages are deployed, every login writes the
identity and the next `check_keys.sh` run removes it.

## Why it matters

Commit attribution on the shared accounts is the problem Mu2e/daq-operations#47
(closed) set out to fix. Silent mis-attribution is possible whenever two
shifters use the same group account; the two packages also undo each other.
S3 rather than S2 because the consequence is audit-trail quality, not DAQ
operation.

## Suggested fix

Export `GIT_AUTHOR_NAME/EMAIL` and `GIT_COMMITTER_NAME/EMAIL` from the
principal (environment ranks above config in git) and stop writing
`--global`; keep `--local` as the explicit opt-in. Align with
mu2edaq-operations' `ops_setup_ots.sh`.

## Related

- Mu2e/daq-operations#47
- mu2edaq-operations `scripts/check_keys.sh`

<!-- mega-review-fingerprint: 13cb81c1 -->

---

## ST-005

**Title:** `[inventory] data/daq_nodes.json names hosts that are not the MC-2 readout nodes`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `data/daq_nodes.json:3`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`daq-cluster-cp` copies to the hosts in `data/daq_nodes.json`
(`src/mu2edaq_shifter_tools/cluster_cp.py:26,43`). The file lists
`mu2edaq01..13`, `mu2etrk01..09`, `mu2ecrv01..08` and `mu2ecalo01..08`. The
MC-2 readout nodes are `mu2e-trk-NN`, `mu2e-calo-NN`, `mu2e-crv-NN`
(mu2edaq-operations `scripts/nodes_config.yaml`: 18 tracker, 14
calorimeter, 1 CRV). This is a sixth disagreeing copy of the cluster
topology (contract §9.7 lists four; mu2edaq-resource-manager RM-009 a fifth).

## Evidence

```
$ python3 -c "import json;d=json.load(open('data/daq_nodes.json'));print({k:len(v) for k,v in d.items()})"
{'daq': 13, 'trk': 9, 'crv': 8, 'calo': 8}
# name resolution from the reviewer's workstation, 2026-10-06
daq  resolve 6 / 13  (mu2edaq03 05 06 09 10 11 12 do not resolve)
trk  resolve 1 / 9   mu2etrk01  -> 131.225.52.35
crv  resolve 0 / 8
calo resolve 1 / 8   mu2ecalo01 -> 131.225.244.20
     mu2e-trk-01 -> 131.225.245.30, mu2e-calo-01 -> 131.225.245.60
```

DNS was queried from outside the DAQ networks; internal views may differ,
so "does not resolve" is evidence, not proof, that a name is dead.

## Why it matters

`daq-cluster-cp --trk` copies to a list that does not contain a single MC-2
tracker node, and the two names that resolve are other machines. A copy
"succeeds" for those and fails for the rest.

## Suggested fix

Generate the groups from one authoritative inventory (the Wave 2 topology
decision) instead of a hand-kept JSON; until then, regenerate it from
mu2edaq-operations `node_list.py -l mc2 -n lab --json`.

## Related

- mu2edaq-resource-manager RM-009; contract §9.7 topology copies

<!-- mega-review-fingerprint: 3d9cdca7 -->

---

## ST-006

**Title:** `[ssh] ssh-config-mu2e.example routes every mu2e-* host through the HEERC gateway and disables host-key checking`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `config/ssh-config-mu2e.example:44-45`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`Host mu2e-*` with `ProxyJump mu2edaq@mu2edaq-gateway.fnal.gov` (the HEERC
test-stand gateway) precedes the specific MC-2 blocks that set
`ProxyJump mu2egateway01.fnal.gov`. ssh keeps the first value obtained, so
the specific blocks never apply. The `Host *` block also ships
`StrictHostKeyChecking no`, `ForwardAgent true` and the obsolete
`Cipher blowfish`.

## Evidence

```
$ for h in mu2e-trk-01.fnal.gov mu2e-cfo-01.fnal.gov mu2e-mc1-cr-01; do
    ssh -G -F config/ssh-config-mu2e.example $h | grep '^proxyjump'; done
proxyjump mu2edaq@mu2edaq-gateway.fnal.gov
proxyjump mu2edaq@mu2edaq-gateway.fnal.gov
proxyjump mu2edaq@mu2edaq-gateway.fnal.gov
$ grep -n 'Cipher\|ForwardAgent\|StrictHostKeyChecking' config/ssh-config-mu2e.example
15:        Cipher                  blowfish
16:        ForwardAgent            true
20:        StrictHostKeyChecking   no
```

Bootstrap's generator template (`ssh/templates/config_mu2edaq.template`)
has no catch-all `mu2e-*` block and routes MC-2 hosts via its MC-2 gateway.

## Why it matters

A shifter who copies this example reaches MC-2 and MC-1 nodes through the
test-stand gateway (or fails to), forwards their agent to every host, and
accepts any host key without warning.

## Suggested fix

Delete the `Host mu2e-*` block (or move it last), remove
`StrictHostKeyChecking no`, `ForwardAgent` and `Cipher` from `Host *`, or
replace the example with a pointer to Bootstrap's `mu2e-ssh-setup`.

## Related

- Bootstrap `ssh/templates/config_mu2edaq.template`

<!-- mega-review-fingerprint: c47da10d -->

---

## ST-007

**Title:** `[config] daq-operations.example.yaml passes "calorimeter" to setup_ots.sh, which accepts only "calo"`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `config/daq-operations.example.yaml:14`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

The `calorimeter` environment's `setup_cmd` ends in `setup_ots.sh calorimeter`.
`setup-online.sh` sources it with that argument
(`scripts/setup-online.sh:156`). Every `setup_ots.sh` copy recognises
`calo` and prints `Invalid parameter!` for anything else.

## Evidence

```
$ grep -n calorimeter config/daq-operations.example.yaml
12:      calorimeter:
14:        setup_cmd: "/home/mu2edaq/test_rel_v9_00_00/setup_ots.sh calorimeter"
20:    # - "calorimeter"
$ grep -n '== "calo' ../otsdaq-mu2e-config/Data_shift/setup_ots.sh ../mu2edaq-operations/scripts/ops_setup_ots.sh
../otsdaq-mu2e-config/Data_shift/setup_ots.sh:91:elif [ $subsystem == "calo" ]; then
../mu2edaq-operations/scripts/ops_setup_ots.sh:127:elif [ $subsystem == "calo" ]; then
```

## Why it matters

Activating the calorimeter environment (it is commented out of
`active_environments` today) makes its tmux window print
`Invalid parameter!` and start `ots` with no environment set up.

## Suggested fix

Use `setup_ots.sh calo`. Optionally have `setup-online.sh` fail when the
sourced setup returns non-zero before `start-daq.sh` runs `ots`.

## Related

- ST-008 (other drift against the setup_ots.sh tables)

<!-- mega-review-fingerprint: 7ed7d424 -->

---

## ST-008

**Title:** `[tunnels] daq-tunnels.sh service ports disagree with every setup_ots.sh port table`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `scripts/daq-tunnels.sh:62-72`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

The default `daq` table forwards `trig=3045` and `stm=30351` to
`mu2e-cfo-01`. Every `setup_ots.sh` copy gives the trigger supervisor
`OTS_MAIN_PORT=3065` (with `#3045` left as a comment) and stm 3035. The
table is hand-kept and not derived from any otsdaq configuration. The
review did not verify which ports the supervisors on `mu2e-cfo-01` actually
bind.

## Evidence

```
$ sed -n '63,72p' scripts/daq-tunnels.sh        # ten lines, joined here
shift=3075:mu2e-cfo-01 crv=3085:mu2e-cfo-01 calo=3025:mu2e-cfo-01 trig=3045:mu2e-cfo-01 dqm=5029:mu2e-cfo-01 dqmvis=5033:mu2e-dl-01-data crvdqm=8877!:mu2e-dl-01 cfo=3095:mu2e-cfo-01 stm=30351:mu2e-cfo-01 trk=3065:mu2e-cfo-01
$ grep -n 'OTS_MAIN_PORT=3065\|OTS_MAIN_PORT=3035' ../otsdaq-mu2e-config/Data_shift/setup_ots.sh
81:export          OTS_MAIN_PORT=3035
97:export          OTS_MAIN_PORT=3065
139:export          OTS_MAIN_PORT=3065 #3045
```

## Why it matters

The forward reports `DAQ: OK` while `localhost:3045` reaches nothing, and
the shifter concludes the trigger GUI is down. `MU2EDAQ_TUNNEL_SERVICES`
can override the table, which is the workaround.

## Suggested fix

Confirm the live ports on `mu2e-cfo-01`, then correct the table; longer
term, derive it from the same source as `setup_ots.sh` (Wave 2 port table).

## Related

- ST-001, ST-007; mu2edaq-operations review (OTS_MAIN_PORT collisions)

<!-- mega-review-fingerprint: b8c8fa4b -->

---

## ST-009

**Title:** `[login] bashrc shared-cache detection hard-codes uid 51937 and /tmp/krb5cc_55438`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `login/bashrc:61-76`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

The block that moves a shared group-account credential cache to a private
random one compares against `UGROUP_ID=51937 #mu2eshift` in its first test
and against the literal `/tmp/krb5cc_55438` in its second, then names the
new cache with 51937 in both. The same `.bashrc` is installed into every
group account by `install-login.sh`.

## Evidence

```
$ grep -n 'UGROUP_ID=\|krb5cc_' login/bashrc
62:UGROUP_ID=51937 #mu2eshift
65:if [[ "x$kinitCache" == "xTicket cache: FILE:/tmp/krb5cc_${UGROUP_ID}" ]]; then
68:    export KRB5CCNAME=/tmp/krb5cc_${UGROUP_ID}_${randomSequence}
71:if [[ "x$kinitCache" == "xklist: No credentials cache found (filename: /tmp/krb5cc_55438)" ]]; then
74:    export KRB5CCNAME=/tmp/krb5cc_${UGROUP_ID}_${randomSequence}
```

mu2edaq-operations' `ops_setup_ots.sh:589` derives the id with `id`
instead.

## Why it matters

On every account other than uid 51937 (and, for the second test, 55438) the
protection against sharing Kerberos tickets between people on the same group
account does nothing.

## Suggested fix

`UGROUP_ID=$(id -u)` and use it in both tests.

## Related

- ST-004

<!-- mega-review-fingerprint: 70780e8d -->

---

## ST-010

**Title:** `[ci] 373 tests and no CI job runs them`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** enhancement
**Location:** `.github/workflows/`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

The four workflows are `git-whitespace.yml` and `mu2e-format-single-pkg.yml`
(reusable Mu2e workflows: whitespace; clang-format and black on changed
files) and `track_new_issues.yml`/`track_new_prs.yml` (add items to org
project 6). None runs pytest or CTest. The suite is 373 offline cases and
passes (`373 passed in 8.36s`, Python 3.12, 2026-10-06).

## Evidence

```
$ ls .github/workflows
git-whitespace.yml  mu2e-format-single-pkg.yml  track_new_issues.yml  track_new_prs.yml
$ grep -l pytest .github/workflows/*; echo rc=$?
rc=1
$ python -m pytest -q | tail -1
373 passed in 8.36s
```

## Why it matters

The suite includes the documentation-drift and shell-precedence checks the
package's own docs rely on; nothing enforces them on a PR. ST-001's bug is
the kind of regression a CI run of a `restart` test would catch.

## Suggested fix

Add a workflow job on Ubuntu with Python 3.9 running `./bootstrap.sh --dev
--no-gui && venv/bin/python -m pytest` (and optionally `ctest`), with mandoc
installed so the man-lint tests are not skipped.

## Related

- mu2edaq-operations review (same gap)

<!-- mega-review-fingerprint: 5ddef9a7 -->

---

## ST-011

**Title:** `[config] tunnels.example.yaml gives gateway01 and gateway02 the same offset; only one binds`

**Severity:** S3 — correctness or maintainability risk, no current outage
**Category:** bug
**Location:** `config/tunnels.example.yaml:28-36`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

`config/tunnels.yaml` is a tracked symlink to this example, so the shipped
configuration has `gateway01` and `gateway02` at `port: 3203`. With
`ExitOnForwardFailure=yes` the second ssh dies. The README and CLAUDE.md
list it as a known gap and `daq-open-tunnels` warns, but it has never been
tracked as an issue.

## Evidence

```
$ grep -n -A3 'label: gateway0' config/tunnels.example.yaml
28:  - label: gateway01
29-    hostname: mu2egateway01.fnal.gov
30-    username: mu2edaq
31-    port: 3203
33:  - label: gateway02
34-    hostname: mu2egateway02.fnal.gov
35-    username: mu2edaq
36-    port: 3203
$ ls -l config/tunnels.yaml
config/tunnels.yaml -> tunnels.example.yaml
```

## Why it matters

Out of the box only two of the three tunnels work; which gateway loses
depends on file order. Not S2 because it is warned about and documented.

## Suggested fix

Give `gateway02` its own offset (e.g. 3205) once the intended remote service
is confirmed.

## Related

- ST-008

<!-- mega-review-fingerprint: 9de83188 -->

---

## ST-012

**Title:** `[run-control] send-run-control-command.sh is a stub that refuses with exit 3`

**Severity:** S4 — cosmetic, stale, hygiene
**Category:** enhancement
**Location:** `scripts/send-run-control-command.sh:114-124`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

The command resolves `host:port`, prints them, and refuses: two lines on
stderr and exit 3 on every real call. No socket is opened on any path. This
is a clear refusal, not silent success; it is filed so the unimplemented
feature is tracked. Two details: the informational lines go to stdout and
the refusal to stderr, and the port it suggests for the GUI (10010 for
tracker with the shipped config) is not the `OTS_MAIN_PORT` (3065) the
`setup_ots.sh` copies assign.

## Evidence

```
$ scripts/send-run-control-command.sh -c config/daq-operations.yaml -z partition_0 -e tracker start; echo rc=$?
Target: localhost:10010  (partition_0/tracker)
Command: start
send-run-control-command.sh: sending run-control commands is not implemented yet
send-run-control-command.sh: use the otsdaq web GUI on localhost:10010 instead
rc=3
$ scripts/send-run-control-command.sh -c config/daq-operations.yaml -e tracker -n start; echo rc=$?
...
Dry run: no datagram sent (payload format not implemented).
rc=0
```

## Why it matters

Low: anyone scripting against it gets a non-zero status. The gateway-port
derivation it relies on (`ots_port_offset + port_offset`) has not been
checked against otsdaq and may be wrong.

## Suggested fix

Transcribe the GatewaySupervisor UDP format (see the file's implementation
notes) and verify the port derivation against a live ots before
implementing; until then print the target on stderr too.

## Related

- ST-008

<!-- mega-review-fingerprint: 70e5af3e -->

---

## ST-013

**Title:** `[diagnostics] daq-network-verify.sh prints no host lines in its report`

**Severity:** S4 — cosmetic, stale, hygiene
**Category:** bug
**Location:** `scripts/daq-network-verify.sh:152`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

The per-network report pipes the matching ARP lines through
`tee -a "$filtered" | grep -q .`. `grep -q` consumes the output, so the
terminal shows only the section headers; the host lines appear only in
`filtered_arp_table.txt`.

## Evidence

```
$ sed -n '152p' scripts/daq-network-verify.sh
    if grep -F "$prefix" "$arp_table" | sort | tee -a "$filtered" | grep -q .; then
# same pipeline on a two-host synthetic table: stdout is empty, the file has both lines
```

## Why it matters

The diagnostic's on-screen answer to "which hosts answered" is blank. The
file is correct, so this is S4.

## Suggested fix

`grep -F "$prefix" "$arp_table" | sort | tee -a "$filtered"` and test
`[ -s ]` on the per-network output for the "(no hosts answered)" line.

## Related

—

<!-- mega-review-fingerprint: 9fa3cc94 -->

---

## ST-014

**Title:** `[hygiene] stale aliases, a personal identity function, unchecked install status, man5 not installed`

**Severity:** S4 — cosmetic, stale, hygiene
**Category:** bug
**Location:** `login/aliases:13-14`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What

Rollup of four low-severity items:

1. `login/aliases:13-14` define `sshx` and `nodes` as
   `ssh-selector -c ~/config/mu2e_daq.yaml`. `ssh-selector` comes from
   mu2edaq-cluster-tools, whose `install.sh` installs into
   `~/.local/share/mu2edaq-cluster-tools`; nothing installs
   `~/config/mu2e_daq.yaml`.
2. `login/bashrc:83-92` ships a personal `ejc()` function that aliases `git`
   to a named individual's identity, into every group account.
3. `install-login.sh:168` exits 0 even if an `install` or `cp` failed, and
   each run leaves `~/bin/<cmd>.bak.<ts>` copies with mode 755 on the `PATH`.
4. `CMakeLists.txt:188-196` installs only `man/man1` and `man/man3`; the
   review added `man/man5/{daq-operations,tunnels,current_release}.yaml.5`,
   which the install does not pick up. Also `scripts/manage-vnc-servers.sh`
   returns the ssh status, which is 0 even when a port reports `FAILED`.

## Evidence

```
$ grep -n ssh-selector login/aliases
13:alias sshx='ssh-selector -c ~/config/mu2e_daq.yaml'
14:alias nodes='ssh-selector -c ~/config/mu2e_daq.yaml'
$ grep -n 'ejc\|user.email' login/bashrc
83:ejc(){
87:    alias git='git -c user.name="edcallaghan" -c user.email="ejc3@lbl.gov"'
$ grep -n 'GLOB MU2EDAQ_MAN' CMakeLists.txt
188:file(GLOB MU2EDAQ_MAN1 "${CMAKE_CURRENT_SOURCE_DIR}/man/man1/*.1")
189:file(GLOB MU2EDAQ_MAN3 "${CMAKE_CURRENT_SOURCE_DIR}/man/man3/*.3")
```

## Why it matters

None of these breaks DAQ operation; each is a small trap for the next
operator.

## Suggested fix

Point the aliases at the cluster-tools config location (or drop them);
move `ejc()` out of the shared dotfiles; check `install` status and put
backups outside `~/bin`; add a `man5` GLOB/install rule; make
`manage-vnc-servers.sh` exit non-zero when any port failed.

## Related

- ST-004, ST-009

<!-- mega-review-fingerprint: 9a7bee14 -->

---

## Addendum for mu2edaq-resource-manager RM-008 (fingerprint 50f56b4c)

RM-008 is staged in `mu2edaq-resource-manager/docs/ISSUES-PENDING.md` for
filing against this repository. Do not open a second issue. When it is filed,
add this as a comment:

> Confirmed from the shifter-tools side (mega-review 2026-10-06).
> `resource_manager_port` is read only by `Operations.resource_manager_port()`
> (`src/mu2edaq_shifter_tools/config.py:432-434`) and printed by
> `daq-read-config resource-manager-port`
> (`src/mu2edaq_shifter_tools/read_config.py:186-187`). No script in
> `scripts/`, `start-daq.sh` or `stop-daq.sh` calls that verb, and no code
> opens a socket to it; the value also appears in `tests/conftest.py:86`
> and `tests/test_read_config.py:79`. The unrelated
> `MU2EDAQ_TUNNEL_BASE_PORT=1973` in `.env.example:47` is a commented
> example for `daq-open-tunnels`, not a resource-manager setting. On the
> review branch the README's "ResourceManager does not exist" bullet and
> the ARCHITECTURE note were corrected to point at
> `Mu2e/mu2edaq-resource-manager` (commit `927783e`, `bc60608`); the config
> default itself was not changed (code/config edits are out of scope).
