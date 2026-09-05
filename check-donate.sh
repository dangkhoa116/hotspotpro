#!/usr/bin/env bash
# Confirm the configured tip-jar link actually made it into the built dylib,
# rather than trusting that the generated header reached the compiler.
SRC=/mnt/c/Users/DangKhoa/HotspotPro
URL="$(cat "$SRC/donate-url.txt" 2>/dev/null)"

if [ -z "$URL" ]; then
    echo "no donate-url.txt — the tip row is meant to be hidden"
    exit 0
fi

echo "expecting: $URL"
for dylib in "$HOME"/HotspotPro-release/.theos/obj/*/HotspotPro.dylib; do
    [ -f "$dylib" ] || continue
    arch="$(basename "$(dirname "$dylib")")"
    if grep -aqF "$URL" "$dylib"; then
        echo "  $arch: present"
    else
        echo "  $arch: MISSING — the row would open nothing"
    fi
done
