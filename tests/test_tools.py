"""Tests for the remaining command line tools."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from mu2edaq_shifter_tools import cluster_cp, install_daq_tools, ls2json, open_tunnels

# --------------------------------------------------------------------------
# daq-cluster-cp
# --------------------------------------------------------------------------


def test_load_nodes_reads_an_explicit_inventory(nodes_file):
    nodes = cluster_cp.load_nodes(str(nodes_file))
    assert nodes["trk"] == ["trk01"]


def test_load_nodes_rejects_a_missing_file(tmp_path):
    from mu2edaq_shifter_tools import config as cfg

    with pytest.raises(cfg.ConfigError, match="not found"):
        cluster_cp.load_nodes(str(tmp_path / "nope.json"))


def test_select_hosts_by_group(nodes_file):
    nodes = cluster_cp.load_nodes(str(nodes_file))
    assert cluster_cp.select_hosts(nodes, ["trk"], False) == ["trk01"]


def test_select_hosts_all_is_deduplicated(nodes_file):
    # daq01 appears in both the daq and calo groups.
    nodes = cluster_cp.load_nodes(str(nodes_file))
    hosts = cluster_cp.select_hosts(nodes, [], True)
    assert hosts == ["daq01", "daq02", "trk01", "crv01", "calo01"]
    assert len(hosts) == len(set(hosts))


def test_select_hosts_uses_a_stable_group_order(nodes_file):
    nodes = cluster_cp.load_nodes(str(nodes_file))
    assert cluster_cp.select_hosts(nodes, ["calo", "daq"], False) == [
        "daq01",
        "daq02",
        "calo01",
    ]


def test_cluster_cp_dry_run_reports_every_host(tmp_path, nodes_file):
    payload = tmp_path / "payload.txt"
    payload.write_text("x")
    result = CliRunner().invoke(
        cluster_cp.main,
        [
            "--dry-run",
            "--trk",
            "--user",
            "mu2edaq",
            "--nodes-file",
            str(nodes_file),
            str(payload),
            "/tmp/dest",
        ],
    )
    assert result.exit_code == 0, result.output
    assert "scp" in result.output
    assert "mu2edaq@trk01:/tmp/dest" in result.output
    assert "nothing was copied" in result.output


def test_cluster_cp_rejects_a_missing_source_file(nodes_file):
    result = CliRunner().invoke(
        cluster_cp.main,
        ["--dry-run", "--trk", "--nodes-file", str(nodes_file), "/nope", "/tmp"],
    )
    assert result.exit_code == 2
    assert "no such file" in result.output


def test_cluster_cp_user_comes_from_the_environment(tmp_path, nodes_file, monkeypatch):
    payload = tmp_path / "payload.txt"
    payload.write_text("x")
    monkeypatch.setenv("MU2EDAQ_CLUSTER_USER", "fromenv")
    result = CliRunner().invoke(
        cluster_cp.main,
        [
            "--dry-run",
            "--trk",
            "--nodes-file",
            str(nodes_file),
            str(payload),
            "/tmp/dest",
        ],
    )
    assert result.exit_code == 0, result.output
    assert "fromenv@trk01" in result.output


def test_cluster_cp_command_line_user_beats_the_environment(
    tmp_path, nodes_file, monkeypatch
):
    payload = tmp_path / "payload.txt"
    payload.write_text("x")
    monkeypatch.setenv("MU2EDAQ_CLUSTER_USER", "fromenv")
    result = CliRunner().invoke(
        cluster_cp.main,
        [
            "--dry-run",
            "--trk",
            "--user",
            "fromcli",
            "--nodes-file",
            str(nodes_file),
            str(payload),
            "/tmp/dest",
        ],
    )
    assert "fromcli@trk01" in result.output


def test_shipped_node_inventory_has_every_group(repo_root, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_ROOT", str(repo_root))
    nodes = cluster_cp.load_nodes()
    for group in cluster_cp.GROUPS:
        assert nodes[group], f"group {group} is empty"


# --------------------------------------------------------------------------
# daq-ls2json
# --------------------------------------------------------------------------


def test_listing_records_files(tmp_path):
    (tmp_path / "a.txt").write_text("hello")
    (tmp_path / "sub").mkdir()

    result = ls2json.listing([str(tmp_path)])
    assert len(result) == 1
    names = [entry["name"] for entry in result[0]["files"]]
    # Directories are excluded unless asked for.
    assert names == ["a.txt"]
    assert result[0]["files"][0]["size"] == 5


def test_listing_can_include_directories(tmp_path):
    (tmp_path / "a.txt").write_text("hello")
    (tmp_path / "sub").mkdir()

    result = ls2json.listing([str(tmp_path)], include_dirs=True)
    kinds = {entry["name"]: entry["type"] for entry in result[0]["files"]}
    assert kinds == {"a.txt": "file", "sub": "directory"}


def test_listing_does_not_duplicate_records_for_directories(tmp_path):
    # Regression: the original implementation appended the previous
    # file's record again for every directory it encountered.
    (tmp_path / "a.txt").write_text("a")
    (tmp_path / "sub1").mkdir()
    (tmp_path / "sub2").mkdir()

    files = ls2json.listing([str(tmp_path)])[0]["files"]
    assert [entry["name"] for entry in files] == ["a.txt"]


def test_listing_reports_an_unreadable_directory(tmp_path):
    result = ls2json.listing([str(tmp_path / "absent")])
    assert result[0]["error"]
    assert result[0]["files"] == []


def test_ls2json_writes_a_file(tmp_path):
    (tmp_path / "a.txt").write_text("hello")
    out = tmp_path / "out.json"
    result = CliRunner().invoke(ls2json.main, ["--output", str(out), str(tmp_path)])
    assert result.exit_code == 0, result.output
    data = json.loads(out.read_text())
    assert data[0]["directory"] == str(tmp_path)


def test_ls2json_defaults_to_stdout(tmp_path, monkeypatch):
    (tmp_path / "a.txt").write_text("hello")
    monkeypatch.chdir(tmp_path)
    result = CliRunner().invoke(ls2json.main, ["--indent", "0"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)[0]["files"][0]["name"] == "a.txt"


# --------------------------------------------------------------------------
# daq-install-tools
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "version,expected",
    [
        ({"prefix": "d", "major": 9, "minor": 0, "patch": 0}, "d09_00_00"),
        (
            {"prefix": "d", "major": 9, "minor": 1, "patch": 2, "suffix": "rc1"},
            "d09_01_02_rc1",
        ),
        ({"prefix": "v", "major": 10, "minor": 11, "patch": 12}, "v10_11_12"),
        # Empty suffix must not leave a trailing underscore.
        (
            {"prefix": "d", "major": 1, "minor": 2, "patch": 3, "suffix": ""},
            "d01_02_03",
        ),
        # Missing components fall back to the schema defaults.
        ({"major": 5}, "d05_00_00"),
    ],
)
def test_build_version_string(version, expected):
    assert install_daq_tools.build_version_string(version) == expected


def test_release_paths_joins_onto_the_basepath():
    config = {"install_path": {"basepath": "/opt/daq", "bin": "bin", "cfg": "config"}}
    paths = dict(install_daq_tools.release_paths(config))
    assert paths["basepath"] == Path("/opt/daq")
    assert paths["bin"] == Path("/opt/daq/bin")
    assert paths["cfg"] == Path("/opt/daq/config")


def test_release_paths_requires_a_basepath():
    from mu2edaq_shifter_tools import config as cfg

    with pytest.raises(cfg.ConfigError, match="basepath"):
        install_daq_tools.release_paths({"install_path": {"bin": "bin"}})


def test_install_tools_creates_missing_directories(tmp_path, monkeypatch):
    release = tmp_path / "config" / "current_release.yaml"
    release.parent.mkdir()
    base = tmp_path / "base"
    base.mkdir()
    release.write_text(f"""
