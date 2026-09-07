#!/usr/bin/env bash
# Generate the BETA channel: a second, opt-in APT repo under docs/beta/.
#
#   ./repo-build-beta.sh [https://YOURNAME.github.io/HotspotPro]
#
# The point of a separate channel is that it is discoverable without being
# forced on anyone. The stable repo lives at docs/ and everyone who added the
# main URL keeps getting stable releases; the beta lives at docs/beta/ and only
# someone who adds the .../beta/ URL ever sees a beta. The two indexes are
# independent files under one Pages site, so publishing a beta never touches a
# single byte the stable users fetch.
#
# It is deliberately NOT repo-build.sh with a flag: that script guards that the
# depiction changelog matches the released version, serves debs from counted
# GitHub release assets, and writes the top-level index. A beta wants none of
# that — its version is ahead of the changelog by definition, its debs are
# sideload artifacts nobody is counting, and it must not overwrite the stable
# landing page. Keeping them apart means a beta build can never clobber stable.
#
# Everything here is regenerated from release/*.deb, so the flow is: download
# the debs the macOS build produced for the beta branch into release/, then run
# this. The debs are served straight from docs/beta/debs/ (relative Filename),
# not from a GitHub release — a beta is not something to cut a tag for.
set -e

SRC="$(cd "$(dirname "$0")/.." && pwd)"

# Arg 1 (or repo-url.txt) is the MAIN site base; the beta channel hangs off it.
MAIN_BASE="${1:-$(cat "$SRC/repo-url.txt" 2>/dev/null || echo "https://dangkhoa116.github.io/hotspotpro")}"
MAIN_BASE="${MAIN_BASE%/}"
BASE_URL="$MAIN_BASE/beta"
GITHUB="${GITHUB_URL:-$(cat "$SRC/github-url.txt" 2>/dev/null || echo "https://github.com/dangkhoa116/hotspotpro")}"

# Where the beta repo is written. Overridable so the generator can be dry-run
# into a throwaway directory without touching the tree that gets committed.
DOCS="${HP_BETA_DOCS:-$SRC/docs/beta}"
DEBS="$DOCS/debs"

if ! ls "$SRC"/release/*.deb >/dev/null 2>&1; then
    echo "no packages in release/ — download the beta build's debs into release/ first"
    exit 1
fi

# The version describes the debs being published, so read it from a deb rather
# than from control — that way this runs correctly from any branch (master
# included) against whatever beta debs were downloaded into release/, instead of
# only from the branch whose control happens to carry the beta stamp.
VERSION="$(dpkg-deb -f "$(ls "$SRC"/release/*.deb | head -1)" Version)"
case "$VERSION" in
    *"~"*|*beta*|*rc*) : ;;   # a pre-release version, as a beta should carry
    *) echo "the debs in release/ are version '$VERSION', which is not a"
       echo "pre-release. A beta should be stamped e.g. 0.6.8~beta1 so it never"
       echo "outranks a real release. Refusing to build a beta channel from it."
       exit 1 ;;
esac

mkdir -p "$DEBS"
rm -f "$DEBS"/*.deb
cp -f "$SRC"/release/*.deb "$DEBS"/
cp -f "$SRC"/assets/icon.png "$DOCS"/CydiaIcon.png

# Render the web templates into the beta channel, stamped with the beta URL and
# version. A visible BETA banner is injected so nobody mistakes this channel for
# stable, and the "Add to Sileo" button already follows @BASE_URL@ to the beta
# URL. donate.html is not carried: a test channel has no tip jar.
for template in "$SRC"/web/index.html "$SRC"/web/depiction.html "$SRC"/web/depiction.json; do
    [ -f "$template" ] || continue
    name="$(basename "$template")"
    sed -e "s|@BASE_URL@|$BASE_URL|g" \
        -e "s|@GITHUB@|$GITHUB|g" \
        -e "s|@VERSION@|$VERSION|g" \
        "$template" > "$DOCS/$name"
done

# A plain, unmissable marker on the landing page. Inserted right after <body>
# so it shows before anything else, whatever the template's structure.
if [ -f "$DOCS/index.html" ]; then
    banner='<p style="margin:0;padding:10px 16px;background:#8a5a00;color:#fff;font:600 14px system-ui;text-align:center">BETA channel — pre-release test builds. For the stable repo, use '"$MAIN_BASE"'/</p>'
    awk -v b="$banner" '{print} /<body[^>]*>/ && !done {print b; done=1}' \
        "$DOCS/index.html" > "$DOCS/index.html.tmp" && mv "$DOCS/index.html.tmp" "$DOCS/index.html"
fi

cd "$DOCS"
: > Packages

DEPSTAMP="$(cat depiction.json depiction.html 2>/dev/null | md5sum | cut -c1-8)"

for deb in debs/*.deb; do
    dpkg-deb -f "$deb" |
        grep -v -E '^(Filename|Size|MD5sum|SHA1|SHA256|Depiction|SileoDepiction|Icon):' >> Packages
    {
        # Served from the beta channel itself, not a GitHub release: a beta is
        # not tagged. The URL a tester added is .../beta/, so a relative
        # Filename resolves under it.
        echo "Filename: $deb"
        echo "Size: $(stat -c%s "$deb")"
        echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
        echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
        echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
        echo "Icon: $BASE_URL/CydiaIcon.png?v=$VERSION"
        echo "Depiction: $BASE_URL/depiction.html?v=$VERSION-$DEPSTAMP"
        echo "SileoDepiction: $BASE_URL/depiction.json?v=$VERSION-$DEPSTAMP"
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
    echo "Origin: HotspotPro (beta)"
    echo "Label: HotspotPro (beta)"
    echo "Suite: beta"
    echo "Version: 1.0"
    echo "Codename: hotspotpro-beta"
    echo "Architectures: iphoneos-arm iphoneos-arm64"
    echo "Components: main"
    echo "Description: HotspotPro pre-release test builds"
    echo "MD5Sum:"
    md5_line Packages
    md5_line Packages.gz
    [ -f Packages.bz2 ] && md5_line Packages.bz2
    echo "SHA256:"
    hash_line Packages
    hash_line Packages.gz
    [ -f Packages.bz2 ] && hash_line Packages.bz2
} > Release

echo "beta repo written to $DOCS for $BASE_URL"
grep -E '^(Package|Version|Architecture|Filename): ' Packages | sed 's/^/  /'
