#requires -version 5.1
<#
.SYNOPSIS
    Start the openhands web app from the locally hardened images
    produced by ..\scripts\build.ps1. Windows / PowerShell port of
    examples/run-openhands.sh.

.DESCRIPTION
    This is an *example* invocation script. It is not part of the build
    pipeline; it shows how to wire the two hardened images together at
    run time. Adapt freely.

.PARAMETER Port
    Host port to bind the UI on. Default: 3000.

.PARAMETER Model
    Model alias passed through to the container. Default is a
    placeholder — replace with your real one. The example shows the
    litellm-proxy syntax (provider/model). For a direct provider, use
    e.g. "anthropic/claude-sonnet-4-5" or "openai/gpt-4o".

.PARAMETER BaseUrl
    LLM base URL. Default points at a litellm proxy on the host. If you
    don't run a proxy, replace with the upstream provider URL or set it
    to an empty string and let openhands use its built-in defaults.

.PARAMETER DeployHome
    Parent dir for all runtime state and logs.
    Default: $HOME\openhands-deployment.
    Sub-paths created beneath it:
        $DeployHome\data\state
        $DeployHome\data\workspace
        $DeployHome\data\.openhands
        $DeployHome\openhands.log         (container stdout)
        $DeployHome\openhands.err.log     (container stderr)

.PARAMETER AgentServerRepo
    Repo of the hardened agent-server image. Default: agent-server.

.PARAMETER AgentServerTag
    Tag of the hardened agent-server image. Default: custom_base
    (matches build.ps1 output).

.NOTES
    REQUIRED ENV
        $env:OH_SECRET_KEY  — JWT signing key for openhands sessions
                              (any reasonably long random string).
                              Generate one once with:
                                  -join ((48..57)+(97..102) | Get-Random -Count 64 | % {[char]$_})
                              or:
                                  python -c "import secrets;print(secrets.token_hex(32))"

    PRIVILEGE NOTE
        This script bind-mounts the Docker Desktop docker socket into
        the openhands container. That gives the container effective
        root on the underlying Docker Desktop VM. This is required so
        openhands can spawn sandbox containers for each conversation.
        Don't run this on a machine where the openhands process is not
        trusted with full docker access.

    LOGGING NOTE
        LOG_LEVEL=DEBUG can record prompt/response payloads and may
        incidentally capture API keys or other secrets. The log files
        live under $DeployHome — outside the repo by default, so they
        can never accidentally be staged. Treat them as sensitive
        regardless of where they land.

.EXAMPLE
    $env:OH_SECRET_KEY = (python -c "import secrets;print(secrets.token_hex(32))")
    .\examples\run-openhands.ps1

.EXAMPLE
    .\examples\run-openhands.ps1 -Port 8080 -Model 'anthropic/claude-sonnet-4-5'
#>

[CmdletBinding()]
param(
    [int]    $Port             = 3000,
    [string] $Model            = 'litellm_proxy/your-model-alias',
    [string] $BaseUrl          = 'http://host.docker.internal:4000',
    [string] $DeployHome,
    [string] $AgentServerRepo  = 'agent-server',
    [string] $AgentServerTag   = 'custom_base'
)

$ErrorActionPreference = 'Stop'

# ----- configuration --------------------------------------------------------
$ContainerName = 'openhands'
$Image         = 'openhands:custom_base'   # built by ..\scripts\build.ps1

# Allow override via parameter or env var; otherwise default outside the repo.
# Mirror of $DEPLOY_HOME from the bash version.
if (-not $DeployHome) {
    $DeployHome = if ($env:DEPLOY_HOME) { $env:DEPLOY_HOME } else { Join-Path $HOME 'openhands-deployment' }
}
$DataDir = Join-Path $DeployHome 'data'
# Two log files because Start-Process refuses to redirect both streams to
# the same path. stdout has the bulk of useful logs; stderr is rarely
# populated by `docker logs -f` but kept separate so neither stream is
# silently dropped. To get a merged tail:
#   Get-Content $DeployHome\openhands.log, $DeployHome\openhands.err.log -Wait
$LogFile    = Join-Path $DeployHome 'openhands.log'
$LogFileErr = Join-Path $DeployHome 'openhands.err.log'

function Write-Status {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

# ----- pre-flight -----------------------------------------------------------
if ([string]::IsNullOrEmpty($env:OH_SECRET_KEY)) {
    Write-Status 'OH_SECRET_KEY is not set.' Red
    Write-Host  'Generate one with:'
    Write-Host  '  python -c "import secrets;print(secrets.token_hex(32))"'
    Write-Host  'or:'
    Write-Host  '  -join ((48..57)+(97..102) | Get-Random -Count 64 | % {[char]$_})'
    exit 1
}

# Docker Desktop must be running. `docker info` returns non-zero if the
# daemon is unreachable, which is the most common Windows-side failure
# mode (Docker Desktop not started, or stopped after a reboot).
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Status 'Docker is not reachable. Start Docker Desktop and try again.' Red
    exit 1
}

