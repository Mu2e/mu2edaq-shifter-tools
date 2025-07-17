# daq-shifter-tools
Scripts and utilities for operating the Mu2e DAQ system

Notes:
* `setup_online <env>` Set up the test release for the given environment, or if no option is provided set up the "main" or gateway instance
* `start_daq` Check if we are in the "main" instance, and if so, spawn screen/tmux/xterms for a configurable set of sub-environments with a script which starts `ots` in each one
* Configuration: JSON? defining environments, with the active base release, set of test releases, and setup instructions for each one
```JSON
  "environments": {
    "tracker": {
       "test_rel_path": "/home/mu2edaq/tracker/test_rel_v9_00_00"
       "setup_cmd": "/home/mu2edaq/tracker/test_rel_v9_00_00/setup_ots.sh tracker"
    },
    "trigger": ...
  }
```
* `kill_daq <all>` Kills the ots instance associated with the current environment, or possibly kills all running ots environments
