#!/bin/bash
# Regenerate the flat Sileo repo served from the PC at http://192.168.68.139:8000/
#
# Unlike CarPiP's version this scans every .deb in the repo directory and
# rebuilds Packages from their real control files, so CarPiP and HotspotPro can
# live in the same repo instead of one clobbering the other.
#
# Usage: repo-publish.sh [path-to-new.deb]
set -e

REPO="/mnt/c/Users/DangKhoa/CarPiP/repo"
NEW="$1"

if [ -n "$NEW" ]; then
    [ -f "$NEW" ] || { echo "missing $NEW"; exit 1; }
    cp -f "$NEW" "$REPO/$(basename "$NEW")"
    echo "added $(basename "$NEW")"
fi

cd "$REPO"
: > Packages

# Depiction and icon are served from the public repo. Pointing the dev repo at
# them means a package installed from the LAN looks exactly like what users see,
# rather than a bare entry with no screenshots — which is otherwise indis-
# tinguishable from the depiction being broken.
PUBLIC="https://dangkhoa116.github.io/hotspotpro"

for deb in *.deb; do
    [ -f "$deb" ] || continue
    # Strip any existing Filename/Size/hash lines from the embedded control and
    # emit fresh ones for this file.
    dpkg-deb -f "$deb" |
        grep -v -E '^(Filename|Size|MD5sum|SHA1|SHA256|Depiction|SileoDepiction|Icon):' >> Packages
    {
        echo "Filename: ./$deb"
        echo "Size: $(stat -c%s "$deb")"
        echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
        echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
        echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
        case "$deb" in
            *hotspotpro*)
                # Stamped with a timestamp rather than the version: during
                # development the version often does not change between builds,
                # and a cached depiction is exactly what wastes an afternoon.
                stamp=$(date +%s)
                echo "Icon: $PUBLIC/CydiaIcon.png?v=$stamp"
                echo "Depiction: $PUBLIC/depiction.html?v=$stamp"
                echo "SileoDepiction: $PUBLIC/depiction.json?v=$stamp"
                ;;
        esac
        echo
    } >> Packages
done

gzip -9 -c -n Packages > Packages.gz

PSZ=$(stat -c%s Packages);    PM5=$(md5sum Packages | cut -d' ' -f1);    PS2=$(sha256sum Packages | cut -d' ' -f1)
GSZ=$(stat -c%s Packages.gz); GM5=$(md5sum Packages.gz | cut -d' ' -f1); GS2=$(sha256sum Packages.gz | cut -d' ' -f1)

cat > Release <<EOF
Origin: DangKhoa Local
Label: DangKhoa Local
Suite: stable
Version: 1.0
Codename: local
Architectures: iphoneos-arm64
Components: main
Description: Local development repo
MD5Sum:
 ${PM5} ${PSZ} Packages
 ${GM5} ${GSZ} Packages.gz
SHA256:
 ${PS2} ${PSZ} Packages
 ${GS2} ${GSZ} Packages.gz
EOF

echo
echo "packages in repo:"
grep -E '^(Package|Version): ' Packages | paste - - | sed 's/^/  /'
