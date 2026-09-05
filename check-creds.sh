#!/usr/bin/env bash
# What git credentials, if any, exist for this repo's environment.
export GIT_DIR="$HOME/hotspotpro.git"

echo "=== credential helper configured ==="
git config --get credential.helper || echo "(none)"

echo
echo "=== stored credential files ==="
for f in "$HOME/.git-credentials" "$HOME/.config/gh/hosts.yml" "$HOME/.netrc"; do
    if [ -f "$f" ]; then echo "PRESENT: $f"; else echo "absent:  $f"; fi
done

echo
echo "=== ssh keys ==="
ls "$HOME"/.ssh/*.pub 2>/dev/null || echo "(none)"
