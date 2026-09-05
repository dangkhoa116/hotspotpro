#!/usr/bin/env bash
# Builds the HotspotPro .deb. Run as builder.
#   wsl -d Ubuntu -u builder -- bash /mnt/c/Users/DangKhoa/HotspotPro/build.sh

export THEOS="$HOME/theos"
export PATH="$THEOS/toolchain/linux/host/bin:$PATH"

# Write our own log so output survives regardless of how the caller captures it.
LOG=/mnt/c/Users/DangKhoa/HotspotPro/build.log
exec > >(tee "$LOG") 2>&1
echo "=== build started $(date) ==="

echo '=== toolchain ==='
"$THEOS/toolchain/linux/iphone/bin/clang" --version 2>/dev/null | head -1 || echo 'clang MISSING'
echo
echo '=== sdks ==='
ls "$THEOS/sdks"
echo
echo '=== building ==='
# Build in a Linux-native dir: Theos + WSL1 on a /mnt/c DrvFs path hits
# permission and symlink problems, so copy the sources across first.
SRC=/mnt/c/Users/DangKhoa/HotspotPro
WORK="$HOME/HotspotPro"
mkdir -p "$WORK"
cp -f "$SRC"/*.m "$SRC"/*.h "$SRC"/Makefile "$SRC"/control "$WORK"/ 2>/dev/null
cp -f "$SRC"/*.x "$SRC"/*.plist "$WORK"/ 2>/dev/null
if [ -s "$SRC/donate-url.txt" ]; then
    printf '#define HP_DONATE_URL "%s"\n' "$(cat "$SRC/donate-url.txt")" > "$WORK/DonateURL.h"
else
    rm -f "$WORK/DonateURL.h"
fi
# layout/ carries the LaunchDaemon plist and the DEBIAN maintainer scripts.
rm -rf "$WORK/layout"
cp -r "$SRC"/layout "$WORK"/ 2>/dev/null
chmod 755 "$WORK"/layout/DEBIAN/postinst "$WORK"/layout/DEBIAN/prerm 2>/dev/null
cd "$WORK"

# NOTE: 'make clean' hangs under WSL 1 here, so wipe the build dirs directly
# instead. Same effect, no stall.
rm -rf .theos packages

make package FINALPACKAGE=1 -j1 2>&1
RC=$?
echo
echo "make exit=$RC"
echo '=== packages ==='
ls -la "$WORK/packages" 2>/dev/null || echo '(none)'

# Copy any built deb back to the Windows side
if ls "$WORK"/packages/*.deb >/dev/null 2>&1; then
    mkdir -p "$SRC/packages"
    cp -f "$WORK"/packages/*.deb "$SRC/packages/"
    echo "copied to $SRC/packages/"
    ls -la "$SRC/packages/"
fi
exit $RC
