<#
.SYNOPSIS
    Scan-only: re-check images without rebuilding. PowerShell counterpart of
    scripts/verify.sh.

.PARAMETER Component
    "openhands" or "agent-server". Omit to run both.

.PARAMETER Upstream
    Scan upstream images instead of the locally-built hardened ones.

.PARAMETER CheckPin
    No Docker scan; just check if AGENT_SERVER_BASE_TAG matches the latest
    stable software-agent-sdk release. Fast — usable from Task Scheduler.

.EXAMPLE
    .\scripts\verify.ps1
    .\scripts\verify.ps1 -Upstream
    .\scripts\verify.ps1 -CheckPin
    .\scripts\verify.ps1 -Component agent-server -Upstream

.NOTES
    Exit codes:
      0 = within policy / pin in sync
      1 = pin drift detected (-CheckPin only)
      2 = policy violation
      3 = drift check could not reach GitHub (-CheckPin only)
#>

[CmdletBinding()]
param(
    [ValidateSet('openhands','agent-server')]
    [string[]]$Component,
    [switch]$Upstream,
    [switch]$CheckPin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not $Component) { $Component = @('openhands','agent-server') }

Load-Env -RepoRoot $RepoRoot

if ($CheckPin) {
    $drift = Get-AgentServerDrift
    switch -Wildcard ($drift) {
        'IN_SYNC' {
            Log-Ok ("agent-server pin in sync with latest stable ({0})" -f $env:AGENT_SERVER_BASE_TAG)
            exit 0
        }
        'DRIFT:*' {
            $newer = $drift.Substring(6)
            Log-Err ("agent-server pin DRIFT: current={0}  latest-stable={1}" -f $env:AGENT_SERVER_BASE_TAG, $newer)
            exit 1
        }
        'UNKNOWN' {
            Log-Warn 'could not reach github.com to check drift'
            exit 3
        }
    }
}

Test-Tools
Show-DriftBanner

# See note in build.ps1 about why REPORTS_DIR defaults outside the repo.
$reportsRoot = if ($env:REPORTS_DIR) {
    $env:REPORTS_DIR
} else {
    Join-Path $HOME 'openhands-deployment/reports'
}
$RunDir = Join-Path $reportsRoot ("verify-{0}" -f (Get-Date -Format 'yyyyMMddTHHmmssZ' -AsUTC))
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Resolve-Image {
    param([string]$Comp, [bool]$ScanUpstream)
    if ($ScanUpstream) {
        if ($Comp -eq 'openhands') { return "$($env:OPENHANDS_BASE_IMAGE):$($env:OPENHANDS_BASE_TAG)" }
        else                       { return "$($env:AGENT_SERVER_BASE_IMAGE):$($env:AGENT_SERVER_BASE_TAG)" }
    } else {
        if ($Comp -eq 'openhands') { return "$($env:OPENHANDS_OUT_IMAGE):$($env:OPENHANDS_OUT_TAG)" }
        else                       { return "$($env:AGENT_SERVER_OUT_IMAGE):$($env:AGENT_SERVER_OUT_TAG)" }
    }
}

$exitCode  = 0
$scanLabel = if ($Upstream) { 'upstream' } else { 'hardened' }

foreach ($c in $Component) {
    $image = Resolve-Image -Comp $c -ScanUpstream:$Upstream
    & docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) {
        Log-Warn ("[{0}] image not present locally: {1} (skipping)" -f $c, $image)
        continue
    }

    Invoke-ScanImage -Image $image -Prefix "${c}-${scanLabel}" -RunDir $RunDir
    $counts = Get-ScanCounts (Join-Path $RunDir "${c}-${scanLabel}-quickview.txt")
    $crit, $high = $counts -split ':'
    Log-Info ("[{0}] {1} ({2}) : {3}C / {4}H" -f $c, $scanLabel, $image, $crit, $high)

    $verdict = Test-Policy -Crit $crit -High $high
    if ($verdict.StartsWith('PASS')) {
        Log-Ok   ("[{0}] {1}" -f $c, $verdict)
    } elseif ($verdict.StartsWith('FAIL')) {
        Log-Err  ("[{0}] {1}" -f $c, $verdict)
        $exitCode = 2
    } else {
        Log-Warn ("[{0}] {1}" -f $c, $verdict)
    }
}

Log-Info ("Reports -> {0}" -f $RunDir)
exit $exitCode
