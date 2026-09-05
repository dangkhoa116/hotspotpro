# Check the live Sileo depiction for the structural mistakes that make it render
# as a blank Details tab rather than as an error.
#
# Sileo silently shows nothing when the JSON is well-formed but structurally
# wrong, so "it parses" is not enough — the root must declare its class, every
# tab and view needs one too, and every screenshot URL has to resolve.

param([string]$Url = 'https://dangkhoa116.github.io/hotspotpro/depiction.json')

$fail = 0
try {
    $raw = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 25).Content
    $d = $raw | ConvertFrom-Json
    "JSON parses"
} catch {
    Write-Error "cannot fetch or parse: $($_.Exception.Message)"; exit 1
}

if ($d.class) { "root class: $($d.class)" }
else { "ROOT HAS NO class — Sileo will render nothing"; $fail = 1 }

if (-not $d.minVersion) { "no minVersion"; $fail = 1 }

foreach ($tab in $d.tabs) {
    if (-not $tab.class)   { "tab '$($tab.tabname)' has no class"; $fail = 1 }
    if (-not $tab.tabname) { "a tab has no tabname"; $fail = 1 }
    foreach ($v in $tab.views) {
        if (-not $v.class) { "a view in '$($tab.tabname)' has no class"; $fail = 1 }
        foreach ($shot in $v.screenshots) {
            try {
                $r = Invoke-WebRequest -Uri $shot.url -UseBasicParsing -TimeoutSec 20 -Method Head
                "screenshot {0}: HTTP {1}" -f $shot.url.Split('/')[-1], $r.StatusCode
            } catch {
                "screenshot {0}: UNREACHABLE" -f $shot.url; $fail = 1
            }
        }
    }
}

if ($fail -eq 0) { "depiction looks valid" } else { "depiction has problems" }
exit $fail
