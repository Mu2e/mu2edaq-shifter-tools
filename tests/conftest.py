"""Make the repo-root modules importable without installation.

mu2edaq-shifter-tools ships loose scripts (open_tunnels.py, ls2json.py) plus a
common/ package, with no pyproject. Put the repo root on sys.path so the tests
can import them directly, and force Qt offscreen before PyQt is imported.
"""
import os
import sys
import pathlib

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