base_release: {{prefix: d, major: 9, minor: 0, patch: 0, path: "{base}"}}
test_release: {{prefix: d, major: 9, minor: 0, patch: 0, path: "{base}"}}
install_path:
  basepath: "{tmp_path}/install"
  bin: "bin"
""")
    result = CliRunner().invoke(
        install_daq_tools.main,
        ["--release-file", str(release), "--makedirs"],
    )
    assert result.exit_code == 0, result.output
    assert (tmp_path / "install" / "bin").is_dir()


def test_install_tools_fails_on_a_missing_release_path(tmp_path):
    release = tmp_path / "current_release.yaml"
    release.write_text("""
base_release: {prefix: d, major: 9, minor: 0, patch: 0, path: "/nonexistent/base"}
test_release: {prefix: d, major: 9, minor: 0, patch: 0, path: "/nonexistent/test"}
install_path: {basepath: "/tmp/install"}
""")
    result = CliRunner().invoke(
        install_daq_tools.main, ["--release-file", str(release)]
    )
    assert result.exit_code == 1
    assert "does not exist" in result.output


def test_install_tools_override_continues_past_missing_paths(tmp_path):
    release = tmp_path / "current_release.yaml"
    release.write_text("""
base_release: {prefix: d, major: 9, minor: 0, patch: 0, path: "/nonexistent/base"}
test_release: {prefix: d, major: 9, minor: 0, patch: 0, path: "/nonexistent/test"}
install_path: {basepath: "/tmp/install"}
""")
    result = CliRunner().invoke(
        install_daq_tools.main, ["--release-file", str(release), "--override"]
    )
    assert result.exit_code == 0, result.output


def test_shipped_release_example_parses(repo_root):
    result = CliRunner().invoke(
        install_daq_tools.main,
        [
            "--release-file",
            str(repo_root / "config" / "current_release.example.yaml"),
            "--override",
        ],
    )
    assert result.exit_code == 0, result.output
    assert "d09_00_00" in result.output


# --------------------------------------------------------------------------
# daq-open-tunnels
# --------------------------------------------------------------------------


def test_default_base_port_is_uid_plus_973():
    import os

    assert open_tunnels.default_base_port() == os.getuid() + 973


def test_ssh_command_builds_a_local_forward():
    command = open_tunnels.ssh_command(
        {"hostname": "gw.fnal.gov", "port": 100, "username": "mu2edaq"}, 1000, None
    )
    assert command == [
        "ssh",
        "-N",
        "-o",
        "ExitOnForwardFailure=yes",
        "-L",
        "1100:localhost:1100",
        "mu2edaq@gw.fnal.gov",
    ]


def test_ssh_command_honours_jump_and_remote():
    command = open_tunnels.ssh_command(
        {
            "hostname": "gw.fnal.gov",
            "port": 5,
            "username": "mu2edaq",
            "jump": "jump.fnal.gov",
            "remote": "inner-host",
        },
        1000,
        None,
    )
    assert "-J" in command
    assert command[command.index("-J") + 1] == "jump.fnal.gov"
    assert "1005:inner-host:1005" in command


def test_ssh_command_user_override_wins():
    command = open_tunnels.ssh_command(
        {"hostname": "gw.fnal.gov", "port": 1, "username": "fromfile"},
        1000,
        "fromcli",
    )
    assert command[-1] == "fromcli@gw.fnal.gov"


def test_state_round_trip(tmp_path):
    path = tmp_path / "state"
    records = [
        {
            "pid": "1234",
            "hostname": "gw.fnal.gov",
            "username": "mu2edaq",
            "local_port": "5000",
            "label": "gateway",
        }
    ]
    open_tunnels.write_state(path, records)
    assert open_tunnels.read_state(path) == records


def test_read_state_tolerates_the_legacy_four_field_format(tmp_path):
    path = tmp_path / "state"
    path.write_text("4321, gw.fnal.gov, mu2edaq, 5000\n")
    record = open_tunnels.read_state(path)[0]
    assert record["pid"] == "4321"
    assert record["local_port"] == "5000"
    assert record["label"] == ""


def test_read_state_of_a_missing_file_is_empty(tmp_path):
    assert open_tunnels.read_state(tmp_path / "absent") == []


def test_open_tunnels_dry_run_warns_about_duplicate_ports(tmp_path, monkeypatch):
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    (config_dir / "tunnels.yaml").write_text(
        "tunnels:\n"
        "  - {label: one, hostname: a.fnal.gov, port: 10, username: u}\n"
        "  - {label: two, hostname: b.fnal.gov, port: 10, username: u}\n"
    )
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(config_dir))
    monkeypatch.setenv("MU2EDAQ_TUNNEL_STATE", str(tmp_path / "state"))

    result = CliRunner().invoke(open_tunnels.main, ["--dry-run", "open"])
    assert result.exit_code == 0, result.output
    assert "claimed by 2 tunnels" in result.output


def test_open_tunnels_list_of_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_TUNNEL_STATE", str(tmp_path / "state"))
    result = CliRunner().invoke(open_tunnels.main, ["list"])
    assert result.exit_code == 0
    assert "No tunnels recorded" in result.output


def test_open_tunnels_base_port_from_the_environment(tmp_path, monkeypatch):
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    (config_dir / "tunnels.yaml").write_text(
        "tunnels:\n  - {hostname: a.fnal.gov, port: 7, username: u}\n"
    )
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(config_dir))
    monkeypatch.setenv("MU2EDAQ_TUNNEL_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("MU2EDAQ_TUNNEL_BASE_PORT", "20000")

    result = CliRunner().invoke(open_tunnels.main, ["--dry-run", "open"])
    assert "20007:localhost:20007" in result.output
