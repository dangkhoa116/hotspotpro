#!/usr/bin/env bash
# Confirm the shipped binaries really carry both architectures. A tweak that
# links cleanly but ships only arm64 fails silently on every A12+ device, so
# this is checked rather than assumed.
set -e
REL=/mnt/c/Users/DangKhoa/HotspotPro/release
TMP=$(mktemp -d)

for deb in "$REL"/*.deb; do
    echo "=== $(basename "$deb") ==="
    rm -rf "$TMP"/x && mkdir -p "$TMP"/x
    dpkg-deb -x "$deb" "$TMP"/x
    find "$TMP"/x -type f \( -name '*.dylib' -o -path '*/usr/bin/*' -o -path '*/libexec/*' \) |
    while read -r f; do
        printf '  %-24s ' "$(basename "$f")"
        file -b "$f" | sed 's/Mach-O universal binary with 2 architectures/FAT(2)/'
    done
    echo
done
rm -rf "$TMP"
