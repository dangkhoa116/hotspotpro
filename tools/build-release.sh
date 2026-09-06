#!/usr/bin/env bash
# Build the release set: one .deb per jailbreak type, each fat with both
# architectures. Run as builder.
#   wsl -d Ubuntu -u builder -- bash /mnt/c/Users/DangKhoa/HotspotPro/tools/build-release.sh
#
# Why two packages:
#   rootless (Architecture: iphoneos-arm64) — Dopamine, palera1n rootless, Xina
#   rootful  (Architecture: iphoneos-arm)   — unc0ver, checkra1n, palera1n rootful
# and why both architectures in each: arm64 covers A7-A11, arm64e covers A12 and
# newer, whose system processes a purely arm64 dylib cannot be injected into.

export THEOS="${THEOS:-$HOME/theos}"

# The Linux toolchain's own clang. Absent on a macOS CI runner, where Xcode
# supplies the compiler and, more to the point, a linker that can emit a
# loadable arm64e slice -- which is why this script has to run there at all.
if [ -d "$THEOS/toolchain/linux/host/bin" ]; then
    export PATH="$THEOS/toolchain/linux/host/bin:$PATH"
fi

# Derived, not hardcoded: the same script builds on the WSL box and on the
# macOS runner.
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$SRC/build-release.log"
exec > >(tee "$LOG") 2>&1
echo "=== release build started $(date) ==="

WORK="$HOME/HotspotPro-release"
rm -rf "$WORK"
mkdir -p "$WORK"
# Sources live in src/ but land FLAT in the build dir, so the Makefile keeps
# naming them bare. Do not "fix" that by adding src/ prefixes in the Makefile.
cp -f "$SRC"/src/*.m "$SRC"/src/*.h "$SRC"/src/*.x "$WORK"/ 2>/dev/null
cp -f "$SRC"/Makefile "$SRC"/control "$SRC"/*.plist "$WORK"/ 2>/dev/null

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
    # sed -i.bak, not sed -i: BSD sed on macOS reads the next argument as the
    # backup suffix, so the GNU spelling fails on the CI runner.
    # The Makefile says `latest`, which on a machine that also has Xcode means
    # Xcode's own iPhoneOS SDK -- and that one carries no PrivateFrameworks
    # stubs, so HotspotProSettings fails to link against Preferences.framework.
    # HP_TARGET pins it there. Empty here, where the only SDK is the right one.
    local target=""
    if [ -n "${HP_TARGET:-}" ]; then
        target="TARGET=$HP_TARGET"
        echo "target: $HP_TARGET"
    fi

    if [ "$scheme" = "rootful" ]; then
        sed -i.bak 's/^Architecture: .*/Architecture: iphoneos-arm/' control
        rm -f control.bak
        make package FINALPACKAGE=1 HP_ROOTFUL=1 $target -j1
    else
        sed -i.bak 's/^Architecture: .*/Architecture: iphoneos-arm64/' control
        rm -f control.bak
        make package FINALPACKAGE=1 $target -j1
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

# The gate. v0.6.6 shipped an arm64e slice in the legacy unversioned ptrauth
# ABI, which iOS 16.3.1 loads with truncated binds -- Settings and SpringBoard
# both died on it. A build that links and packages cleanly can still be
# unshippable, so the encoding is checked here rather than trusted.
echo
echo "=== fat / ABI check ==="
# `bash script`, never `./script`: nothing in this repo carries the exec bit,
# because the work tree lives on /mnt/c and WSL1's DrvFs has no permission
# metadata to store it in. Calling it directly is a permission denied on any
# machine that respects the mode -- which is how this first failed in CI.
if ! bash "$SRC/tools/check-fat.sh" "$OUT"; then
    echo "!! the debs above are NOT releasable"
    exit 1
fi
for deb in "$OUT"/*.deb; do
    echo
    echo "--- $(basename "$deb") ---"
    dpkg-deb -f "$deb" Package Version Architecture Depends
    echo "payload:"
    dpkg-deb -c "$deb" | grep -E 'DynamicLibraries|libexec|usr/bin' | sed 's/^/  /'
done
