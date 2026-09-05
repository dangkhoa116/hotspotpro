# Print how many times each HotspotPro package has been downloaded.
#
# GitHub Pages keeps no access logs, so a deb served from docs/ is uncountable.
# A deb attached to a GitHub *release* is counted by GitHub on every fetch and
# the number is readable without authentication. That is why repo-build.sh has
# a release mode -- see HP_RELEASE_TAG in that script.
#
#   .\stats.ps1
#
# Read these as downloads, not installs: an upgrade counts again, a failed
# install still counts, and a download that happened before the release existed
# was never counted at all.

param(
    [string]$Repo = 'dangkhoa116/hotspotpro'
)

$api = "https://api.github.com/repos/$Repo/releases"

try {
    # The API returns JSON; -UseBasicParsing keeps this working on a machine
    # where IE first-run has never been completed.
    $releases = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 25 -Headers @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'hotspotpro-stats'
    }
} catch {
    Write-Error "cannot reach the GitHub API: $($_.Exception.Message)"
    Write-Host "  (unauthenticated calls are limited to 60 per hour per IP)"
    exit 1
}

if (-not $releases -or $releases.Count -eq 0) {
    Write-Host "no releases yet for $Repo"
    Write-Host ""
    Write-Host "Create one at https://github.com/$Repo/releases/new, pick the"
    Write-Host "existing tag, and attach the .deb files from release\. Counting"
    Write-Host "starts from the moment the assets exist; downloads before that"
    Write-Host "are not recoverable."
    exit 0
}

Write-Host "HotspotPro downloads ($Repo)"
Write-Host ""

$grand = 0
foreach ($r in $releases) {
    $published = if ($r.published_at) { ([datetime]$r.published_at).ToString('yyyy-MM-dd') } else { 'draft' }
    $draft = if ($r.draft) { '  [DRAFT - not public, will not be counted]' } else { '' }
    Write-Host ("  {0}   published {1}{2}" -f $r.tag_name, $published, $draft)

    $subtotal = 0
    $debs = 0
    foreach ($a in $r.assets) {
        Write-Host ("      {0,-52} {1,6}" -f $a.name, $a.download_count)
        $subtotal += $a.download_count
        if ($a.name -like '*.deb') { $debs++ }
    }

    if ($r.assets.Count -eq 0) {
        Write-Host "      (no assets attached - nothing to count)"
    } else {
        Write-Host ("      {0,-52} {1,6}" -f 'subtotal', $subtotal)
    }

    # Both architectures must be attached or half your users fall back to the
    # uncounted Pages copy, which looks like low adoption rather than a gap.
    if ($debs -eq 1) {
        Write-Host "      warning: only one .deb attached; the other arch is uncounted"
    }

    $grand += $subtotal
    Write-Host ""
}

Write-Host ("  total across all releases: {0}" -f $grand)
