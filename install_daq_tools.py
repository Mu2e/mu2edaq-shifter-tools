#!/usr/bin/env python3

import argparse
import yaml
import os
import sys

# Version number padding
version_pad = 2

# Default filename to use for release information
default_release_file = "current_release.yaml"

# Version schema
version_schema = {"prefix": "d", "major": 0, "minor": 0, "patch": 0, "suffix": ""}


def build_version_string(version_info):
    theString = ""
    for key in version_schema.keys():
        if key == "prefix":
            theString = version_info[key]
        if key == "major":
            theString = theString + str(version_info[key]).rjust(version_pad, "0")
        if key == "minor":
            theString = theString + "_" + str(version_info[key]).rjust(version_pad, "0")
        if key == "patch":
            theString = theString + "_" + str(version_info[key]).rjust(version_pad, "0")
        if key == "suffix":
            if version_info[key] != "":
                theString = theString + "_" + str(version_info[key])
                pass
    return theString


def parse_yaml(file_path):
    try:
        with open(file_path, "r") as file:
            data = yaml.safe_load(file)
        return data
    except FileNotFoundError:
        print(f"Error: File '{file_path}' not found.")
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error parsing YAML file: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Parse YAML file and extract DAQ tool paths."
    )
    parser.add_argument("-v", "--version", action="version", version="%(prog)s 1.0")
    parser.add_argument(
        "-O",
        "--override",
        action="store_true",
        help="Override fatal errors and continue.",
    )
    parser.add_argument(
        "-M",
        "--makedirs",
        action="store_true",
        help="Create missing install directories.",
    )
    parser.add_argument(
        "-f",
        "--yaml_file",
        type=str,
        default=default_release_file,
        help="Path to the YAML configuration file.",
    )
    args = parser.parse_args()

    if args.yaml_file:
        config = parse_yaml(args.yaml_file)
    else:
        config = parse_yaml(default_release_file)

    base_release = config.get("base_release")
    test_release = config.get("test_release")
    install_paths = config.get("install_path", {})

    # Require that the YAML have all the required fields
    if not base_release or not test_release or not install_paths:
        print("Error: Missing required fields in the YAML file.")
        sys.exit(1)

    # print("Install Paths:")
    # for key, path in install_paths.items():
    #    print(f"  {key}: {path}")

    # Build the version strings
    base_release_str = build_version_string(base_release)
    test_release_str = build_version_string(test_release)

    # Print the release information that is found
    print(f"-------------------")
    print(f"Detected Base Release/Test Release information")
    print(f"-------------------")
    print(f"Base Release: {base_release_str}")
    print(f"Path: {base_release['path']}")
    print()
    print(f"Test Release: {test_release_str}")
    print(f"Path: {test_release['path']}")
    print(f"-------------------")

    # Test for the paths of each of these
    if not os.path.exists(base_release["path"]):
        print(f"Warning: Base release path does not exist: {base_release['path']}")
    if not os.path.exists(test_release["path"]):
        print(f"Warning: Test release path does not exist: {test_release['path']}")
    if not os.path.exists(base_release["path"]) or not os.path.exists(
        test_release["path"]
    ):
        print(f"Fatal Error: One or more release paths do not exist.")
        # Bail if one of the paths do not exist
        if not args.override:
            sys.exit(1)

    # Now check for the install path
    if not install_paths:
        print(f"Fatal Error: No install paths found.")
        if not args.override:
            sys.exit(1)

    thePath = ""
    theBasePath = ""
    for key, path in install_paths.items():
        if key == "basepath":
            print(f"Base Install Path: {path}")
            thePath = path
        else:
            thePath = install_paths["basepath"] + "/" + path
        if not os.path.exists(thePath):
            print(f"Warning: Install path does not exist: {thePath}")
            if args.makedirs:
                os.makedirs(thePath)
                print(f"Created missing install directory: {thePath}")


if __name__ == "__main__":
    main()
