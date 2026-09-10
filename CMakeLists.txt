# CMakeLists.txt -- mu2edaq-shifter-tools
#
# This project ships no compiled code: it is a set of bash and Python
# operator utilities. CMake is used here for packaging and installation
# (and to drive the test suite through CTest), which gives the toolkit
# the same build/install interface as the rest of the Mu2e software.
#
#   cmake -S . -B build -DCMAKE_INSTALL_PREFIX=$HOME/daq-tools
#   cmake --build build --target venv     # create venv/ and install deps
#   ctest --test-dir build --output-on-failure
#   cmake --install build
#
# Layout produced by "cmake --install":
#
#   <prefix>/bin                       shell commands and the Python entry points
#   <prefix>/share/man/man1            command man pages
#   <prefix>/share/man/man3            API man pages
#   <prefix>/share/mu2edaq/config      config examples and defaults
#   <prefix>/share/mu2edaq/data        static data (node inventory, principals)
#   <prefix>/share/mu2edaq/login       login dotfiles (installed by install-login.sh)
#   <prefix>/share/doc/mu2edaq         markdown documentation
#
# Set MU2EDAQ_ROOT=<prefix>/share/mu2edaq at runtime so the installed
# commands find their config and data.

cmake_minimum_required(VERSION 3.16)

project(mu2edaq-shifter-tools
        VERSION 1.1.0
        DESCRIPTION "Operator utilities for running the Mu2e DAQ system"
        LANGUAGES NONE)

# GNUInstallDirs cannot derive CMAKE_INSTALL_LIBDIR with LANGUAGES NONE,
# because no target architecture is known. Nothing here installs a
# library, so set it explicitly rather than take the developer warning.
if(NOT DEFINED CMAKE_INSTALL_LIBDIR)
    set(CMAKE_INSTALL_LIBDIR "lib")
endif()

include(GNUInstallDirs)
include(CTest)

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------

option(MU2EDAQ_INSTALL_SHELL_TOOLS
       "Install the bash operator scripts (POSIX shells only)" ON)
option(MU2EDAQ_INSTALL_PYTHON
       "Install the Python package into the install prefix with pip" ON)
option(MU2EDAQ_WITH_GUI
       "Include the PyQt5 extra, needed for 'daq-open-tunnels --gui'" ON)

set(MU2EDAQ_SHAREDIR "${CMAKE_INSTALL_DATADIR}/mu2edaq"
    CACHE STRING "Directory under the prefix for config, data and login files")

# The bash scripts need a POSIX shell, tmux and ssh. On Windows only the
# Python entry points are usable, so they are skipped by default there.
if(WIN32 AND MU2EDAQ_INSTALL_SHELL_TOOLS)
    message(STATUS
        "Windows detected: the bash operator scripts require a POSIX shell "
        "(WSL, Git Bash or MSYS2). Configure with "
        "-DMU2EDAQ_INSTALL_SHELL_TOOLS=OFF to install only the Python tools.")
endif()

# --------------------------------------------------------------------------
# Python interpreter
# --------------------------------------------------------------------------

find_package(Python3 3.9 COMPONENTS Interpreter)
if(NOT Python3_FOUND)
    message(WARNING
        "Python >= 3.9 was not found. The Python utilities "
        "(daq-read-config and friends) will not be installed, and the "
        "shell scripts that call them will not work.")
endif()

# --------------------------------------------------------------------------
# venv target: bootstrap the development/runtime virtual environment
# --------------------------------------------------------------------------

if(NOT WIN32)
    add_custom_target(venv
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/bootstrap.sh" --dev
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Creating venv/ and installing dependencies via bootstrap.sh"
        USES_TERMINAL)
else()
    add_custom_target(venv
        COMMAND "${CMAKE_COMMAND}" -E env
                "${Python3_EXECUTABLE}" -m venv "${CMAKE_CURRENT_SOURCE_DIR}/venv"
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/venv/Scripts/python.exe"
                -m pip install -r "${CMAKE_CURRENT_SOURCE_DIR}/requirements.txt"
        COMMENT "Creating venv/ and installing dependencies"
        USES_TERMINAL)
