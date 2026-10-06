"""Mu2e DAQ shifter tools.

Operator utilities for running the Mu2e DAQ: partition/environment
lifecycle management, SSH tunnel and VNC access, cluster file
distribution, and the Kerberos/git login environment.

The Python half of the toolkit is importable as a library; every command
line entry point is a thin wrapper over it. See mu2edaq_shifter_tools(3).
"""

__version__ = "1.1.0"

__all__ = ["__version__", "config"]
