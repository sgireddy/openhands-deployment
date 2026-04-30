<#
.SYNOPSIS
    Discover the latest stable software-agent-sdk release and (optionally)
    bump AGENT_SERVER_BASE_TAG in .env then rebuild. PowerShell counterpart
    of scripts/update.sh.

.PARAMETER Apply
    Bump .env and re-run build.ps1 -Yes. Without this flag the script is
    read-only.

.EXAMPLE
    .\scripts\update.ps1            # just print current vs latest stable
    .\scripts\update.ps1 -Apply     # bump and rebuild

.NOTES
    Discovery uses GitHub's /releases/latest endpoint, which by definition
    excludes prereleases and drafts — matching the project's stable-only
    versioning policy.
#>

[CmdletBinding()]
param(
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'lib.ps1')

Load-Env -RepoRoot $RepoRoot

# --- ghcr tag existence probe ----------------------------------------------
function Test-GhcrTag {
    param([Parameter(Mandatory)] [string]$Repo, [Parameter(Mandatory)] [string]$Tag)
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:${Repo}:pull" -TimeoutSec 10
    } catch {
        return $false
    }
    if (-not $tok.token) { return $false }
    try {
        $resp = Invoke-WebRequest `
            -Uri ("https://ghcr.io/v2/{0}/manifests/{1}" -f $Repo, $Tag) `
            -Method Head `
            -Headers @{
                'Authorization' = "Bearer $($tok.token)"
                'Accept'        = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'
            } `
            -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# --- discover --------------------------------------------------------------
Log-Hdr 'Discovering newer upstream tags'

Log-Info 'Querying github.com/OpenHands/software-agent-sdk/releases/latest ...'
$headers = @{ 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

$asNewest = $null
try {
    $rel = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/OpenHands/software-agent-sdk/releases/latest' `
        -Headers $headers -TimeoutSec 10
    $sdkTag   = $rel.tag_name
    $sdkVer   = $sdkTag -replace '^v',''
    $candidate = "${sdkVer}-python"
    Log-Info ("  latest SDK release : {0}" -f $sdkTag)
    if (Test-GhcrTag -Repo 'openhands/agent-server' -Tag $candidate) {
        $asNewest = $candidate
    } else {
        Log-Warn ("  {0} not found on ghcr.io (mismatch between release and image publish)" -f $candidate)
    }
} catch {
    Log-Warn '  could not reach GitHub releases API (rate limit? offline?)'
}

Log-Info ("  current  : {0}" -f $env:AGENT_SERVER_BASE_TAG)
Log-Info ("  newest   : {0}" -f ($(if ($asNewest) { $asNewest } else { '<none-found>' })))

Log-Info ("OpenHands base image ({0}:{1}) is operator-managed; not auto-discovered." -f $env:OPENHANDS_BASE_IMAGE, $env:OPENHANDS_BASE_TAG)

if (-not $Apply) {
    Log-Info ''
    Log-Info 'Run with -Apply to bump .env and rebuild.'
    exit 0
}

# --- apply -----------------------------------------------------------------
if (-not $asNewest -or $asNewest -eq $env:AGENT_SERVER_BASE_TAG) {
    Log-Ok 'No update needed: pin already on latest stable (or discovery failed).'
    exit 0
}

if (-not (Confirm-Continue ("Bump AGENT_SERVER_BASE_TAG {0} -> {1}?" -f $env:AGENT_SERVER_BASE_TAG, $asNewest))) {
    Log-Info 'Aborted by user.'
    exit 0
}

$envPath = Join-Path $RepoRoot '.env'
if (-not (Test-Path -LiteralPath $envPath)) {
    Log-Err ".env file not found at $envPath. Copy .env.example to .env first."
    exit 1
}

$content = Get-Content -LiteralPath $envPath -Raw
if ($content -match '(?m)^AGENT_SERVER_BASE_TAG\s*=') {
    $content = $content -replace '(?m)^AGENT_SERVER_BASE_TAG\s*=.*$', "AGENT_SERVER_BASE_TAG=$asNewest"
} else {
    $content += "`nAGENT_SERVER_BASE_TAG=$asNewest`n"
}
Set-Content -LiteralPath $envPath -Value $content -NoNewline
Log-Ok ("bumped AGENT_SERVER_BASE_TAG -> {0}" -f $asNewest)

Log-Hdr 'Re-running build.ps1 ...'
& (Join-Path $PSScriptRoot 'build.ps1') -Yes
exit $LASTEXITCODE
