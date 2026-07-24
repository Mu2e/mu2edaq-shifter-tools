#!/usr/bin/env python3
import os
import json
import argparse
import subprocess
import concurrent.futures

# Copy files to a location across the full DAQ cluster

# Parse command-line arguments
parser = argparse.ArgumentParser(
    description="Copy files to a location across the full DAQ cluster."
)
parser.add_argument(
    "-v", "--verbose", action="store_true", help="Enable verbose output."
)
parser.add_argument(
    "-c", "--calo", action="store_true", help="Copy files to the Calo nodes."
)
parser.add_argument(
    "-C", "--crv", action="store_true", help="Copy files to the CRV nodes."
)
parser.add_argument(
    "-t", "--trk", action="store_true", help="Copy files to the Trk nodes."
)
parser.add_argument(
    "-d", "--daq", action="store_true", help="Copy files to the DAQ nodes."
)
parser.add_argument("-a", "--all", action="store_true", help="Copy files to all nodes.")
parser.add_argument("-u", "--user", help="Username for the remote nodes.")
parser.add_argument("files", nargs="+", help="List of files to copy.")
parser.add_argument(
    "destination", nargs=1, help="Destination path on the remote nodes."
)
args = parser.parse_args()

verbose = args.verbose

# print(args.files)
# print(args.destination)

user = args.user
files = args.files
destination = args.destination

# First read in the list of nodes to copy files to
# Path to the JSON file containing the list of nodes
nodes_file_path = "/home/mu2edaq/DAQ-Test-Releases/daq-shifter-tools/"
nodes_file = "daq_nodes.json"

user = "mu2edaq"

# Read the JSON file and load the list of nodes
with open(nodes_file_path + nodes_file, "r") as f:
    nodes = json.load(f)

# Ensure the nodes are in a list format
# if not isinstance(nodes, list):
#    raise ValueError("The JSON file must contain a list of node names.")

hosts = []
if not args.calo and not args.crv and not args.trk and not args.daq:
    # print("No hosts specified")
    args.all = True

if args.calo:
    hosts += nodes["calo"]
if args.crv:
    hosts += nodes["crv"]
if args.trk:
    hosts += nodes["trk"]
if args.daq:
    hosts += nodes["daq"]
if args.all:
    hosts = nodes["daq"] + nodes["trk"] + nodes["crv"] + nodes["calo"]
if verbose:
    print(f"Using hosts list: {hosts}")


def copy_file_to_host(file, host, user, destination):
    ret = 0
    ret = os.system(f"scp {file} {user}@{host}:{destination}")
    if ret != 0:
        print(f"Error: copying {file} to {user}@{host}:{destination}")
    else:
        if verbose:
            print(f"Completed copying {file} to {user}@{host}:{destination}")
    return ret


with concurrent.futures.ThreadPoolExecutor() as executor:
    futures = []
    for f in files:
        for h in hosts:
            # copy_file_to_host(f, h, user, destination[0])
            futures.append(
                executor.submit(copy_file_to_host, f, h, user, destination[0])
            )

    # Wait for all futures to complete
    concurrent.futures.wait(futures)
    if verbose:
        print("All file copy operations submitted.")

    # for future in futures:
    # print(future)
    # if future.result() != 0:
    #    print(f"File copy operation failed.")
    # else:
    #    print(f"File copy operation succeeded.")
