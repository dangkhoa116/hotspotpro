#!/usr/bin/env bash
# Verify the LIVE repo the way a package manager does: fetch Release, then
# fetch every Packages variant it declares and check the SHA256 matches.
#
# Written after Sileo rejected the repo with "Hash for Packages.bz2 is
# invalid": the file was being served but not declared in Release, which no
# amount of "does the URL return 200" checking would have caught.
#
#   ./check-repo.sh [base-url]
# tools/ sits one level below the project root, where repo-url.txt lives.
BASE="${1:-$(cat "$(dirname "$0")/../repo-url.txt" 2>/dev/null)}"
BASE="${BASE%/}"
TMP=$(mktemp -d)
FAIL=0

echo "checking $BASE"
if ! curl -fsSL "$BASE/Release" -o "$TMP/Release"; then
    echo "  FAIL: Release not fetchable"; exit 1
fi
echo "  Release: ok"

# Everything the server actually offers, so a served-but-undeclared file shows up.
for variant in Packages Packages.gz Packages.bz2; do
    if ! curl -fsSL "$BASE/$variant" -o "$TMP/$variant" 2>/dev/null; then
        echo "  $variant: not served (fine if never generated)"
        continue
    fi

    declared=$(awk -v f="$variant" '/^SHA256:/{s=1;next} /^[A-Za-z]/{s=0} s && $3==f {print $1}' "$TMP/Release" | head -1)
    actual=$(sha256sum "$TMP/$variant" | cut -d' ' -f1)

    if [ -z "$declared" ]; then
        echo "  $variant: SERVED BUT NOT DECLARED in Release — package managers will reject this"
        FAIL=1
    elif [ "$declared" = "$actual" ]; then
        echo "  $variant: hash ok"
    else
        echo "  $variant: HASH MISMATCH (Release says ${declared:0:12}…, file is ${actual:0:12}…)"
        FAIL=1
    fi
done

# And that every package's Filename actually resolves.
#
# Filename may be relative to the repo (Pages-hosted) or an absolute URL (a
# GitHub release asset, so downloads get counted). Release assets answer with a
# 302 to objects.githubusercontent.com, so redirects must be followed or every
# counted package reads as broken.
#
# Fed by process substitution, not a pipe: a `while` on the right of a pipe runs
# in a subshell, so FAIL=1 was being set and then discarded -- this loop used to
# report failures and still exit 0.
while read -r rel; do
    case "$rel" in
        http://*|https://*) url="$rel" ;;
        *)                  url="$BASE/$rel" ;;
    esac
    # HEAD, so verifying the repo does not inflate the download count.
    code=$(curl -o /dev/null -sw '%{http_code}' -IL "$url")
    if [ "$code" = "200" ]; then
        echo "  $rel: $code"
    else
        echo "  $rel: $code FAIL"
        FAIL=1
    fi
done < <(grep '^Filename:' "$TMP/Packages" | awk '{print $2}')

rm -rf "$TMP"
[ "$FAIL" = 0 ] && echo "repo is consistent" || echo "repo has problems"
exit $FAIL
