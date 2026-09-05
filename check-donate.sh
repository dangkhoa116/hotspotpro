#!/usr/bin/env bash
# Confirm the tip-jar link actually made it into the built dylib, rather than
# trusting that the Makefile's -D reached the compiler.
for dylib in "$HOME"/HotspotPro-release/.theos/obj/*/HotspotPro.dylib; do
    [ -f "$dylib" ] || continue
    echo "=== $dylib ==="
    if grep -ao 'https://www\.paypal\.com/donate[^ ]*' "$dylib" | head -1; then
        :
    else
        echo "  (no donate URL found — the row will be hidden)"
    fi
done
