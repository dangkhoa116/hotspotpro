#!/usr/bin/env bash
# git for this project. The repo database lives in the Linux filesystem because
# WSL1 cannot chmod on /mnt/c; this wrapper points git at it.
#
#   wsl -d Ubuntu -u builder -- bash /mnt/c/Users/DangKhoa/HotspotPro/git.sh status
#   wsl -d Ubuntu -u builder -- bash /mnt/c/Users/DangKhoa/HotspotPro/git.sh commit -am "fix"
export GIT_DIR="$HOME/hotspotpro.git"
export GIT_WORK_TREE=/mnt/c/Users/DangKhoa/HotspotPro
exec git "$@"
