<#
.SYNOPSIS
    Set up the Python virtual environment for the Python utilities in
    mu2edaq-shifter-tools (cluster_cp.py, open_tunnels.py, ls2json.py,
    install_daq_tools.py, common/read_config.py) and install their
    dependencies. PowerShell port of bootstrap.sh for Windows.

.DESCRIPTION
    The shell utilities (Kerberos, VNC and noVNC helpers under scripts/) wrap
    Unix-only tools (klist/kinit, vncserver, systemctl over ssh) and are not
    ported; they run under bash on the DAQ nodes. See WINDOWS-COMPATIBILITY-
    REPORT.md and Mu2e/mu2edaq-main#11.

.PARAMETER Dev
    Also install pytest.
#>
[CmdletBinding()]
param(
    [switch]$Dev
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Venv = Join-Path $Here 'venv'

# Prefer 'python'; fall back to the py launcher ('python3' on Windows is the
# Microsoft Store alias stub, so it is not used here).
$Python = $env:PYTHON
if (-not $Python) {
    if (Get-Command python -ErrorAction SilentlyContinue) { $Python = 'python' }
    elseif (Get-Command py -ErrorAction SilentlyContinue) { $Python = 'py' }
    else { Write-Error 'Python 3.9+ not found on PATH. Install it first.'; exit 1 }
}

$pyver = & $Python -c 'import sys; print("%d.%d" % sys.version_info[:2])'
& $Python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
if ($LASTEXITCODE -ne 0) { Write-Error "Python >= 3.9 required, found $pyver"; exit 1 }
Write-Host "Using Python $pyver ($Python)"

if (-not (Test-Path $Venv)) {
    Write-Host "Creating virtual environment in $Venv"
    & $Python -m venv $Venv
}

$VenvPy = Join-Path $Venv 'Scripts\python.exe'
& $VenvPy -m pip install --upgrade pip | Out-Null

Write-Host 'Installing dependencies from requirements.txt'
& $VenvPy -m pip install -r (Join-Path $Here 'requirements.txt')

if ($Dev) {
    Write-Host 'Installing dev tools (pytest)'
    & $VenvPy -m pip install pytest
}

Write-Host ''
Write-Host 'Bootstrap complete. Activate with:  venv\Scripts\Activate.ps1'