endif()

# --------------------------------------------------------------------------
# Shell operator commands
# --------------------------------------------------------------------------

# Commands living at the top level (the start/stop pair).
set(MU2EDAQ_TOPLEVEL_SCRIPTS
    start-daq.sh
    stop-daq.sh
    install-login.sh
    bootstrap.sh)

# Commands and libraries under scripts/.
set(MU2EDAQ_SCRIPTS
    scripts/daq-common.sh
    scripts/setup-online.sh
    scripts/create-environment.sh
    scripts/daq-status.sh
    scripts/send-run-control-command.sh
    scripts/daq-tunnels.sh
    scripts/daq-network-verify.sh
    scripts/start-tmux.sh
    scripts/manage-vnc-servers.sh
    scripts/start-novnc-connection.sh
    scripts/get_krb_principal.sh
    scripts/get_krb_daq_principal.sh
    scripts/set_git_env.sh)

if(MU2EDAQ_INSTALL_SHELL_TOOLS)
    install(PROGRAMS ${MU2EDAQ_TOPLEVEL_SCRIPTS} ${MU2EDAQ_SCRIPTS}
            DESTINATION "${CMAKE_INSTALL_BINDIR}"
            COMPONENT shell)
endif()

# --------------------------------------------------------------------------
# Python package
# --------------------------------------------------------------------------