# Verify both hardened images are present.
foreach ($img in @($Image, "${AgentServerRepo}:${AgentServerTag}")) {
    & docker image inspect $img *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "image not found locally: $img" Red
        Write-Host  '  Run ..\scripts\build.ps1 first.'
        exit 1
    }
}

# ----- setup ----------------------------------------------------------------
foreach ($d in @(
        $DeployHome,
        $DataDir,
        (Join-Path $DataDir 'state'),
        (Join-Path $DataDir 'workspace'),
        (Join-Path $DataDir '.openhands')
    )) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Remove any prior container with the same name. Don't fail if absent.
& docker rm -f $ContainerName *> $null

# Stop any previously-detached `docker logs -f openhands` tailer started by
# a prior run. Match by command line. The pid-file pattern (below) is what
# we rely on for clean shutdown; this is just a belt-and-braces fallback
# for upgrade paths from older versions of the script.
$pidFile = Join-Path $DeployHome 'log-tailer.pid'
if (Test-Path -LiteralPath $pidFile) {
    $oldPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
}

# ----- launch ---------------------------------------------------------------
# NOTE: .openhands is mounted to BOTH /.openhands (for FILE_STORE_PATH
#       settings/secrets) AND /home/enduser/.openhands (where openhands.db
#       and v1_conversations are stored).
#
# AGENT_SERVER_IMAGE_REPOSITORY + AGENT_SERVER_IMAGE_TAG together tell
# openhands which agent-server image to spawn for each new sandbox.
# Both must be set or the resolver falls back to the upstream pinned
# default (ghcr.io/openhands/agent-server:<version>-python).
# See: openhands/app_server/sandbox/sandbox_spec_service.py:get_agent_server_image
#
# SANDBOX_USER_ID:
#   On Linux/macOS the bash port reads `id -u`. On Windows there is no
#   meaningful host UID to forward (Docker Desktop runs containers in a
#   Linux VM with translated bind mounts). 1000 is the conventional
#   default and matches the user inside the upstream agent-server image.
$dockerArgs = @(
    'run','-d','--restart','unless-stopped','--name', $ContainerName,
    '-p', "${Port}:3000",
    '-v', '/var/run/docker.sock:/var/run/docker.sock',
    '-v', "${DataDir}\state:/app/data",
    '-v', "${DataDir}\workspace:/opt/workspace_base",
    '-v', "${DataDir}\.openhands:/.openhands",
    '-v', "${DataDir}\.openhands:/home/enduser/.openhands",
    '-e', 'SANDBOX_USER_ID=1000',
    '-e', "OPENAI_BASE_URL=$BaseUrl",
    '-e', "OPENAI_MODEL=$Model",
    '-e', "OH_SECRET_KEY=$($env:OH_SECRET_KEY)",
    '-e', 'LOG_LEVEL=DEBUG',
    '-e', 'CONVERSATION_MAX_AGE_SECONDS=315360000',
    '-e', "AGENT_SERVER_IMAGE_REPOSITORY=$AgentServerRepo",
    '-e', "AGENT_SERVER_IMAGE_TAG=$AgentServerTag",
    $Image
)

# IMPORTANT: capture native stdout into a single scalar so it doesn't leak
# into the success stream — same pattern we use in build.ps1.
$containerId = (& docker @dockerArgs 2>&1 | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0) {
    Write-Status "Failed: $containerId" Red
    exit 1
}

# ----- detached log tailer --------------------------------------------------
# Start `docker logs -f openhands` in a hidden background process and
# record its PID so the next run (or a future stop script) can clean it up.
#
# -WindowStyle Hidden is a Windows-only parameter; we splat it
# conditionally so the script can also be smoke-tested on non-Windows
# editions of pwsh. On PowerShell 5.1 (Desktop) $IsWindows is undefined
# (and evaluates to $null/false), so we additionally treat the Desktop
# edition as Windows.
$startProcArgs = @{
    FilePath               = 'docker'
    ArgumentList           = @('logs', '-f', $ContainerName)
    RedirectStandardOutput = $LogFile
    RedirectStandardError  = $LogFileErr
    PassThru               = $true
}
$onWindows = $IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')
if ($onWindows) { $startProcArgs.WindowStyle = 'Hidden' }
$tailer = Start-Process @startProcArgs
Set-Content -LiteralPath $pidFile -Value $tailer.Id -Encoding ascii

# ----- summary --------------------------------------------------------------
Write-Status 'OpenHands backgrounded.' Green
Write-Host  ('UI:           http://localhost:{0}' -f $Port)
Write-Host  ('Web image:    {0}' -f $Image)
Write-Host  ('Sandbox img:  {0}:{1}' -f $AgentServerRepo, $AgentServerTag)
Write-Host  ('Logs (stdout): {0}' -f $LogFile)
Write-Host  ('Logs (stderr): {0}' -f $LogFileErr)
Write-Host  ('Tailer PID:    {0}  (stop with: Stop-Process -Id {0})' -f $tailer.Id)
Write-Host  ''
Write-Host  'Verify the sandbox image is being used by spawning a conversation'
Write-Host  'in the UI, then run:'
Write-Host  "  docker ps --filter name=oh-agent-server- --format '{{.Image}}'"
