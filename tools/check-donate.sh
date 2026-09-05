#!/usr/bin/env bash
# Confirm the configured tip-jar link actually made it into the built dylib,
# rather than trusting that the generated header reached the compiler.
#
# The row lives in the Settings half, so HotspotProSettings.dylib is the one
# that must carry the URL -- HotspotPro.dylib (SpringBoard) never shows it.
SRC=/mnt/c/Users/DangKhoa/HotspotPro
URL="$(cat "$SRC/donate-url.txt" 2>/dev/null)"

if [ -z "$URL" ]; then
    echo "no donate-url.txt — the tip row is meant to be hidden"
    exit 0
fi

echo "expecting: $URL"
FAIL=1
for dylib in "$HOME"/HotspotPro-release/.theos/obj/*/HotspotProSettings.dylib; do
    [ -f "$dylib" ] || continue
    arch="$(basename "$(dirname "$dylib")")"
    if grep -aqF "$URL" "$dylib"; then
        echo "  $arch: present"
        FAIL=0
    else
        echo "  $arch: MISSING — the row would open nothing"
    fi
done

[ "$FAIL" = 0 ] || echo "tip jar URL not found in any Settings dylib"
exit $FAIL
