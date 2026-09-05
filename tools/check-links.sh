#!/usr/bin/env bash
# Verify the SpringBoard dylib does not drag Preferences.framework in with it.
#
# Anything named in a load command is loaded by dyld the moment the dylib loads.
# When one dylib served both processes, that meant SpringBoard loaded
# Preferences.framework during its own launch -- before any %ctor, before any
# @try/@catch -- so a fault there was a phone that would not boot rather than a
# Settings pane that misbehaved. The two-dylib split exists to prevent that, and
# this is what proves the split is still in force.
#
#   ./check-links.sh            # checks the release build
#   ./check-links.sh dev        # checks the development build
set -u

case "${1:-release}" in
    dev) ROOT="$HOME/HotspotPro" ;;
    *)   ROOT="$HOME/HotspotPro-release" ;;
esac

FAIL=0
FOUND=0

for d in "$ROOT"/.theos/obj/*/*.dylib; do
    [ -f "$d" ] || continue
    FOUND=1
    arch="$(basename "$(dirname "$d")")"
    name="$(basename "$d")"
    echo "=== $name ($arch) ==="
    strings -a "$d" | grep -E '\.(framework|dylib)/' | sort -u | sed 's/^/  /'

    if [ "$name" = "HotspotPro.dylib" ]; then
        if strings -a "$d" | grep -q 'Preferences.framework'; then
            echo "  FAIL: the SpringBoard dylib links Preferences.framework"
            FAIL=1
        else
            echo "  ok: no Preferences.framework in the SpringBoard dylib"
        fi
    fi
    echo
done

if [ "$FOUND" = 0 ]; then
    echo "no dylibs under $ROOT/.theos/obj — build first"
    exit 1
fi

[ "$FAIL" = 0 ] && echo "link check passed" || echo "link check FAILED"
exit $FAIL
