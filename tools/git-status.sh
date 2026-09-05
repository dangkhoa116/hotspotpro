#!/usr/bin/env bash
export GIT_DIR="$HOME/hotspotpro.git"
export GIT_WORK_TREE=/mnt/c/Users/DangKhoa/HotspotPro

echo "=== repo ==="
echo "$GIT_DIR"
echo
echo "=== commits ==="
git log --oneline
echo
echo "=== remotes ==="
git remote -v
echo "(nothing listed above means the repo is local only)"
echo
echo "=== github cli ==="
command -v gh || echo "gh not installed"
