"""Tests for the daq-read-config command verbs.

The shell scripts capture this tool's stdout with command substitution,
so the exact output shape matters as much as the values.
"""

from __future__ import annotations

import json

import pytest
from click.testing import CliRunner

from mu2edaq_shifter_tools.read_config import VERBS, main


@pytest.fixture
def run(operations_config):
    """Invoke daq-read-config against the temp operations config."""
    runner = CliRunner()

    def _run(*args, expect_success=True):
        result = runner.invoke(
            main, ["--config", str(operations_config), *args]
        )
        if expect_success:
            assert result.exit_code == 0, result.output
        return result

    return _run


def test_partitions_are_space_separated_on_one_line(run):
    # The callers do "for p in $(daq-read-config partitions)".
    assert run("partitions").output == "partition_0 partition_1\n"


def test_active_envs(run):
    assert run("-z", "partition_0", "active-envs").output == "tracker trigger\n"


def test_environments_lists_all_of_them(run):
    assert (
        run("-z", "partition_0", "environments").output
        == "tracker trigger calorimeter\n"
    )


def test_directory(run):
    assert run("-z", "partition_0", "-e", "tracker", "directory").output == (
        "/releases/tracker\n"
    )


def test_setup_keeps_its_arguments(run):
    # setup_cmd carries an argument; it must come back intact.
    assert run("-z", "partition_0", "-e", "trigger", "setup").output == (
        "/releases/trigger/setup_ots.sh trigger\n"
    )


def test_base_release(run):
    assert run("-z", "partition_0", "base-release").output == (
        "/mu2e/releases/v9_00_00\n"
    )


def test_gateway_port(run):
    assert run("-z", "partition_0", "-e", "trigger", "gateway-port").output == "10020\n"


def test_port_offset(run):
    assert run("-z", "partition_0", "-e", "tracker", "port-offset").output == "10\n"


def test_ots_port_offset(run):
    assert run("-z", "partition_0", "ots-port-offset").output == "10000\n"


def test_resource_manager_port(run):
    assert run("resource-manager-port").output == "1973\n"


def test_config_file_reports_the_file_used(run, operations_config):
    assert run("config-file").output.strip() == str(operations_config)


def test_environment_defaults_to_the_first_active_one(run):
    # No -e: fall back to the partition's first active environment.
    assert run("-z", "partition_0", "directory").output == "/releases/tracker\n"


def test_default_partition_is_partition_0(run):
    assert run("active-envs").output == "tracker trigger\n"


def test_partition_comes_from_the_environment(run, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_PARTITION", "partition_1")
    assert run("active-envs").output == "crv\n"


def test_command_line_partition_beats_the_environment(run, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_PARTITION", "partition_1")
    assert run("-z", "partition_0", "active-envs").output == "tracker trigger\n"


def test_config_comes_from_the_environment(operations_config, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_CONFIG", str(operations_config))
    result = CliRunner().invoke(main, ["partitions"])
    assert result.exit_code == 0, result.output
    assert result.output == "partition_0 partition_1\n"


def test_json_output_is_parseable(run):
    result = run("-z", "partition_0", "--json", "active-envs")
    assert json.loads(result.output) == ["tracker", "trigger"]


def test_print_emits_the_whole_config_as_json(run):
    result = run("--json", "print")
    assert "partition_0" in json.loads(result.output)["partitions"]


def test_unknown_verb_is_a_usage_error(run):
    result = run("frobnicate", expect_success=False)
    assert result.exit_code != 0
    assert "unrecognized verb" in result.output


def test_unknown_partition_exits_nonzero(run):
    result = run("-z", "nope", "active-envs", expect_success=False)
    assert result.exit_code == 1
    assert "not found" in result.output


def test_unknown_environment_exits_nonzero(run):
    result = run("-z", "partition_0", "-e", "nope", "directory", expect_success=False)
    assert result.exit_code == 1
    assert "not found" in result.output


def test_missing_config_file_exits_nonzero():
    result = CliRunner().invoke(main, ["--config", "/nonexistent.yaml", "partitions"])
    assert result.exit_code == 1
    assert "not found" in result.output


def test_list_verbs_covers_every_documented_verb():
    result = CliRunner().invoke(main, ["--list-verbs"])
    assert result.exit_code == 0
    listed = {line.split("\t")[0] for line in result.output.strip().splitlines()}
    assert listed == set(VERBS)


def test_config_path_works_without_a_config_file(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_ROOT", str(tmp_path))
    monkeypatch.chdir(tmp_path)
    result = CliRunner().invoke(main, ["config-path"])
    assert result.exit_code == 0
    assert "config" in result.output
