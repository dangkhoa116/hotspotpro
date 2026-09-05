#!/usr/bin/env bash
# Erase a path from every commit in this repo's history, not just from the tip.
# Takes a git pathspec, so a glob works and matches at any depth:
#
#   wsl -d Ubuntu -u builder -- bash .../purge-file.sh REDDIT-POST.md
#   wsl -d Ubuntu -u builder -- bash .../purge-file.sh '*.md'
#
# Quote the glob so the calling shell hands it to git unexpanded.
#
# `git rm` only stops a file at HEAD; the blob stays reachable through the
# commit history and GitHub will happily render it. Removing it for real means
# rewriting every commit that touched it, which changes those commits' SHAs and
# therefore needs a force push.
#
# Deliberately not a routine tool. Rewriting shared history breaks every clone;
# it is safe here only because this is a solo repo with no collaborators.
#
# WARNING: filter-branch ends with `git read-tree -u -m HEAD`, so it syncs the
# working tree to the rewritten HEAD -- purging a path DELETES YOUR LOCAL COPY
# of it too. If you meant to keep the file locally, copy it out of the backup
# this script prints, using the pre-rewrite SHA it also prints:
#
#   GIT_DIR=<backup> git show <before>:<path> > <path>
set -e

TARGET="$1"
[ -n "$TARGET" ] || { echo "usage: purge-file.sh <path-in-repo>"; exit 1; }

export GIT_DIR="$HOME/hotspotpro.git"
export GIT_WORK_TREE=/mnt/c/Users/DangKhoa/HotspotPro
# filter-branch refuses to run outside a work tree even for --index-filter,
# which never touches one, so the work tree has to be real and current.
cd "$GIT_WORK_TREE"

# Its scratch area (.git-rewrite by default, in the cwd) is kept on the Linux
# filesystem instead: it is written to once per commit, and DrvFs is both slow
# and the source of this project's permission trouble.
SCRATCH="$HOME/.hp-rewrite"
rm -rf "$SCRATCH"

BACKUP="$HOME/hotspotpro.git.backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$GIT_DIR" "$BACKUP"
echo "backup: $BACKUP"

BEFORE=$(git rev-parse HEAD)
echo "before: $BEFORE"

# --ignore-unmatch so commits predating the file do not abort the rewrite.
# -- --all so tags are rewritten too, not just the branch.
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f -d "$SCRATCH" \
    --index-filter "git rm --cached --ignore-unmatch -- '$TARGET'" \
    --prune-empty --tag-name-filter cat -- --all

# filter-branch keeps the originals under refs/original/ as a safety net, and
# the reflog still points at the old commits. While either exists the old blobs
# stay reachable and gc will not drop them.
git for-each-ref --format='%(refname)' refs/original | xargs -r -n 1 git update-ref -d
git reflog expire --expire=now --all
git gc --prune=now --aggressive --quiet

echo "after:  $(git rev-parse HEAD)"
echo
if git log --all --oneline -- "$TARGET" | grep -q .; then
    echo "FAILED: $TARGET is still present in history"
    exit 1
fi
echo "$TARGET no longer appears in any commit"
