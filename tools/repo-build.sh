#!/usr/bin/env bash
# Generate a static APT repo into docs/, ready to serve from GitHub Pages.
#
#   ./repo-build.sh https://YOURNAME.github.io/HotspotPro
#
# GitHub Pages can serve the docs/ folder of a branch directly, so the repo and
# its source live in one place with nothing to deploy. Everything here is
# regenerated from release/*.deb, so the flow is: build-release.sh, then this.
set -e

# This script lives in tools/, so the project root is one level up.
SRC="$(cd "$(dirname "$0")/.." && pwd)"

BASE_URL="${1:-$(cat "$SRC/repo-url.txt" 2>/dev/null || echo "https://CHANGEME.github.io/HotspotPro")}"
BASE_URL="${BASE_URL%/}"
DOCS="$SRC/docs"
DEBS="$DOCS/debs"

if ! ls "$SRC"/release/*.deb >/dev/null 2>&1; then
    echo "no packages in release/ — run build-release.sh first"; exit 1
fi

GITHUB="${GITHUB_URL:-$(cat "$SRC/github-url.txt" 2>/dev/null || echo "https://github.com/CHANGEME/HotspotPro")}"
VERSION="$(grep '^Version:' "$SRC/control" | cut -d' ' -f2)"

# The Sileo changelog is hand-written in web/depiction.json, in plain language
# rather than README's technical notes, so it is the one thing a version bump
# does not carry with it. 0.6.7 shipped with a changelog whose newest entry
# still said 0.6.6; this is what catches that.
DEP_TOP="$(grep -o '\*\*[0-9][0-9.]*\*\*' "$SRC/web/depiction.json" | head -1 | tr -d '*')"
if [ "$DEP_TOP" != "$VERSION" ]; then
    echo "control says $VERSION but the newest changelog entry in"
    echo "web/depiction.json is $DEP_TOP — add it before publishing."
    exit 1
fi

# Optional: serve the packages from a GitHub release instead of from Pages.
#
#   HP_RELEASE_TAG=v0.5.2 ./repo-build.sh
#
# Pages keeps no access logs, so a deb served from docs/debs/ can never be
# counted. GitHub counts every fetch of a release asset and reports it through
# the API, which is what stats.ps1 reads. Package managers accept an absolute
# URL in Filename, so this changes only where the bytes come from.
#
# The debs are still copied into docs/debs/ either way: they cost nothing, and
# they are the fallback if a release asset is ever deleted.
RELEASE_TAG="${HP_RELEASE_TAG:-}"

mkdir -p "$DEBS"
rm -f "$DEBS"/*.deb
cp -f "$SRC"/release/*.deb "$DEBS"/
cp -f "$SRC"/assets/icon.png "$DOCS"/CydiaIcon.png

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
        if [ -n "$RELEASE_TAG" ]; then
            echo "Filename: $GITHUB/releases/download/$RELEASE_TAG/$(basename "$deb")"
        else
            echo "Filename: $deb"
        fi
        echo "Size: $(stat -c%s "$deb")"
        echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
        echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
        echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
        # ?v= is cache-busting, not decoration. Sileo and GitHub Pages both
        # cache depictions, so a fixed URL means users keep seeing the previous
        # release's depiction — including a broken one — long after it is fixed.
        echo "Icon: $BASE_URL/CydiaIcon.png?v=$VERSION"
        echo "Depiction: $BASE_URL/depiction.html?v=$VERSION"
        echo "SileoDepiction: $BASE_URL/depiction.json?v=$VERSION"
        echo "Homepage: $BASE_URL"
        echo
    } >> Packages
done

rm -f Packages.gz Packages.bz2
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
    # EVERY compressed form that exists must be listed here. Sileo prefers
    # Packages.bz2, and a file present on the server but missing from Release
    # fails its integrity check with "Hash for Packages.bz2 is invalid" — which
    # reads like corruption but really means "not declared".
    echo "MD5Sum:"
    md5_line Packages
    md5_line Packages.gz
    [ -f Packages.bz2 ] && md5_line Packages.bz2
    echo "SHA256:"
    hash_line Packages
    hash_line Packages.gz
    [ -f Packages.bz2 ] && hash_line Packages.bz2
} > Release

if [ -n "$RELEASE_TAG" ]; then
    echo "packages point at release $RELEASE_TAG (downloads counted by GitHub)"
else
    echo "packages served from Pages (downloads NOT counted; set HP_RELEASE_TAG to count)"
fi
echo "repo written to $DOCS for $BASE_URL"
grep -E '^(Package|Version|Architecture|Filename): ' Packages | sed 's/^/  /'
