"""Tests for the configuration module: precedence, search path, accessors."""

from __future__ import annotations

from pathlib import Path

import pytest

from mu2edaq_shifter_tools import config as cfg


# --------------------------------------------------------------------------
# resolve(): the project-wide precedence
# --------------------------------------------------------------------------


def test_resolve_command_line_beats_everything():
    value = cfg.resolve(
        cli="from-cli",
        env_var="MU2EDAQ_PARTITION",
        dotenv={"MU2EDAQ_PARTITION": "from-dotenv"},
        config={"defaults": {"partition": "from-config"}},
        config_key="defaults.partition",
        default="from-default",
        environ={"MU2EDAQ_PARTITION": "from-env"},
    )
    assert value == "from-cli"


def test_resolve_environment_beats_dotenv_and_config():
    value = cfg.resolve(
        cli=None,
        env_var="MU2EDAQ_PARTITION",
        dotenv={"MU2EDAQ_PARTITION": "from-dotenv"},
        config={"defaults": {"partition": "from-config"}},
        config_key="defaults.partition",
        default="from-default",
        environ={"MU2EDAQ_PARTITION": "from-env"},
    )
    assert value == "from-env"


def test_resolve_dotenv_beats_config():
    value = cfg.resolve(
        cli=None,
        env_var="MU2EDAQ_PARTITION",
        dotenv={"MU2EDAQ_PARTITION": "from-dotenv"},
        config={"defaults": {"partition": "from-config"}},
        config_key="defaults.partition",
        default="from-default",
        environ={},
    )
    assert value == "from-dotenv"


def test_resolve_config_beats_default():
    value = cfg.resolve(
        cli=None,
        env_var="MU2EDAQ_PARTITION",
        dotenv={},
        config={"defaults": {"partition": "from-config"}},
        config_key="defaults.partition",
        default="from-default",
        environ={},
    )
    assert value == "from-config"


def test_resolve_falls_back_to_default():
    assert (
        cfg.resolve(env_var="MU2EDAQ_PARTITION", default="partition_0", environ={})
        == "partition_0"
    )


def test_resolve_ignores_empty_environment_value():
    # An exported-but-empty variable must not mask the lower tiers.
    value = cfg.resolve(
        env_var="MU2EDAQ_PARTITION",
        dotenv={"MU2EDAQ_PARTITION": "from-dotenv"},
        default="from-default",
        environ={"MU2EDAQ_PARTITION": ""},
    )
    assert value == "from-dotenv"


def test_resolve_keeps_falsey_command_line_values():
    # 0 is a legitimate port offset and must survive.
    assert cfg.resolve(cli=0, default=99, environ={}) == 0


# --------------------------------------------------------------------------
# .env parsing
# --------------------------------------------------------------------------


def test_load_dotenv_parses_exports_comments_and_quotes(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n".join(
            [
                "# a comment",
                "",
                "MU2EDAQ_PARTITION=partition_7",
                'export MU2EDAQ_CONFIG="/etc/ops.yaml"',
                "MU2EDAQ_NETWORKS='10.0.0.0/24'",
                "not a setting",
                "9BAD=x",
                "MU2EDAQ_TUNNEL_BASE_PORT=1973",
            ]
        )
    )
    monkeypatch.setenv("MU2EDAQ_DOTENV", str(env_file))
    values = cfg.load_dotenv()

    assert values["MU2EDAQ_PARTITION"] == "partition_7"
    assert values["MU2EDAQ_CONFIG"] == "/etc/ops.yaml"
    assert values["MU2EDAQ_NETWORKS"] == "10.0.0.0/24"
    assert values["MU2EDAQ_TUNNEL_BASE_PORT"] == "1973"
    assert "9BAD" not in values
    assert "not a setting" not in values


