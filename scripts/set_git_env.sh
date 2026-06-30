#!/usr/bin/env bash
#
# Setup the Git environment

# Print "<label>: " followed by Pass (green) or Fail (red) for the
# given exit status. Set VERBOSE=1 to also print the underlying detail.
_status() {
    if [ "$1" -eq 0 ]; then
        printf '%s: \033[32mPass\033[0m\n' "$2"
    else
        printf '%s: \033[31mFail\033[0m\n' "$2"
    fi
}

# Configure the Git user identity from KRB5_PRINCIPAL (email = full
# principal, name = the user portion before the @).
git config --global user.email "$KRB5_PRINCIPAL" \
    && git config --global user.name "${KRB5_PRINCIPAL%%@*}"
_status $? "Configuring Git User Information"
[ -n "$VERBOSE" ] && git config --global --list | grep user

# Configure the Git SSH command to use the per-user key
# ~/.ssh/id_<user>_rsa; report Fail if that key is missing.
privkey_path="$HOME/.ssh/id_${KRB5_PRINCIPAL%%@*}_rsa"
export GIT_SSH_COMMAND="ssh -i $privkey_path"
[ -f "$privkey_path" ]
_status $? "Configuring Git SSH Command"
if [ -n "$VERBOSE" ]; then
    echo "  GIT_SSH_COMMAND=$GIT_SSH_COMMAND"
    [ -f "$privkey_path" ] || echo "  --> $privkey_path not found <--"
fi

# Add the private key to the ssh-agent, but only when stdin is a
# terminal so the user can actually be prompted for the passphrase
# (during a non-interactive login there is nowhere to type it), and
# only when an ssh-agent is available to add the key to.
if [ -t 0 ] && [ -n "$SSH_AUTH_SOCK" ]; then
    # Skip if this key's fingerprint is already loaded in the agent,
    # so we don't prompt for the passphrase a second time.
    key_fp=$(ssh-keygen -lf "$privkey_path" 2>/dev/null | awk '{print $2}')
    if [ -n "$key_fp" ] && ssh-add -l 2>/dev/null | grep -q -- "$key_fp"; then
        [ -n "$VERBOSE" ] && echo "Key already loaded in ssh-agent, skipping ssh-add."
    elif [ -n "$VERBOSE" ]; then
        ssh-add "$privkey_path"
    else
        ssh-add -q "$privkey_path"
    fi
fi

unset -f _status
