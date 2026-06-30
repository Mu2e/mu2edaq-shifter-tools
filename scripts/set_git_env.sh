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

# Set the ssh keys to use for github access. The private key is keyed
# off the user portion of KRB5_PRINCIPAL: ~/.ssh/id_<user>_rsa
privkey_path="$HOME/.ssh/id_${KRB5_PRINCIPAL%%@*}_rsa"
export GIT_SSH_COMMAND="ssh -i $privkey_path"
echo "Setting Git SSH Command:"
echo $GIT_SSH_COMMAND
echo "--> Ensure that $privkey_path exists and is accessible <---"

# Add the private key to the ssh-agent, but only when stdin is a
# terminal so the user can actually be prompted for the passphrase
# (during a non-interactive login there is nowhere to type it), and
# only when an ssh-agent is available to add the key to.
if [ -t 0 ] && [ -n "$SSH_AUTH_SOCK" ]; then
    # Skip if this key's fingerprint is already loaded in the agent,
    # so we don't prompt for the passphrase a second time.
    key_fp=$(ssh-keygen -lf "$privkey_path" 2>/dev/null | awk '{print $2}')
    if [ -n "$key_fp" ] && ssh-add -l 2>/dev/null | grep -q -- "$key_fp"; then
        echo "Key already loaded in ssh-agent, skipping ssh-add."
    else
        ssh-add "$privkey_path"
    fi
fi
