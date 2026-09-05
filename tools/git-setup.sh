#!/usr/bin/env bash
# Put HotspotPro under version control.
#
# WSL1 cannot chmod on the Windows drive, so `git init` inside
# /mnt/c/... fails outright ("chmod on .git/config.lock failed"). The repository
# database therefore lives in the Linux filesystem and points at the Windows
# working tree, which needs no changes to /etc/wsl.conf and no Git for Windows.
#
# Day to day, use git.sh (generated next to this script) instead of bare `git`.
set -e

export GIT_DIR="$HOME/hotspotpro.git"
export GIT_WORK_TREE=/mnt/c/Users/DangKhoa/HotspotPro

rm -rf "$GIT_WORK_TREE/.git"          # a half-created repo from a failed attempt

if [ ! -d "$GIT_DIR" ]; then
    git init -q
    git config core.fileMode false    # DrvFs reports everything as 777
    git config user.name  "DangKhoa"
    git config user.email "dangkhoa116@gmail.com"
    echo "created $GIT_DIR"
fi

git add -A
if git diff --cached --quiet; then
    echo "nothing to commit"
else
    git commit -q -m "${1:-HotspotPro: work in progress}"
fi

git log --oneline
echo "--- tracked files: $(git ls-files | wc -l) ---"
git ls-files
