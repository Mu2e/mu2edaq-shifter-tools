"""Cross-platform / Windows compatibility tests.

Added in the windows-compat sweep. Locks in:
  * open_tunnels imports on Windows (the module-level os.getuid() guard),
  * common/read_config imports sys so its error paths don't NameError, and
  * bootstrap.sh has a PowerShell port (the Kerberos/VNC/ssh admin scripts are
    Unix-only by nature and intentionally not ported -- see #11).
"""
import importlib
import os
import pathlib
import shutil
import subprocess

import pytest

REPO = pathlib.Path(__file__).resolve().parent.parent
PWSH = shutil.which("pwsh") or shutil.which("powershell")


def test_open_tunnels_imports_on_any_platform():
    # Fails on Windows before the fix: os.getuid() at module scope raised
    # AttributeError, so the module could not be imported at all.
    pytest.importorskip("PyQt5", reason="PyQt5 not installed")
    mod = importlib.import_module("open_tunnels")
    assert isinstance(mod.baseport, int)
    assert mod.baseport > 973 or mod.baseport >= 973


def test_read_config_imports_sys_for_its_error_paths():
    # read_config.py uses sys.stderr/sys.exit on every error branch; without
    # `import sys` those raise NameError instead of the intended message.
    src = (REPO / "common" / "read_config.py").read_text(encoding="utf-8")
    assert "import sys" in src
    spec = importlib.util.spec_from_file_location(
        "shifter_read_config", REPO / "common" / "read_config.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert hasattr(mod, "sys")
    assert callable(mod.load_config)


def test_bootstrap_has_a_powershell_port():
    assert (REPO / "bootstrap.sh").is_file()
    assert (REPO / "bootstrap.ps1").is_file()


@pytest.mark.skipif(not PWSH, reason="PowerShell not available")
def test_bootstrap_powershell_parses():
    path = (REPO / "bootstrap.ps1").as_posix()
    code = (
        "$e=$null;"
        f"[System.Management.Automation.Language.Parser]::ParseFile('{path}',[ref]$null,[ref]$e)|Out-Null;"
        "if($e){$e|ForEach-Object{Write-Error $_};exit 1}else{exit 0}"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-Command", code],
        capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0, result.stderr


def test_unix_only_admin_scripts_are_documented_not_ported():
    # These wrap Unix-only tools (klist/kinit, vncserver, systemctl over ssh);
    # they intentionally have no PowerShell port. Assert they still exist as the
    # bash originals so a refactor doesn't silently drop them.
    for rel in ("scripts/get_krb_principal.sh",
                "scripts/manage-vnc-servers.sh",
                "scripts/start-novnc-connection.sh",
                "install_login.sh"):
        assert (REPO / rel).is_file(), f"missing Unix admin script: {rel}"
        assert not (REPO / rel).with_suffix(".ps1").exists(), (
            f"{rel} is Unix-only and should not have a PowerShell port")
