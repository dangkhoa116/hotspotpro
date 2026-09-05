#!/usr/bin/env bash
# Which frameworks does the tweak dylib pull in eagerly?
#
# This matters because the same dylib is injected into SpringBoard AND
# Preferences. Anything named in a load command is loaded by dyld the moment the
# dylib loads -- so linking Preferences.framework means SpringBoard loads
# Preferences.framework during its own launch, which it otherwise never does.
set -e

for d in "$HOME"/HotspotPro-release/.theos/obj/*/HotspotPro.dylib; do
    [ -f "$d" ] || continue
    echo "=== $(basename "$(dirname "$d")") ==="
    strings -a "$d" | grep -E '\.(framework|dylib)/' | sort -u | sed 's/^/  /'
    echo
done
