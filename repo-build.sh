#!/usr/bin/env bash
# Generate a static APT repo into docs/, ready to serve from GitHub Pages.
#
#   ./repo-build.sh https://YOURNAME.github.io/HotspotPro
#
# GitHub Pages can serve the docs/ folder of a branch directly, so the repo and
# its source live in one place with nothing to deploy. Everything here is
# regenerated from release/*.deb, so the flow is: build-release.sh, then this.
set -e

BASE_URL="${1:-$(cat "$(dirname "$0")/repo-url.txt" 2>/dev/null || echo "https://CHANGEME.github.io/HotspotPro")}"
BASE_URL="${BASE_URL%/}"

SRC="$(cd "$(dirname "$0")" && pwd)"
DOCS="$SRC/docs"
DEBS="$DOCS/debs"

if ! ls "$SRC"/release/*.deb >/dev/null 2>&1; then
    echo "no packages in release/ — run build-release.sh first"; exit 1
fi

GITHUB="${GITHUB_URL:-$(cat "$SRC/github-url.txt" 2>/dev/null || echo "https://github.com/CHANGEME/HotspotPro")}"
VERSION="$(grep '^Version:' "$SRC/control" | cut -d' ' -f2)"

mkdir -p "$DEBS"
rm -f "$DEBS"/*.deb
cp -f "$SRC"/release/*.deb "$DEBS"/
cp -f "$SRC"/icon.png "$DOCS"/CydiaIcon.png

# The landing page and both depictions are rendered from web/ rather than
# edited in place, so the URLs live in one file and re-running this is safe.
for template in "$SRC"/web/*; do
    name="$(basename "$template")"

    # donate.html holds payment details that are edited by hand and must
    # outlive a rebuild, so it is seeded once and never overwritten.
    if [ "$name" = "donate.html" ] && [ -f "$DOCS/$name" ]; then
        echo "keeping your edited $name"
        continue
    fi

    sed -e "s|@BASE_URL@|$BASE_URL|g" \
        -e "s|@GITHUB@|$GITHUB|g" \
        -e "s|@VERSION@|$VERSION|g" \
        "$template" > "$DOCS/$name"
done

cd "$DOCS"
: > Packages

for deb in debs/*.deb; do
    dpkg-deb -f "$deb" |
        grep -v -E '^(Filename|Size|MD5sum|SHA1|SHA256|Depiction|SileoDepiction|Icon):' >> Packages
    {
        echo "Filename: $deb"
        echo "Size: $(stat -c%s "$deb")"
        echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
        echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
        echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
        echo "Icon: $BASE_URL/CydiaIcon.png"
        echo "Depiction: $BASE_URL/depiction.html"
        echo "SileoDepiction: $BASE_URL/depiction.json"
        echo "Homepage: $BASE_URL"
        echo
    } >> Packages
done

gzip -9 -c -n Packages > Packages.gz
command -v bzip2 >/dev/null && bzip2 -9 -c Packages > Packages.bz2 || true

hash_line() { echo " $(sha256sum "$1" | cut -d' ' -f1) $(stat -c%s "$1") $1"; }
md5_line()  { echo " $(md5sum "$1"    | cut -d' ' -f1) $(stat -c%s "$1") $1"; }

{
    echo "Origin: HotspotPro"
    echo "Label: HotspotPro"
    echo "Suite: stable"
    echo "Version: 1.0"
    echo "Codename: hotspotpro"
    echo "Architectures: iphoneos-arm iphoneos-arm64"
    echo "Components: main"
    echo "Description: Personal Hotspot usage, connected devices and data limits"
    echo "MD5Sum:"
    md5_line Packages
    md5_line Packages.gz
    echo "SHA256:"
    hash_line Packages
    hash_line Packages.gz
} > Release

echo "repo written to $DOCS for $BASE_URL"
grep -E '^(Package|Version|Architecture|Filename): ' Packages | sed 's/^/  /'
