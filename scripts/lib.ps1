# scripts/lib.ps1 — shared helpers for build.ps1 / verify.ps1 / update.ps1.
# Dot-source this from the entry-point scripts:  . "$PSScriptRoot/lib.ps1"
#
# This is the PowerShell 7 counterpart of scripts/lib.sh. The two files MUST
# stay behaviourally aligned. When you change one, mirror the change to the
# other. Discrepancies are bugs.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- color logging ----------------------------------------------------------
$script:UseColor = $Host.UI.RawUI -and -not $env:NO_COLOR
function script:Cw([string]$Color, [string]$Text) {
    if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
}
function global:Log-Info  { param([string]$Msg) Cw 'Cyan'   ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg) }
function global:Log-Ok    { param([string]$Msg) Cw 'Green'  ("[ OK ] {0}" -f $Msg) }
function global:Log-Warn  { param([string]$Msg) [Console]::Error.WriteLine(("[WARN] {0}" -f $Msg)) }
function global:Log-Err   { param([string]$Msg) [Console]::Error.WriteLine(("[ERR ] {0}" -f $Msg)) }
function global:Log-Hdr   { param([string]$Msg) Cw 'Magenta' ("`n==> {0}" -f $Msg) }

function global:Confirm-Continue {
    param([string]$Prompt = 'Proceed?')
    if ($env:ASSUME_YES -eq '1' -or $script:AssumeYes) { return $true }
    $ans = Read-Host "$Prompt [y/N]"
    return $ans -match '^[Yy]$'
}

# --- env loading ------------------------------------------------------------
# Loads .env from $RepoRoot, then applies defaults for any unset variable.
# Variables are exposed as script-scoped variables in the *caller*, so we
# write into the global scope here.
function global:Load-Env {
    param([string]$RepoRoot)

    $envFile = Join-Path $RepoRoot '.env'
    if (Test-Path -LiteralPath $envFile) {
        Get-Content -LiteralPath $envFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { return }
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $name  = $Matches[1]
                $value = $Matches[2].Trim()
                # Strip surrounding quotes if present
                if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                    ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                Set-Item -LiteralPath ("Env:{0}" -f $name) -Value $value
            }
        }
    }

    # Apply defaults
    $defaults = @{
        OPENHANDS_BASE_IMAGE     = 'openhands'
        OPENHANDS_BASE_TAG       = 'latest'
        AGENT_SERVER_BASE_IMAGE  = 'ghcr.io/openhands/agent-server'
        AGENT_SERVER_BASE_TAG    = '1.19.0-python'
        OPENHANDS_OUT_IMAGE      = 'openhands'
        OPENHANDS_OUT_TAG        = 'custom_base'
        AGENT_SERVER_OUT_IMAGE   = 'agent-server'
        AGENT_SERVER_OUT_TAG     = 'custom_base'
        POLICY_MAX_CRITICAL      = '0'
        POLICY_MAX_HIGH          = ''
        PIP_UPGRADES_OPENHANDS   = ''
        PIP_UPGRADES_AGENT_SERVER = ''
    }
    foreach ($k in $defaults.Keys) {
        if (-not (Test-Path -LiteralPath ("Env:{0}" -f $k)) -or
            [string]::IsNullOrEmpty((Get-Item -LiteralPath ("Env:{0}" -f $k)).Value)) {
            Set-Item -LiteralPath ("Env:{0}" -f $k) -Value $defaults[$k]
        }
    }
}

# --- pre-flight -------------------------------------------------------------
function global:Test-Tools {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Log-Err 'docker not found in PATH. Install Docker Desktop and retry.'
        exit 1
    }
    # Probe scout. `docker scout version` exits non-zero if the plugin isn't installed.
    $null = & docker scout version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log-Err 'docker scout plugin not available. Install via: https://docs.docker.com/scout/install/'
        exit 1
    }
}

# --- scout scan -------------------------------------------------------------
# Runs three reports for an image and writes them under $RunDir with a
# common prefix.
#
# We disable scout's color codes by setting NO_COLOR=1 for the child process —
# without this, scout writes ANSI escapes when it detects a TTY and
# Get-ScoutCounts can't parse the line. (Bash version doesn't hit this
# because we redirect stdout to a file there, which scout treats as not-a-TTY
# automatically. PowerShell's pipeline keeps the parent's TTY context, so we
# have to be explicit.)
function global:Invoke-ScoutScan {
    param(
        [Parameter(Mandatory)] [string]$Image,
        [Parameter(Mandatory)] [string]$Prefix,
        [Parameter(Mandatory)] [string]$RunDir
    )
    Log-Hdr ("Scout scan: {0}  ({1})" -f $Prefix, $Image)
    $qv  = Join-Path $RunDir ("{0}-quickview.txt" -f $Prefix)
    $ch  = Join-Path $RunDir ("{0}-cves-critical-high.txt" -f $Prefix)
    $pkg = Join-Path $RunDir ("{0}-pkgs-critical-high.txt" -f $Prefix)

    $prevNoColor = $env:NO_COLOR
    $env:NO_COLOR = '1'
    try {
        # Capture as strings, then write file as UTF-8. Avoid Tee-Object's
        # platform-dependent default encoding entirely.
        $out = & docker scout quickview $Image 2>&1 | Out-String
        Set-Content -LiteralPath $qv  -Value $out -Encoding utf8

        $out = & docker scout cves --only-severity critical,high $Image 2>&1 | Out-String
        Set-Content -LiteralPath $ch  -Value $out -Encoding utf8

        $out = & docker scout cves --format only-packages --only-severity critical,high $Image 2>&1 | Out-String
        Set-Content -LiteralPath $pkg -Value $out -Encoding utf8
    } finally {
        $env:NO_COLOR = $prevNoColor
    }

    Log-Info ("Saved: {0}/{1}-{{quickview,cves-critical-high,pkgs-critical-high}}.txt" -f $RunDir, $Prefix)
}

