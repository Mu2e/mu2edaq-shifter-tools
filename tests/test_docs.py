"""Tests that the documentation keeps up with the code.

Every command must have a man page, every man page must belong to a
command, and every page must render through groff.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MAN1 = REPO_ROOT / "man" / "man1"
MAN3 = REPO_ROOT / "man" / "man3"

#: Shell commands, relative to the repository root, that end users run.
SHELL_COMMANDS = [
    "start-daq.sh",
    "stop-daq.sh",
    "install-login.sh",
    "bootstrap.sh",
    "scripts/setup-online.sh",
    "scripts/create-environment.sh",
    "scripts/daq-status.sh",
    "scripts/send-run-control-command.sh",
    "scripts/daq-tunnels.sh",
    "scripts/daq-network-verify.sh",
    "scripts/start-tmux.sh",
    "scripts/manage-vnc-servers.sh",
    "scripts/start-novnc-connection.sh",
    "scripts/get_krb_principal.sh",
    "scripts/get_krb_daq_principal.sh",
    "scripts/set_git_env.sh",
]

#: Shell libraries, documented in section 3 rather than section 1.
SHELL_LIBRARIES = ["scripts/daq-common.sh"]

MAN = shutil.which("man")


def console_scripts() -> list:
    """Return the console script names declared in pyproject.toml."""
    text = (REPO_ROOT / "pyproject.toml").read_text()
    block = text.split("[project.scripts]", 1)[1].split("[", 1)[0]
    return [
        line.split("=", 1)[0].strip()
        for line in block.strip().splitlines()
        if "=" in line
    ]


# --------------------------------------------------------------------------
# Coverage
# --------------------------------------------------------------------------


@pytest.mark.parametrize("command", SHELL_COMMANDS)
def test_shell_command_has_a_man_page(command):
    name = Path(command).name
    assert (MAN1 / f"{name}.1").is_file(), f"man/man1/{name}.1 is missing"


@pytest.mark.parametrize("library", SHELL_LIBRARIES)
def test_shell_library_has_an_api_man_page(library):
    name = Path(library).name
    assert (MAN3 / f"{name}.3").is_file(), f"man/man3/{name}.3 is missing"


@pytest.mark.parametrize("command", console_scripts())
def test_console_script_has_a_man_page(command):
    assert (MAN1 / f"{command}.1").is_file(), f"man/man1/{command}.1 is missing"


def test_python_package_has_api_man_pages():
    assert (MAN3 / "mu2edaq_shifter_tools.3").is_file()
    assert (MAN3 / "mu2edaq_shifter_tools_config.3").is_file()


def test_no_orphan_man_pages():
    """Every section 1 page must correspond to a real command."""
    documented = {p.stem for p in MAN1.glob("*.1")}
    expected = {Path(c).name for c in SHELL_COMMANDS} | set(console_scripts())
    assert documented == expected


# --------------------------------------------------------------------------
# Content
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "page", sorted(MAN1.glob("*.1")) + sorted(MAN3.glob("*.3")), ids=lambda p: p.name
)
def test_man_page_has_the_required_sections(page):
    text = page.read_text()
    assert text.startswith(".TH "), f"{page.name} has no .TH header"
    for section in (".SH NAME", ".SH SYNOPSIS", ".SH DESCRIPTION", ".SH SEE ALSO"):
        assert section in text, f"{page.name} is missing {section}"


@pytest.mark.parametrize(
    "page", sorted(MAN1.glob("*.1")) + sorted(MAN3.glob("*.3")), ids=lambda p: p.name
)
def test_man_page_name_line_matches_the_filename(page):
    text = page.read_text()
    name_line = text.split(".SH NAME", 1)[1].strip().splitlines()[0]
    # A Python module page is named mu2edaq_shifter_tools_config.3 but
    # documents "mu2edaq_shifter_tools.config", so compare with "." and
    # "_" treated alike.
    documented = name_line.split()[0].replace(".", "_")
    assert documented == page.stem.replace(
        ".", "_"
    ), f"{page.name}: NAME section says {name_line!r}"


@pytest.mark.parametrize(
    "page", sorted(MAN1.glob("*.1")) + sorted(MAN3.glob("*.3")), ids=lambda p: p.name
)
def test_man_page_th_section_matches_the_directory(page):
    header = page.read_text().splitlines()[0]
    section = header.split()[2].strip('"')
    assert section == page.suffix.lstrip(
        "."
    ), f"{page.name}: .TH declares section {section}"


@pytest.mark.skipif(MAN is None, reason="man is not available")
@pytest.mark.parametrize(
    "page", sorted(MAN1.glob("*.1")) + sorted(MAN3.glob("*.3")), ids=lambda p: p.name
)
def test_man_page_renders(page):
    result = subprocess.run(
        [MAN, str(page)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"MANWIDTH": "80", "PATH": "/usr/bin:/bin", "LANG": "C"},
    )
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout, f"{page.name} rendered empty"


# --------------------------------------------------------------------------
# Markdown documentation
# --------------------------------------------------------------------------


def test_required_documents_exist():
    for name in ("INSTALL.md", "BUILD.md", "CONFIGURATION.md", "ARCHITECTURE.md"):
        assert (REPO_ROOT / "docs" / name).is_file(), f"docs/{name} is missing"
    assert (REPO_ROOT / "README.md").is_file()


def test_readme_mentions_every_command():
    readme = (REPO_ROOT / "README.md").read_text()
    for command in SHELL_COMMANDS:
        name = Path(command).name
        assert name in readme, f"README.md does not mention {name}"
    for command in console_scripts():
        assert command in readme, f"README.md does not mention {command}"


def test_env_example_documents_every_variable_the_code_reads():
    """Any MU2EDAQ_* variable the code reads must appear in .env.example."""
    example = (REPO_ROOT / ".env.example").read_text()
    pattern = re.compile(r"MU2EDAQ_[A-Z0-9_]+")

    referenced = set()
    for path in list((REPO_ROOT / "scripts").glob("*.sh")) + [
        REPO_ROOT / "start-daq.sh",
        REPO_ROOT / "stop-daq.sh",
        REPO_ROOT / "install-login.sh",
    ]:
        referenced |= set(pattern.findall(path.read_text()))

    # Names built at runtime from a prefix, and the install-time-only
    # overrides, are not settings an operator puts in .env.
    ignore = {
        "MU2EDAQ_ROOT",
        "MU2EDAQ_DOTENV",
        "MU2EDAQ_INSTALL_HOME",
        "MU2EDAQ_INSTALL_BIN",
    }
    missing = sorted(v for v in referenced - ignore if v not in example)
    assert not missing, f"undocumented in .env.example: {missing}"


# --------------------------------------------------------------------------
# roff correctness
#
# groff renders a malformed page without complaint, so these failures are
# silent: the reader simply never sees the line. mandoc reports them.
# --------------------------------------------------------------------------

MANDOC = shutil.which("mandoc")


@pytest.mark.skipif(MANDOC is None, reason="mandoc is not available")
@pytest.mark.parametrize(
    "page", sorted(MAN1.glob("*.1")) + sorted(MAN3.glob("*.3")), ids=lambda p: p.name
)
def test_man_page_passes_mandoc_lint(page):
    """No ERROR- or WARNING-level roff problems."""
    result = subprocess.run(
        [MANDOC, "-T", "lint", str(page)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    problems = [
        line
        for line in result.stdout.decode().splitlines()
        if "ERROR:" in line or "WARNING:" in line
    ]
    assert not problems, "\n".join(problems)


@pytest.mark.parametrize(
    "page", sorted(MAN1.glob("*.1")) + sorted(MAN3.glob("*.3")), ids=lambda p: p.name
)
def test_example_lines_are_not_swallowed_by_roff(page):
    """A line starting with a dot or an apostrophe is a roff control line.

    Regression: example commands written as "./bootstrap.sh --dev" were
    parsed as unknown macros and dropped from the rendered page, so the
    EXAMPLES section showed the surrounding lines but not the command
    itself. groff reported nothing. The fix is a leading zero-width
    escape.
    """
    offenders = [
        (n, line)
        for n, line in enumerate(page.read_text().splitlines(), 1)
        if line.startswith("./") or line.startswith("'")
    ]
    assert not offenders, f"{page.name}: unescaped control lines {offenders}"
