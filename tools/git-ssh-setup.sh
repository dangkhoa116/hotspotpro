#!/usr/bin/env bash
# Set up SSH auth for pushing to GitHub, so no token ever has to be typed,
# pasted into a chat, or stored in a file that git reads.
#
# The private key stays in WSL and is never transmitted anywhere; only the
# public half goes to GitHub.
set -e

KEY="$HOME/.ssh/id_ed25519"
export GIT_DIR="$HOME/hotspotpro.git"
export GIT_WORK_TREE=/mnt/c/Users/DangKhoa/HotspotPro

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY" ]; then
    # No passphrase: this key exists so pushes do not prompt. The trade-off is
    # that anyone with access to this WSL account can push to the repos it is
    # authorised for, which for a public tweak repo is a fair exchange.
    ssh-keygen -t ed25519 -C "dangkhoa116@gmail.com" -f "$KEY" -N "" -q
    echo "generated a new key at $KEY"
else
    echo "reusing existing key at $KEY"
fi
chmod 600 "$KEY"

# Pre-trust github.com so the first push does not stop on a host-key prompt.
if ! grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    echo "added github.com to known_hosts"
fi

git remote set-url origin git@github.com:dangkhoa116/HotspotPro.git
echo "remote is now: $(git remote get-url origin)"

echo
echo "=============================================================="
echo " PUBLIC KEY — paste this into https://github.com/settings/keys"
echo "=============================================================="
cat "$KEY.pub"
echo "=============================================================="
