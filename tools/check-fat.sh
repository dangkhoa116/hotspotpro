#!/usr/bin/env bash
# Confirm the shipped binaries really carry both architectures, AND that the
# arm64e slice is encoded the way iOS actually loads it.
#
# A tweak that links cleanly but ships only arm64 fails silently on every A12+
# device, so that is checked rather than assumed. This used to be the whole
# check, done with `file` -- and `file` turned out to be blind to the bug that
# actually shipped: it prints "arm64" for an arm64e slice and says nothing about
# its ABI encoding, so v0.6.6 went out with an arm64e slice that crashes
# Settings and SpringBoard on iOS 16.3.1. tools/macho-abi.py does the real
# check now; the long version of why is in its header.
#
# Runs on the WSL build box and on a macOS CI runner, so: no `mapfile`, no bash
# arrays and no GNU-only flags -- macOS ships bash 3.2.
#
#   ./check-fat.sh              # checks release/*.deb
#   ./check-fat.sh DIR|DEB...   # checks the debs given instead
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ABI="$DIR/macho-abi.py"
REL="$(cd "$DIR/.." && pwd)/release"

if [ ! -f "$ABI" ]; then
    echo "missing $ABI"
    exit 1
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t hpfat)
trap 'rm -rf "$TMP"' EXIT

# Collect the debs to check, one per line. A plain list rather than an array:
# `${#arr[@]}` on an empty array trips `set -u` in bash 3.2.
LIST="$TMP/debs"
: > "$LIST"
if [ "$#" -eq 0 ]; then
    ls -1 "$REL"/*.deb 2>/dev/null >> "$LIST"
else
    for a in "$@"; do
        if [ -d "$a" ]; then
            ls -1 "$a"/*.deb 2>/dev/null >> "$LIST"
        elif [ -f "$a" ]; then
            echo "$a" >> "$LIST"
        fi
    done
fi

if [ ! -s "$LIST" ]; then
    echo "no debs found — build first"
    exit 1
fi

FAIL=0
while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    echo "=== $(basename "$deb") ==="
    rm -rf "$TMP"/x && mkdir -p "$TMP"/x
    if ! dpkg-deb -x "$deb" "$TMP"/x; then
        echo "  FAIL: could not extract"
        FAIL=1
        continue
    fi
    # macho-abi.py walks the payload itself and skips anything that is not a
    # Mach-O, so the two tweak dylibs, the CLI and the daemon are all covered
    # without this script having to know their names.
    python3 "$ABI" "$TMP"/x || FAIL=1
    echo
done < "$LIST"

if [ "$FAIL" = 0 ]; then
    echo "fat/ABI check passed"
else
    echo "fat/ABI check FAILED — do not publish this build"
fi
exit $FAIL