if(MU2EDAQ_INSTALL_PYTHON AND Python3_FOUND)
    if(MU2EDAQ_WITH_GUI)
        set(_mu2edaq_pip_target "${CMAKE_CURRENT_SOURCE_DIR}[gui]")
    else()
        set(_mu2edaq_pip_target "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()

    # pip is invoked at install time so it lands under CMAKE_INSTALL_PREFIX
    # (honouring DESTDIR) rather than in the build tree.
    install(CODE "
        message(STATUS \"Installing the Python package with pip\")
        execute_process(
            COMMAND \"${Python3_EXECUTABLE}\" -m pip install
                    --prefix \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\"
                    \"${_mu2edaq_pip_target}\"
            RESULT_VARIABLE _pip_result)
        if(NOT _pip_result EQUAL 0)
            message(WARNING
                \"pip install failed (status \${_pip_result}). The shell \"
                \"scripts fall back to running the package straight out of \"
                \"src/, so set MU2EDAQ_ROOT and PYTHONPATH by hand if you \"
                \"need the Python tools.\")
        endif()
    " COMPONENT python)
endif()

# --------------------------------------------------------------------------
# Environment script
# --------------------------------------------------------------------------

# "pip install --prefix" puts the package in
# <prefix>/lib/pythonX.Y/site-packages, which is not on a system
# interpreter's sys.path. The generated env script exports the PYTHONPATH
# that makes the installed console scripts importable, alongside PATH,
# MANPATH and MU2EDAQ_ROOT.
if(Python3_FOUND)
    configure_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/mu2edaq-env.sh.in"
        "${CMAKE_CURRENT_BINARY_DIR}/mu2edaq-env.sh"
        @ONLY)
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/mu2edaq-env.sh"
            DESTINATION "${MU2EDAQ_SHAREDIR}"
            COMPONENT config)
endif()

# --------------------------------------------------------------------------
# Man pages
# --------------------------------------------------------------------------

file(GLOB MU2EDAQ_MAN1 "${CMAKE_CURRENT_SOURCE_DIR}/man/man1/*.1")
file(GLOB MU2EDAQ_MAN3 "${CMAKE_CURRENT_SOURCE_DIR}/man/man3/*.3")

install(FILES ${MU2EDAQ_MAN1}
        DESTINATION "${CMAKE_INSTALL_MANDIR}/man1"
        COMPONENT man)
install(FILES ${MU2EDAQ_MAN3}
        DESTINATION "${CMAKE_INSTALL_MANDIR}/man3"
        COMPONENT man)

# --------------------------------------------------------------------------
# Config, data, login files and documentation
# --------------------------------------------------------------------------

# Only the .example files are installed: the live daq-operations.yaml is
# deployment-specific and must not be overwritten by an upgrade.
install(DIRECTORY config/
        DESTINATION "${MU2EDAQ_SHAREDIR}/config"
        COMPONENT config
        FILES_MATCHING PATTERN "*.example*")

install(DIRECTORY data/
        DESTINATION "${MU2EDAQ_SHAREDIR}/data"
        COMPONENT data
        FILES_MATCHING PATTERN "*.json")

install(DIRECTORY login/
        DESTINATION "${MU2EDAQ_SHAREDIR}/login"
        COMPONENT login
        PATTERN ".*" EXCLUDE)

install(DIRECTORY docs/
        DESTINATION "${CMAKE_INSTALL_DOCDIR}"
        COMPONENT doc
        FILES_MATCHING PATTERN "*.md")

install(FILES README.md LICENSE
        DESTINATION "${CMAKE_INSTALL_DOCDIR}"
        COMPONENT doc)

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

if(BUILD_TESTING AND Python3_FOUND)
    # Prefer the project venv, which is where bootstrap.sh puts pytest and
    # the dependencies. A system interpreter found by find_package rarely
    # has either.
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/venv/bin/python")
        set(MU2EDAQ_TEST_PYTHON "${CMAKE_CURRENT_SOURCE_DIR}/venv/bin/python")
    else()
        set(MU2EDAQ_TEST_PYTHON "${Python3_EXECUTABLE}")
    endif()

    # Only register the suite if it can actually run, so a checkout that
    # has not been bootstrapped reports "not built" rather than a failure
    # that looks like a broken test.
    execute_process(
        COMMAND "${MU2EDAQ_TEST_PYTHON}" -c "import pytest, yaml, click"
        RESULT_VARIABLE MU2EDAQ_TEST_DEPS
        OUTPUT_QUIET ERROR_QUIET)

    if(MU2EDAQ_TEST_DEPS EQUAL 0)
        add_test(NAME pytest
                 COMMAND "${MU2EDAQ_TEST_PYTHON}" -m pytest
                         "${CMAKE_CURRENT_SOURCE_DIR}/tests"
                 WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
        set_tests_properties(pytest PROPERTIES
            ENVIRONMENT "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}/src")
    else()
        message(STATUS
            "pytest/PyYAML/click not importable with ${MU2EDAQ_TEST_PYTHON}; "
            "the Python test suite is not registered. Run "
            "'cmake --build <dir> --target venv' (or ./bootstrap.sh --dev) "
            "and re-configure.")
    endif()

    # Syntax-check every shell script; catches the kind of quoting bug
    # that only shows up in the control room otherwise.
    find_program(MU2EDAQ_BASH bash)
    if(MU2EDAQ_BASH)
        foreach(_script ${MU2EDAQ_TOPLEVEL_SCRIPTS} ${MU2EDAQ_SCRIPTS})
            get_filename_component(_name "${_script}" NAME)
            add_test(NAME "shellsyntax_${_name}"
                     COMMAND "${MU2EDAQ_BASH}" -n
                             "${CMAKE_CURRENT_SOURCE_DIR}/${_script}")
        endforeach()
    endif()
endif()

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

message(STATUS "")
message(STATUS "mu2edaq-shifter-tools ${PROJECT_VERSION}")
message(STATUS "  install prefix : ${CMAKE_INSTALL_PREFIX}")
message(STATUS "  shell tools    : ${MU2EDAQ_INSTALL_SHELL_TOOLS}")
message(STATUS "  python package : ${MU2EDAQ_INSTALL_PYTHON}")
message(STATUS "  Qt GUI extra   : ${MU2EDAQ_WITH_GUI}")
if(DEFINED MU2EDAQ_TEST_PYTHON)
    message(STATUS "  test python    : ${MU2EDAQ_TEST_PYTHON}")
endif()
message(STATUS "  share dir      : ${CMAKE_INSTALL_PREFIX}/${MU2EDAQ_SHAREDIR}")
message(STATUS "")
message(STATUS "  After 'cmake --install', set up the environment with:")
message(STATUS "    source ${CMAKE_INSTALL_PREFIX}/${MU2EDAQ_SHAREDIR}/mu2edaq-env.sh")
message(STATUS "")
