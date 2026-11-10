#!/bin/bash
set -euo pipefail

key_dir=/config/ssh/host_keys
mkdir -p "$key_dir" /etc/ssh
chown root:root "$key_dir"
chmod 0700 "$key_dir"

# Restore saved identities before generating any missing algorithm keys.
for algorithm in ed25519 ecdsa rsa; do
    name="ssh_host_${algorithm}_key"
    saved="$key_dir/$name"
    if [ -e "$saved" ]; then
        chown root:root "$saved"
        chmod 0600 "$saved"
        # Reject corrupt or encrypted saved keys rather than silently rotating them.
        ssh-keygen -y -P '' -f "$saved" > /dev/null
        cp "$saved" "/etc/ssh/$name"
        chmod 0600 "/etc/ssh/$name"
    fi
done

ssh-keygen -A

# Adopt existing keys on first migration, or save freshly generated keys.
for algorithm in ed25519 ecdsa rsa; do
    name="ssh_host_${algorithm}_key"
    active="/etc/ssh/$name"
    saved="$key_dir/$name"
    ssh-keygen -y -P '' -f "$active" > /dev/null
    if [ ! -e "$saved" ]; then
        cp "$active" "$saved.new"
        chown root:root "$saved.new"
        chmod 0600 "$saved.new"
        mv "$saved.new" "$saved"
    fi
    # Derive public files from the private key so they cannot become mismatched.
    ssh-keygen -y -P '' -f "$saved" > "$saved.pub.new"
    chown root:root "$saved.pub.new"
    chmod 0644 "$saved.pub.new"
    mv "$saved.pub.new" "$saved.pub"
    cp "$saved.pub" "$active.pub"
    chown root:root "$active" "$active.pub"
    chmod 0600 "$active"
    chmod 0644 "$active.pub"
done
