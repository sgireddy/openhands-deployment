<#
.SYNOPSIS
    Scan upstream, overlay, scan again, verify CVE policy.

.DESCRIPTION
    PowerShell counterpart of scripts/build.sh. Assumes both upstream
    images already exist in the local Docker cache; this script does NOT
    pull anything. Procuring upstream is the operator's job.

    For each component (openhands, agent-server):
      1. Verify upstream is in local cache; bail if not.
      2. Scout-scan upstream (BASELINE).
      3. Build local hardening overlay (Dockerfile.<component>).
      4. Scout-scan the result.
      5. Apply policy (POLICY_MAX_CRITICAL / POLICY_MAX_HIGH from .env).

.PARAMETER Component
    "openhands" or "agent-server". Omit to run both.

.PARAMETER Yes
    Skip interactive prompts.

.EXAMPLE
    .\scripts\build.ps1
    .\scripts\build.ps1 -Component agent-server
    .\scripts\build.ps1 -Yes

.NOTES
    Exit codes:
      0  all components built and within policy
      1  hard error
      2  policy violation on at least one component
#>

[CmdletBinding()]
param(
    [ValidateSet('openhands','agent-server')]
    [string[]]$Component,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'lib.ps1')

$script:AssumeYes = [bool]$Yes
if ($Yes) { $env:ASSUME_YES = '1' }

if (-not $Component) { $Component = @('openhands','agent-server') }

Load-Env -RepoRoot $RepoRoot
Test-Tools

$RunDir = Join-Path $RepoRoot ("reports/{0}" -f (Get-Date -Format 'yyyyMMddTHHmmssZ' -AsUTC))
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
Log-Info ("Reports -> {0}" -f $RunDir)

# Banner: surface drift before doing real work.
Show-DriftBanner

# IMPORTANT: PowerShell function return semantics.
# Every uncaptured expression inside a function (including stdout from any
# `& native.exe ...` call) is sent to the success stream and becomes part
# of the function's return value. To return a single int and nothing else
# we must:
#   - Pipe external commands to `Out-Host`        (show user, don't capture)
#     or `Out-Null`                                (suppress entirely)
#     or assign to a variable                     (capture, don't emit)
#   - Use `[OutputType([int])]` for self-doc + linting.
function Invoke-ComponentBuild {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('openhands','agent-server')]
        [string]$Comp
    )

    switch ($Comp) {
        'openhands' {
            $baseImage    = $env:OPENHANDS_BASE_IMAGE
            $baseTag      = $env:OPENHANDS_BASE_TAG
            $outImage     = $env:OPENHANDS_OUT_IMAGE
            $outTag       = $env:OPENHANDS_OUT_TAG
            $dockerfile   = Join-Path $RepoRoot 'overlays/Dockerfile.openhands'
            $pipUpgrades  = $env:PIP_UPGRADES_OPENHANDS
        }
        'agent-server' {
            $baseImage    = $env:AGENT_SERVER_BASE_IMAGE
            $baseTag      = $env:AGENT_SERVER_BASE_TAG
            $outImage     = $env:AGENT_SERVER_OUT_IMAGE
            $outTag       = $env:AGENT_SERVER_OUT_TAG
            $dockerfile   = Join-Path $RepoRoot 'overlays/Dockerfile.agent-server'
            $pipUpgrades  = $env:PIP_UPGRADES_AGENT_SERVER
        }
    }
    $upstream = "${baseImage}:${baseTag}"
    $hardened = "${outImage}:${outTag}"

    Log-Hdr ("[{0}] upstream={1}  ->  hardened={2}" -f $Comp, $upstream, $hardened)

    # 1. require upstream cached. *> $null swallows all streams.
    & docker image inspect $upstream *> $null
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Log-Err ("[{0}] upstream image not found locally: {1}" -f $Comp, $upstream)
        Log-Err  '  This script does not pull upstream images. Obtain it first, e.g.:'
        if ($Comp -eq 'openhands') {
            Log-Err '    cd <OpenHands source repo>; make build'
        } else {
            Log-Err ("    docker pull {0}" -f $upstream)
        }
        return [int]1
    }
    Log-Ok ("[{0}] upstream cached: {1}" -f $Comp, $upstream)

    # 2. baseline scan
    Invoke-ScoutScan -Image $upstream -Prefix "${Comp}-01-baseline" -RunDir $RunDir
    $bCounts = Get-ScoutCounts (Join-Path $RunDir "${Comp}-01-baseline-quickview.txt")
    $bCrit, $bHigh = $bCounts -split ':'
    Log-Info ("[{0}] baseline           : {1}C / {2}H" -f $Comp, $bCrit, $bHigh)

    # 3. overlay build. Pipe to Out-Host so the user sees streaming output,
    # WITHOUT it leaking into our function's return value.
    Log-Hdr ("[{0}] building overlay -> {1}" -f $Comp, $hardened)
    & docker build `
        -f $dockerfile `
        --build-arg "BASE_IMAGE=$upstream" `
        --build-arg "PIP_UPGRADES=$pipUpgrades" `
        --no-cache `
        -t $hardened `
        $RepoRoot 2>&1 | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Log-Err ("[{0}] overlay build failed (docker exit {1}); see error above" -f $Comp, $rc)
        return [int]1
    }
    Log-Ok ("[{0}] built {1}" -f $Comp, $hardened)

    # 4. post-overlay scan
    Invoke-ScoutScan -Image $hardened -Prefix "${Comp}-02-post-overlay" -RunDir $RunDir
    $pCounts = Get-ScoutCounts (Join-Path $RunDir "${Comp}-02-post-overlay-quickview.txt")
    $pCrit, $pHigh = $pCounts -split ':'
    Log-Info ("[{0}] after overlay      : {1}C / {2}H   (was {3}C / {4}H)" -f $Comp, $pCrit, $pHigh, $bCrit, $bHigh)

    # 5. policy gate
    $verdict = Test-Policy -Crit $pCrit -High $pHigh
    if     ($verdict.StartsWith('PASS')) { Log-Ok   ("[{0}] policy: {1}" -f $Comp, $verdict); return [int]0 }
    elseif ($verdict.StartsWith('FAIL')) { Log-Err  ("[{0}] policy: {1}" -f $Comp, $verdict); return [int]2 }
    else                                 { Log-Warn ("[{0}] policy: {1}" -f $Comp, $verdict); return [int]0 }
}

$exitCode = 0
foreach ($c in $Component) {
    # Force scalar int even if a downstream change ever leaks pipeline output.
    $rc = [int](Invoke-ComponentBuild -Comp $c | Select-Object -Last 1)
    switch ($rc) {
        0 { }
        2 { $exitCode = 2 }
        default {
            Log-Err ("Invoke-ComponentBuild '{0}' failed (rc={1}); aborting" -f $c, $rc)
            exit 1
        }
    }
}

Log-Hdr 'Summary'
Log-Info ("Run reports : {0}" -f $RunDir)
Log-Info  'Compose up  : docker compose -f compose/docker-compose.yml --env-file .env up -d'

if ($exitCode -eq 2) {
    Log-Warn 'At least one component violates policy. See reports/*-cves-critical-high.txt'
}
exit $exitCode
