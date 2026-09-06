#!/usr/bin/env bash
# Both jailbreak layouts use the same build and ABI verification pipeline.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(awk '/^Version:/{print $2}' "$SRC/control")"
mkdir -p "$SRC/release"
for rootful in 0 1; do
    HP_ROOTFUL="$rootful" bash "$SRC/tools/build.sh" "$@"
    arch=iphoneos-arm64
    [ "$rootful" = 0 ] || arch=iphoneos-arm
    cp "$SRC/packages/com.dangkhoa.hotspotpro_${VERSION}_${arch}.deb" "$SRC/release/"
done
