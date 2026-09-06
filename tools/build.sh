#!/usr/bin/env bash
# Build in a temporary native filesystem directory, keeping source names flat.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
export THEOS="${THEOS:-$HOME/theos}"
if [ "$(uname -s)" = Linux ]; then
    export PATH="$THEOS/toolchain/linux/host/bin:$PATH"
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hotspotpro-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}"
cp "$SRC"/src/*.m "$SRC"/src/*.h "$SRC"/src/*.x "$WORK/"
cp "$SRC/Makefile" "$SRC/control" "$SRC"/*.plist "$WORK/"
cp -R "$SRC/layout" "$WORK/"
chmod 755 "$WORK/layout/DEBIAN/postinst" "$WORK/layout/DEBIAN/prerm"
if [ -s "$SRC/donate-url.txt" ]; then
    python3 - "$SRC/donate-url.txt" "$WORK/DonateURL.h" <<'PY'
import json, pathlib, sys
url = pathlib.Path(sys.argv[1]).read_text().strip()
pathlib.Path(sys.argv[2]).write_text('#define HP_DONATE_URL ' + json.dumps(url) + '\n')
PY
fi
if [ "${HP_ROOTFUL:-0}" = 1 ]; then
    python3 - "$WORK/control" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('Architecture: iphoneos-arm64', 'Architecture: iphoneos-arm'))
PY
fi
# Serial make also avoids hangs in the older make shipped with Xcode.
make -C "$WORK" all FINALPACKAGE=1 "$@" -j1
python3 "$SRC/tools/check-arm64e.py" "$WORK"/.theos/obj/HotspotPro*.dylib \
    "$WORK/.theos/obj/hotspotpro" "$WORK/.theos/obj/hotspotprod"
make -C "$WORK" package FINALPACKAGE=1 "$@" -j1
mkdir -p "$SRC/packages"
cp "$WORK"/packages/*.deb "$SRC/packages/"
