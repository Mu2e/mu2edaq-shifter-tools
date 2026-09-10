"""Shared pytest fixtures for the shifter-tools test suite."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

#: Every MU2EDAQ_* variable the tools read. Cleared for each test so a
#: developer's own .env or shell environment cannot change the results.
MU2EDAQ_VARS = (
    "MU2EDAQ_ROOT",
    "MU2EDAQ_CONFIG",
    "MU2EDAQ_CONFIG_DIR",
    "MU2EDAQ_DATA_DIR",
    "MU2EDAQ_DOTENV",
    "MU2EDAQ_PARTITION",
    "MU2EDAQ_ENVIRONMENT",
    "MU2EDAQ_TUNNELS",
    "MU2EDAQ_TUNNEL_BASE_PORT",
    "MU2EDAQ_TUNNEL_STATE",
    "MU2EDAQ_CLUSTER_USER",
    "MU2EDAQ_CLUSTER_JOBS",
)


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch, tmp_path):
    """Run every test with a neutral environment and no ambient .env."""
    for name in MU2EDAQ_VARS:
        monkeypatch.delenv(name, raising=False)
    # Point DOTENV at a file that does not exist so find_dotenv() cannot
    # pick up the repository's own .env.
    monkeypatch.setenv("MU2EDAQ_DOTENV", str(tmp_path / "absent.env"))
    return None


@pytest.fixture
def repo_root() -> Path:
    """The repository root, for tests that read the shipped examples."""
    return REPO_ROOT


@pytest.fixture
def operations_config(tmp_path) -> Path:
    """A small but complete operations config, written to a temp dir."""
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    # The root marker, so repo_root() resolves to tmp_path when
    # MU2EDAQ_ROOT points here.
    (config_dir / "daq-operations.example.yaml").write_text("partitions: {}\n")

    path = config_dir / "daq-operations.yaml"
    path.write_text(
        """
partitions:
  partition_0:
    environments:
      tracker:
        test_rel_path: "/releases/tracker"
        setup_cmd: "/releases/tracker/setup_ots.sh tracker"
        port_offset: 10
      trigger:
        test_rel_path: "/releases/trigger"
        setup_cmd: "/releases/trigger/setup_ots.sh trigger"
        port_offset: 20
      calorimeter:
        test_rel_path: "/releases/calo"
        setup_cmd: "/releases/calo/setup_ots.sh calorimeter"
        port_offset: 30
    base_release: "/mu2e/releases/v9_00_00"
    active_environments:
      - tracker
      - trigger
    ots_port_offset: 10000
  partition_1:
    environments:
      crv:
        test_rel_path: "/releases/crv"
        setup_cmd: "/releases/crv/setup_ots.sh crv"
    base_release: "/mu2e/releases/v9_01_00"

resource_manager_port: 1973
"""
    )
    return path


@pytest.fixture
def nodes_file(tmp_path) -> Path:
    """A miniature node inventory."""
    path = tmp_path / "daq_nodes.json"
    path.write_text(
        json.dumps(
            {
                "daq": ["daq01", "daq02"],
                "trk": ["trk01"],
                "crv": ["crv01"],
                "calo": ["calo01", "daq01"],
            }
        )
    )
    return path
