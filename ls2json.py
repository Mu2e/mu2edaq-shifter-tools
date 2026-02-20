#!/usr/bin/env python3
import os
import json
import argparse


def ls_to_json(directory, output_file):
    """
    List files in a directory and save the details to a JSON file.

    Args:
        directory: Path to the directory to list files from
        output_file: Path to the output JSON file
    """

    # Create the empty lists
    dir_list = []  # Empty list to hold directory info
    file_list = []  # Empty list to hold file info

    print(f"Listing files in directories: {directory}")

    try:
        for thedir in directory:
            file_list = []  # Reset file list for each directory
            for filename in os.listdir(thedir):
                filepath = os.path.join(thedir, filename)
                if os.path.isfile(filepath):
                    file_info = {
                        "name": filename,
                        "size": os.path.getsize(filepath),
                        "modified_time": os.path.getmtime(filepath),
                    }
                file_list.append(file_info)
            dir_item = {"directory": thedir, "files": file_list}
            dir_list.append(dir_item)
    except Exception as e:
        print(f"Error: {e}")

    # print(f"Listing files in directory: {dir_list}")

    # Dump the list to a JSON file
    with open(output_file, "a") as json_file:
        json.dump(dir_list, json_file, indent=4)
        # Print the output file name
        print(f"File list saved to \033[91m{output_file}\033[0m")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="List files in a directory and save to JSON."
    )
    parser.add_argument(
        "-l",
        "--dirlist",
        nargs="+",
        help="List of directories to list files and save to JSON",
    )
    parser.add_argument(
        "-d", "--directory", default=".", help="Directory to list files from"
    )
    parser.add_argument(
        "-o", "--output_file", default="ls-output.json", help="Output JSON file path"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable verbose output"
    )
    args = parser.parse_args()

    output_file = args.output_file
    open(output_file, "w").close()  # Clear the output file

    if args.dirlist:
        thedirlist = args.dirlist
    else:
        thedirlist = [args.directory]

    # Generate all the json from the directory list that was given and write
    # it out to a file
    ls_to_json(thedirlist, output_file=output_file)

    if args.verbose:
        ## Example code for reading the resulting json file
        # Read and display the JSON file
        with open(output_file, "r") as json_file:
            data = json.load(json_file)  # Load JSON data

            # Traverse and print the data
            for directory in data:
                print(f"Directory: {directory['directory']}")
                for file in directory["files"]:
                    print(
                        f"File: {file['name']}, Size: {file['size']} bytes, Modified Time: {file['modified_time']}"
                    )