def test_load_dotenv_does_not_touch_os_environ(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("MU2EDAQ_PARTITION=partition_9\n")
    monkeypatch.setenv("MU2EDAQ_DOTENV", str(env_file))

    cfg.load_dotenv()

    import os

    assert os.environ.get("MU2EDAQ_PARTITION") is None


def test_load_dotenv_returns_empty_when_absent(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_DOTENV", str(tmp_path / "nope.env"))
    assert cfg.load_dotenv() == {}


# --------------------------------------------------------------------------
# Search path and file discovery
# --------------------------------------------------------------------------


def test_config_search_path_honours_override_and_dedupes(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(tmp_path / "first"))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("MU2EDAQ_ROOT", str(tmp_path))

    path = cfg.config_search_path()

    assert path[0] == tmp_path / "first"
    # cwd/config and root/config are the same directory here and must
    # appear only once.
    assert [str(p) for p in path].count(str(tmp_path / "config")) == 1


def test_find_config_file_uses_explicit_path(operations_config):
    found = cfg.find_config_file("daq-operations.yaml", str(operations_config))
    assert found == operations_config


def test_find_config_file_expands_tilde(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    target = home / "ops.yaml"
    target.write_text("partitions: {}\n")
    monkeypatch.setenv("HOME", str(home))

    found = cfg.find_config_file("daq-operations.yaml", "~/ops.yaml")
    assert found == target


def test_find_config_file_rejects_missing_explicit_path(tmp_path):
    with pytest.raises(cfg.ConfigError, match="config file not found"):
        cfg.find_config_file("daq-operations.yaml", str(tmp_path / "nope.yaml"))


def test_find_config_file_searches_the_path(operations_config, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(operations_config.parent))
    found = cfg.find_config_file("daq-operations.yaml")
    assert found == operations_config


def test_find_config_file_reports_the_search_path(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_ROOT", str(tmp_path))
    monkeypatch.chdir(tmp_path)
    with pytest.raises(cfg.ConfigError, match="config search path"):
        cfg.find_config_file("does-not-exist.yaml")


def test_repo_root_prefers_the_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_ROOT", str(tmp_path))
    assert cfg.repo_root() == tmp_path


def test_repo_root_finds_the_marker_in_the_checkout(repo_root):
    assert cfg.repo_root() == repo_root


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------


def test_load_config_reads_yaml(operations_config):
    data = cfg.load_config(operations_config)
    assert "partitions" in data


def test_load_config_rejects_a_non_mapping(tmp_path):
    path = tmp_path / "bad.yaml"
    path.write_text("- just\n- a\n- list\n")
    with pytest.raises(cfg.ConfigError, match="expected a mapping"):
        cfg.load_config(path)


def test_load_config_reports_a_parse_error(tmp_path):
    path = tmp_path / "bad.yaml"
    path.write_text("partitions: [unclosed\n")
    with pytest.raises(cfg.ConfigError, match="cannot parse"):
        cfg.load_config(path)


def test_load_config_treats_an_empty_file_as_empty(tmp_path):
    path = tmp_path / "empty.yaml"
    path.write_text("")
    assert cfg.load_config(path) == {}


# --------------------------------------------------------------------------
# Operations accessors
# --------------------------------------------------------------------------


@pytest.fixture
def ops(operations_config) -> cfg.Operations:
    return cfg.Operations(cfg.load_config(operations_config), operations_config)


def test_partitions(ops):
    assert ops.partitions() == ["partition_0", "partition_1"]


def test_environments(ops):
    assert ops.environments("partition_0") == ["tracker", "trigger", "calorimeter"]


def test_active_environments(ops):
    assert ops.active_environments("partition_0") == ["tracker", "trigger"]


def test_active_environments_defaults_to_all(ops):
    # partition_1 lists no active_environments, so every environment is
    # considered active.
    assert ops.active_environments("partition_1") == ["crv"]


def test_base_release(ops):
    assert ops.base_release("partition_0") == "/mu2e/releases/v9_00_00"


def test_test_rel_path_and_setup_cmd(ops):
    assert ops.test_rel_path("partition_0", "tracker") == "/releases/tracker"
    assert ops.setup_cmd("partition_0", "tracker").endswith("setup_ots.sh tracker")


def test_gateway_port_is_partition_plus_environment_offset(ops):
    assert ops.ots_port_offset("partition_0") == 10000
    assert ops.port_offset("partition_0", "trigger") == 20
    assert ops.gateway_port("partition_0", "trigger") == 10020


def test_gateway_port_defaults_to_zero_offsets(ops):
    # partition_1 sets neither offset.
    assert ops.gateway_port("partition_1", "crv") == 0


def test_resource_manager_port(ops):
    assert ops.resource_manager_port() == 1973


def test_unknown_partition_lists_the_known_ones(ops):
    with pytest.raises(cfg.ConfigError, match="known: partition_0, partition_1"):
        ops.partition("partition_99")


def test_unknown_environment_lists_the_known_ones(ops):
    with pytest.raises(cfg.ConfigError, match="known: tracker, trigger, calorimeter"):
        ops.environment("partition_0", "solenoid")


def test_missing_base_release_is_an_error(tmp_path):
    ops = cfg.Operations({"partitions": {"p": {"environments": {}}}})
    with pytest.raises(cfg.ConfigError, match="no base_release"):
        ops.base_release("p")


# --------------------------------------------------------------------------
# Tunnels
# --------------------------------------------------------------------------


def test_load_tunnels_accepts_a_mapping_with_a_tunnels_key(tmp_path, monkeypatch):
    path = tmp_path / "tunnels.yaml"
    path.write_text(
        "tunnels:\n"
        "  - hostname: a.fnal.gov\n"
        "    port: 100\n"
        "    username: mu2edaq\n"
    )
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(tmp_path))
    tunnels = cfg.load_tunnels()
    assert tunnels == [
        {"hostname": "a.fnal.gov", "port": 100, "username": "mu2edaq"}
    ]


def test_load_tunnels_accepts_a_bare_json_list(tmp_path, monkeypatch):
    # The historical file was JSON, which is valid YAML.
    path = tmp_path / "tunnels.yaml"
    path.write_text('[{"hostname": "a.fnal.gov", "port": 100}]')
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(tmp_path))
    assert cfg.load_tunnels()[0]["hostname"] == "a.fnal.gov"


def test_load_tunnels_requires_hostname_and_port(tmp_path, monkeypatch):
    path = tmp_path / "tunnels.yaml"
    path.write_text("tunnels:\n  - username: mu2edaq\n")
    monkeypatch.setenv("MU2EDAQ_CONFIG_DIR", str(tmp_path))
    with pytest.raises(cfg.ConfigError, match="missing hostname, port"):
        cfg.load_tunnels()


def test_shipped_tunnels_example_is_valid(repo_root, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_ROOT", str(repo_root))
    tunnels = cfg.load_tunnels(str(repo_root / "config" / "tunnels.example.yaml"))
    assert tunnels
    assert all("hostname" in t and "port" in t for t in tunnels)


# --------------------------------------------------------------------------
# Static data
# --------------------------------------------------------------------------


def test_data_file_finds_the_node_inventory(repo_root, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_ROOT", str(repo_root))
    assert cfg.data_file("daq_nodes.json").is_file()


def test_data_file_rejects_a_missing_file(tmp_path, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_DATA_DIR", str(tmp_path))
    with pytest.raises(cfg.ConfigError, match="data file not found"):
        cfg.data_file("nope.json")
