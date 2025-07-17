# daq-shifter-tools
Scripts and utilities for operating the Mu2e DAQ system

Notes:
* `setup_online <env>` Set up the test release for the given environment, or if no option is provided set up the "main" or gateway instance
* `start_daq` Check if we are in the "main" instance, and if so, spawn screen/tmux/xterms for a configurable set of sub-environments with a script which starts `ots` in each one
* Configuration: JSON? defining environments, with the active base release, set of test releases, and setup instructions for each one
```JSON
"partitions": [
"partition_0": {
  "environments": {
    "tracker": {
       "test_rel_path": "/home/mu2edaq/tracker/test_rel_v9_00_00"
       "setup_cmd": "/home/mu2edaq/tracker/test_rel_v9_00_00/setup_ots.sh tracker",
       "port_offset": 10
    },
    "trigger": "..."
  },
  "base_release": "/mu2e/releases/v9_00_00",
  "active_environments": [ "tracker", "trigger" ],
  "ots_port_offset": 10000
}
],
"resource_manager_port": 1973
```
* `kill_daq <all>` Kills the ots instance associated with the current environment, or possibly kills all running ots environments

Do we need resource management? What about ports? How do we make sure that two instances of the DAQ are not trying to use the same DTC? How do we automatically offset ports for ots/artdaq.
* ResourceManager reads a static configuration of availble resources (e.g. DTCs), and manages whether they have been claimed by an active partition (could be Node.js, need claim/release/status/transaction_{start,end})
* Must implement ResourceSupervisor that taks to the ResourceManager to reserve fungible resources (e.g. DTCs).
* If any failure occurs in a transaction, respond with failure message until the transaction ends. This should put the ots state machines in the "failed" state

TMUX: https://stackoverflow.com/questions/8537149/how-to-start-tmux-with-several-windows-in-different-directories