# Strip ANSI/CSI/OSC escape sequences. Belt and braces in case scout
# (or some future plugin) ignores NO_COLOR and writes colors anyway.
function global:Remove-AnsiEscapes {
    param([string]$Text)
    if (-not $Text) { return '' }
    # CSI: ESC[ ... letter        OSC: ESC] ... BEL/ST       2-byte ESC X
    $pattern = "(`e\[[0-9;?]*[ -/]*[@-~])|(`e\][^`a]*(`a|`e\\))|(`e[@-Z\\-_])"
    return [regex]::Replace($Text, $pattern, '')
}

# Parse a quickview file into "<crit>:<high>". Token-walking matches the
# bash version's awk: scan whitespace-separated fields for an "<N>C" token
# immediately followed by an "<N>H" token. This is robust to format drift
# (different separators, padding, ANSI residue, codepage substitutions for
# the box-drawing pipe, etc.).
function global:Get-ScoutCounts {
    param([Parameter(Mandatory)] [string]$QuickviewPath)
    if (-not (Test-Path -LiteralPath $QuickviewPath)) { return '?:?' }
    $clean = Remove-AnsiEscapes (Get-Content -LiteralPath $QuickviewPath -Raw)
    foreach ($line in ($clean -split "`r?`n")) {
        if ($line -notmatch 'Target') { continue }
        # Replace any non-alphanumeric run with a single space so "│" / "|"
        # / multiple spaces collapse cleanly, then split.
        $tokens = ($line -replace '[^A-Za-z0-9:.\-/]+',' ').Trim() -split '\s+'
        for ($i = 0; $i -lt $tokens.Length - 1; $i++) {
            if ($tokens[$i] -match '^([0-9]+)C$' -and $tokens[$i+1] -match '^([0-9]+)H$') {
                $c = ($tokens[$i]   -replace 'C$','')
                $h = ($tokens[$i+1] -replace 'H$','')
                return ('{0}:{1}' -f $c, $h)
            }
        }
    }
    return '?:?'
}

# --- policy gate ------------------------------------------------------------
# Returns 'PASS:...', 'FAIL:...' or 'UNKNOWN:...'.
function global:Test-Policy {
    param(
        [Parameter(Mandatory)] [string]$Crit,
        [Parameter(Mandatory)] [string]$High
    )
    if ($Crit -eq '?' -or $High -eq '?') { return "UNKNOWN: scout output unparseable" }

    $cMax = [int]$env:POLICY_MAX_CRITICAL
    if ([int]$Crit -gt $cMax) {
        return ("FAIL: {0} Critical > {1}" -f $Crit, $cMax)
    }
    if ($env:POLICY_MAX_HIGH -ne '') {
        $hMax = [int]$env:POLICY_MAX_HIGH
        if ([int]$High -gt $hMax) {
            return ("FAIL: {0} High > {1}" -f $High, $hMax)
        }
    }
    return ("PASS: {0}C / {1}H within policy" -f $Crit, $High)
}

# --- agent-server pin drift -------------------------------------------------
# Mirror of the Bash agent_server_drift / report_drift in lib.sh. Returns
# one of: 'IN_SYNC', 'DRIFT:<tag>', 'UNKNOWN'.
function global:Get-AgentServerDrift {
    $headers = @{ 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    try {
        $resp = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/OpenHands/software-agent-sdk/releases/latest' `
            -Headers $headers `
            -TimeoutSec 5 `
            -ErrorAction Stop
    } catch {
        return 'UNKNOWN'
    }
    $sdkTag = $resp.tag_name
    if (-not $sdkTag) { return 'UNKNOWN' }
    $expected = ($sdkTag -replace '^v','') + '-python'
    if ($expected -eq $env:AGENT_SERVER_BASE_TAG) { return 'IN_SYNC' }
    return ("DRIFT:{0}" -f $expected)
}

function global:Show-DriftBanner {
    $drift = Get-AgentServerDrift
    switch -Wildcard ($drift) {
        'IN_SYNC' {
            Log-Ok ("agent-server pin is on latest stable ({0})" -f $env:AGENT_SERVER_BASE_TAG)
        }
        'DRIFT:*' {
            $newer = $drift.Substring(6)
            Log-Warn ("agent-server pin DRIFT: current={0}  latest-stable={1}" -f $env:AGENT_SERVER_BASE_TAG, $newer)
            Log-Warn '  policy: track latest stable. Bump unless a known regression justifies holding.'
            Log-Warn '  to update: ./scripts/update.ps1 -Apply'
        }
        'UNKNOWN' {
            Log-Warn 'could not reach github.com to check pin drift (offline / rate-limited?)'
        }
    }
}
