#!/usr/bin/env bash
# Build the release set: one .deb per jailbreak type, each fat with both
# architectures. Run as builder.
#   wsl -d Ubuntu -u builder -- bash /mnt/c/Users/DangKhoa/HotspotPro/build-release.sh
#
# Why two packages:
#   rootless (Architecture: iphoneos-arm64) — Dopamine, palera1n rootless, Xina
#   rootful  (Architecture: iphoneos-arm)   — unc0ver, checkra1n, palera1n rootful
# and why both architectures in each: arm64 covers A7-A11, arm64e covers A12 and
# newer, whose system processes a purely arm64 dylib cannot be injected into.

export THEOS="$HOME/theos"
export PATH="$THEOS/toolchain/linux/host/bin:$PATH"

SRC=/mnt/c/Users/DangKhoa/HotspotPro
LOG="$SRC/build-release.log"
exec > >(tee "$LOG") 2>&1
echo "=== release build started $(date) ==="

WORK="$HOME/HotspotPro-release"
rm -rf "$WORK"
mkdir -p "$WORK"
cp -f "$SRC"/*.m "$SRC"/*.h "$SRC"/*.x "$SRC"/Makefile "$SRC"/control "$SRC"/*.plist "$WORK"/ 2>/dev/null

# Turn the tip-jar link into a header. Generated rather than passed as a -D:
# the URL contains '&', which make and the shell between them mangle.
if [ -s "$SRC/donate-url.txt" ]; then
    printf '#define HP_DONATE_URL "%s"\n' "$(cat "$SRC/donate-url.txt")" > "$WORK/DonateURL.h"
    echo "tip jar: $(cat "$SRC/donate-url.txt")"
else
    rm -f "$WORK/DonateURL.h"
    echo "tip jar: not configured, row will be hidden"
fi
cp -r "$SRC"/layout "$WORK"/
chmod 755 "$WORK"/layout/DEBIAN/postinst "$WORK"/layout/DEBIAN/prerm

OUT="$SRC/release"
mkdir -p "$OUT"
rm -f "$OUT"/*.deb

build_scheme() {
    local scheme="$1" label="$2"
    echo
    echo "=== building $label ==="
    cd "$WORK"
    rm -rf .theos packages          # 'make clean' hangs under WSL1

    # The Architecture field is what tells package managers which jailbreak a
    # deb is for, and Theos takes it verbatim from control rather than from the
    # scheme. Left alone, the rootful build produces a second iphoneos-arm64
    # package that overwrites the rootless one.
    if [ "$scheme" = "rootful" ]; then
        sed -i 's/^Architecture: .*/Architecture: iphoneos-arm/' control
        make package FINALPACKAGE=1 HP_ROOTFUL=1 -j1
    else
        sed -i 's/^Architecture: .*/Architecture: iphoneos-arm64/' control
        make package FINALPACKAGE=1 -j1
    fi

    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "!! $label FAILED (exit $rc)"
        return $rc
    fi
    cp -f packages/*.deb "$OUT"/
    return 0
}

build_scheme "rootless" "rootless (iphoneos-arm64)" || exit 1
build_scheme "rootful" "rootful (iphoneos-arm)" || exit 1

echo
echo "=== release artifacts ==="
ls -la "$OUT"
for deb in "$OUT"/*.deb; do
    echo
    echo "--- $(basename "$deb") ---"
    dpkg-deb -f "$deb" Package Version Architecture Depends
    echo "payload:"
    dpkg-deb -c "$deb" | grep -E 'DynamicLibraries|libexec|usr/bin' | sed 's/^/  /'
done
