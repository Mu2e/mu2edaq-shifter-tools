#!/bin/env python3

import yaml
import click
import pathlib
from pprint import pprint

def load_config(input_file):
    with open(input_file) as stream:
        try:
            config = yaml.safe_load(stream)
            return config
        except yaml.YAMLError as exception:
            print(exception)

@click.command()
@click.option('--config', '-c', help="Config file to read", type=click.Path(exists=True), default="~/daq-shifter-tools/daq-operations.yaml")
@click.option('--partition', '-z', help="Partition to load", default="partition_0")
@click.option("--environment", "-e", help="Environment to load", default=None, type=str)
@click.argument("command_verb", type=str, default="print")
def read_config(config, partition, environment, command_verb):
    config_obj = load_config(config)
    if partition not in config_obj['partitions']:
        sys.stderr.write(f"ERROR: Partition {partition} not found!")
        sys.exit(1)
    partition_config = config_obj['partitions'][partition]

    if environment != None and environment not in partition_config['environments']:
        sys.stderr.write(f"ERROR: Environment {environment} not found in partition {partition}!")
        sys.exit(2)
    environment_config = {}
    if environment != None:
        environment_config = partition_config['environments'][environment]

    if command_verb.lower() == "directory":
        print(environment_config['test_rel_path'])
    elif command_verb.lower() == "setup":
        print(environment_config['setup_cmd'])
    elif command_verb.lower() == "print":
        pprint(config_obj)
    elif command_verb.lower() == "active-envs":
        output_str=""
        for env in partition_config['active_environments']:
            output_str += env + " "
        print(output_str)
    elif command_verb.lower() == "partitions":
        output_str=""
        for partition in config_obj['partitions']:
            output_str += partition + " "
        print(output_str)
    elif command_verb.lower() == "base-release":
        print(partition_config['base_release'])
    else:
        sys.stderr.write(f"ERROR: Unrecognized command {command_verb}!")
        sys.exit(3)

if __name__ == '__main__':
   read_config()
