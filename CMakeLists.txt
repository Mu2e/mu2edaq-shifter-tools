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
    # Unit tests for the Python package.
    add_test(NAME pytest
             COMMAND "${Python3_EXECUTABLE}" -m pytest
                     "${CMAKE_CURRENT_SOURCE_DIR}/tests"
             WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
    set_tests_properties(pytest PROPERTIES
        ENVIRONMENT "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}/src")

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
message(STATUS "  share dir      : ${CMAKE_INSTALL_PREFIX}/${MU2EDAQ_SHAREDIR}")
message(STATUS "")
