#!/bin/env python3

import yaml
import click
import pathlib

def load_config(input_file):
    with open(input_file) as stream:
        try:
            config = yaml.safe_load(stream)
            return config
        except yaml.YAMLError as exception:
            print(exception)

@click.command()
@click.option('--input_file', '-f', help="Config file to read", type=click.Path(exists=True), default="~/daq-shifter-tools/daq-operations.yaml")
@click.option('--partition', '-z', help="Partition to load", default="partition_0")
@click.option("--environment", "-e", help="Environment to load", default=None, type=str)
@click.argument("command_verb", type=click.Choice(["directory", "setup"], case_sensitive=False))
def read_config(input_file, partition, environment, command_verb):
    config = load_config(input_file)
    if partition not in config['partitions']:
        sys.stderr.write(f"ERROR: Partition {partition} not found!")
        sys.exit(1)
    partition_config = config['partitions'][partition]

    if environment != None and environment not in partition_config['environments']:
        sys.stderr.write(f"ERROR: Environment {environment} not found in partition {partition}!")
        sys.exit(2)
    environment_config = {}
    if environment != None:
        environment_config = partition_config['environments'][environment]

    if command_verb == "directory":
        print(environment_config['test_rel_path'])
    elif command_verb == "setup":
        print(environment_config['setup_cmd'])
        

if __name__ == '__main__':
   read_config()
