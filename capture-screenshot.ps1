# Save a screenshot of the phone to a file.
#
# The MCP screenshot tool hands the image back inline, which is no use for
# committing files, so this speaks the same JSON-RPC directly and decodes the
# base64 payload to disk.
#
#   .\capture-screenshot.ps1 docs\screenshots\1-hotspot-pane.jpg

param([Parameter(Mandatory = $true)][string]$OutFile)

$server = 'http://192.168.68.182:8090/mcp'
$headers = @{
    'Accept'               = 'application/json, text/event-stream'
    'MCP-Protocol-Version' = '2025-06-18'
}

function Invoke-Mcp($body, $sessionId) {
    $h = $headers.Clone()
    if ($sessionId) { $h['Mcp-Session-Id'] = $sessionId }
    Invoke-WebRequest -Uri $server -Method Post -Headers $h `
        -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 8) `
        -UseBasicParsing -TimeoutSec 40
}

# Responses may arrive as SSE frames rather than plain JSON.
function Read-McpText($response) {
    if ($response.Content -is [string]) { return $response.Content }
    return [Text.Encoding]::UTF8.GetString($response.Content)
}

$init = Invoke-Mcp @{
    jsonrpc = '2.0'; id = 1; method = 'initialize'
    params  = @{
        protocolVersion = '2025-06-18'
        capabilities    = @{}
        clientInfo      = @{ name = 'hotspotpro-capture'; version = '1.0' }
    }
} $null

$session = $init.Headers['Mcp-Session-Id']
if ($session -is [array]) { $session = $session[0] }

Invoke-Mcp @{ jsonrpc = '2.0'; method = 'notifications/initialized' } $session | Out-Null

$shot = Invoke-Mcp @{
    jsonrpc = '2.0'; id = 2; method = 'tools/call'
    params  = @{ name = 'screenshot'; arguments = @{} }
} $session

# Pull the base64 straight out of the response text.
#
# ConvertFrom-Json on this payload kept handing back something whose
# .result.content did not index as expected, and debugging that is not worth it
# when the field is unambiguous: one "data" value holding base64. The escaped
# forward slashes ("\/") in the JSON string have to be unescaped or the decode
# fails.
# Invoke-WebRequest gives Content as a String for JSON responses and a byte
# array for binary ones. Feeding a String to UTF8.GetString is what produced
# "Cannot convert argument bytes" — an error that reads like a decode failure
# but happens before any decoding.
$raw = if ($shot.Content -is [string]) { $shot.Content }
       else { [Text.Encoding]::UTF8.GetString($shot.Content) }
if ($raw -notmatch '"data"\s*:\s*"([^"]+)"') {
    Write-Error "no image data in response"
    exit 1
}
$b64 = $Matches[1] -replace '\\/', '/'

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

[IO.File]::WriteAllBytes($OutFile, [Convert]::FromBase64String($b64))

# A JPEG starts with FF D8 FF; anything else means we saved rubbish.
$head = [IO.File]::ReadAllBytes($OutFile)[0..2]
if ($head[0] -ne 0xFF -or $head[1] -ne 0xD8) {
    Write-Error "saved file is not a JPEG"
    exit 1
}
"{0}  ({1:N0} bytes)" -f $OutFile, (Get-Item $OutFile).Length
