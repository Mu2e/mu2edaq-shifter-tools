#!/usr/bin/env bash
#
# Setup the Git environment

# First set the user email use the KRB5_PRINCIPAL variable
git config --global user.email "$KRB5_PRINCIPAL"

# Next set the user name, use the first part of the KRB5_PRINCIPAL variable
git config --global user.name "${KRB5_PRINCIPAL%%@*}"

# List the configured Git user information
echo "Configured Git User Information:"
git config --global --list | grep user

# Set the ssh keys to use for github access
privkey_path="~/.ssh/id_${KRB5_PRINCIPAL%%@*}_rsa"
export GIT_SSH_COMMAND="ssh -i $privkey_path"
echo "Setting Git SSH Command:"
echo $GIT_SSH_COMMAND
