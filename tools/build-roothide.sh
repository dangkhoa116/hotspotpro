#!/usr/bin/env bash
# Build ONLY the roothide package, for CI verification that the roothide scheme
# still compiles. Kept separate from build-release.sh on purpose:
#
#   - roothide needs a DIFFERENT Theos (the roothide fork), because the stock
#     Theos has no `roothide` package scheme and no libroothide for -lroothide /
#     <roothide.h>. The caller points $THEOS at that fork.
#   - The stable release channel does NOT ship a roothide deb; this only proves
#     the build is not broken, so it is not wired into build-release.sh or the
#     release pipeline.
#
# Mirrors build-release.sh's flat-copy-then-make dance and its arm64e ABI gate.
# Run on a macOS runner: only Xcode's linker emits the versioned arm64e ABI iOS
# actually loads (see build-release.sh for the long version).

set -u
export THEOS="${THEOS:-$HOME/theos}"

if [ -d "$THEOS/toolchain/linux/host/bin" ]; then
    export PATH="$THEOS/toolchain/linux/host/bin:$PATH"
fi

SRC="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$SRC/build-roothide.log"
exec > >(tee "$LOG") 2>&1
echo "=== roothide build started $(date) ==="
echo "THEOS=$THEOS"

WORK="$HOME/HotspotPro-roothide"
rm -rf "$WORK"
mkdir -p "$WORK"
# Sources live in src/ but land FLAT in the build dir, exactly as build-release.sh
# does it — the Makefile names them bare on purpose.
cp -f "$SRC"/src/*.m "$SRC"/src/*.h "$SRC"/src/*.x "$WORK"/ 2>/dev/null
cp -f "$SRC"/Makefile "$SRC"/control "$SRC"/*.plist "$WORK"/ 2>/dev/null

# The tip jar is optional for a compile check: Settings.x uses __has_include, so
# a missing DonateURL.h just hides the row. Honour donate-url.txt if it is there.
if [ -s "$SRC/donate-url.txt" ]; then
    printf '#define HP_DONATE_URL "%s"\n' "$(cat "$SRC/donate-url.txt")" > "$WORK/DonateURL.h"
    echo "tip jar: configured"
else
    rm -f "$WORK/DonateURL.h"
    echo "tip jar: not configured, row will be hidden"
fi
cp -r "$SRC"/layout "$WORK"/
chmod 755 "$WORK"/layout/DEBIAN/postinst "$WORK"/layout/DEBIAN/prerm

OUT="$SRC/release-roothide"
mkdir -p "$OUT"
rm -f "$OUT"/*.deb

cd "$WORK"
rm -rf .theos packages

# See build-release.sh: `latest` would pick Xcode's own SDK, which has no
# PrivateFrameworks stubs and breaks the Settings link. Pin it when given.
target=""
if [ -n "${HP_TARGET:-}" ]; then
    target="TARGET=$HP_TARGET"
    echo "target: $HP_TARGET"
fi

# The Makefile forces THEOS_PACKAGE_ARCH := iphoneos-arm64e for this scheme, so
# the control Architecture field is left alone — no sed dance like the other two.
echo
echo "=== make package HP_ROOTHIDE=1 ==="
make package FINALPACKAGE=1 HP_ROOTHIDE=1 $target -j1
rc=$?
if [ $rc -ne 0 ]; then
    echo "!! roothide build FAILED (exit $rc)"
    exit $rc
fi

cp -f packages/*.deb "$OUT"/ 2>/dev/null
if ! ls "$OUT"/*.deb >/dev/null 2>&1; then
    echo "!! no roothide deb was produced"
    exit 1
fi

echo
echo "=== roothide artifact ==="
ls -la "$OUT"
for deb in "$OUT"/*.deb; do
    echo "--- $(basename "$deb") ---"
    dpkg-deb -f "$deb" Package Version Architecture Depends
    echo "payload:"
    dpkg-deb -c "$deb" | grep -E 'DynamicLibraries|libexec|usr/bin' | sed 's/^/  /'
done

# Same arm64e ABI gate as the release build: a deb that links and packages can
# still carry the wrong ptrauth encoding, so verify the slices.
echo
echo "=== fat / ABI check ==="
if ! bash "$SRC/tools/check-fat.sh" "$OUT"; then
    echo "!! the roothide deb is NOT loadable — bad arm64e ABI"
    exit 1
fi

echo
echo "=== roothide build OK ==="
