# daq-shifter-tools
Scripts and utilities for operating the Mu2e DAQ system

## Scripts/Utilities
* `setup_online [-z partition=0] <env>` Set up the test release for the given environment in the given parition
* `start_daq [-z partition=0]` Spawn screen/tmux/xterms for the configured sub-environments with a script which starts `ots` in each one. Prints/opens gateway context URL
  * tmux hints: https://stackoverflow.com/questions/8537149/how-to-start-tmux-with-several-windows-in-different-directories
* Configuration: JSON? YAML? defining environments, with the active base release, set of test releases, and setup instructions for each one
```JSON
"partitions": [
"partition_0": {
  "environments": {
    "tracker": {
       "test_rel_path": "/home/mu2edaq/tracker/test_rel_v9_00_00"
       "setup_cmd": "/home/mu2edaq/tracker/test_rel_v9_00_00/setup_ots.sh tracker",
       "port_offset": 10
    },
    "trigger": {
       "test_rel_path": "/home/mu2edaq/test_rel_v9_00_00"
       "setup_cmd": "/home/mu2edaq/test_rel_v9_00_00/setup_ots.sh trigger",
       "port_offset": 20
    },
    "calorimeter": {
       "test_rel_path": "/home/mu2edaq/test_rel_v9_00_00"
       "setup_cmd": "/home/mu2edaq/test_rel_v9_00_00/setup_ots.sh calorimeter",
       "port_offset": 30
    },
  },
  "base_release": "/mu2e/releases/v9_00_00",
  "active_environments": [ "tracker", "trigger" ],
  "ots_port_offset": 10000
}
],
"resource_manager_port": 1973
```
* `kill_daq [-z parition=0] [--all]` Kills the ots instances associated with the given partition, or possibly kills all running ots environments
* `daq_status` List all running paritions, their environments, and optionally query 1-line OTS status from each\
* `send_run_control_command [-z partition] [env] <cmd>` Sends a UDP state transition message to the targeted OTS instance
* `create_environment [-z partition] [env]` Read the configuration and call `mu2e-quick-spack-start.sh` as appropriate to make the environment test release 
* SSH Tunnel utilities

## Resource Management

Do we need resource management? What about ports? How do we make sure that two instances of the DAQ are not trying to use the same DTC? How do we automatically offset ports for ots/artdaq.
* ResourceManager reads a static configuration of availble resources (e.g. DTCs), and manages whether they have been claimed by an active partition (could be Node.js, need claim/release/status/transaction_{start,end})
* Must implement ResourceSupervisor that taks to the ResourceManager to reserve fungible resources (e.g. DTCs).
* If any failure occurs in a transaction, respond with failure message until the transaction ends. This should put the ots state machines in the "failed" state
* 
## Desktop Icons

* Start DAQ
* Start DAQ (No Firefox)
* Resource Manager Status Page
* DCS Status Page
* Grafana Monitoring

## VNC Utilities

* `scripts/start-novnc-connection.sh [-H host] [-u user] [-p local_port] [-r remote_port] [-P password_file] [-n]`
  Opens an SSH tunnel to the noVNC manager host and opens a generated,
  card-based dashboard of the available VNC sessions in the browser
  (instead of the plain session-list page). If `~/.novnc_password` (or
  the file given via `-P`) exists, session links are built to
  auto-connect using that password. See `man/start-novnc-connection.sh.1`.
* `scripts/manage-vnc-servers.sh {start|stop|restart} [-H host] [-u user] [-P ports] [-y] [-n]`
  Starts, stops, or restarts the `vncserver@` systemd units (display
  ports 4-9 by default) on the noVNC manager host over ssh. Prompts
  for confirmation unless `-y` is given, since this can disconnect
  active sessions. See `man/manage-vnc-servers.sh.1`.

## Man Pages

Man pages for the scripts above live under `man/` and can be viewed
directly without installing them, e.g.:
```sh
man ./man/start-novnc-connection.sh.1
man ./man/manage-vnc-servers.sh.1
```

## Other things

* Kerberos Keytabs (Pat should have utilities for AL9)
