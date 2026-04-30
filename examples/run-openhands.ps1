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

.PARAMETER InstanceName
    A unique name used to scope EVERY piece of per-instance state:
    container name, data dir, log files, pidfile. Default is
    "openhands-<Port>" so that running

        .\run-openhands.ps1 -Port 3010 -Model 'anthropic/claude-...'
        .\run-openhands.ps1 -Port 3020 -Model 'openai/gpt-...'

    in two different terminals leaves you with two simultaneous
    instances (openhands-3010 + openhands-3020) — different ports,
    different containers, different conversation DBs, no collisions.
    Override only if you want a friendlier name like "claude-prod".

.PARAMETER DeployHome
    Parent dir for all runtime state and logs.
    Default: $HOME\openhands-deployment.
    Sub-paths (one set per instance, scoped by InstanceName):
        $DeployHome\<InstanceName>\state
        $DeployHome\<InstanceName>\workspace
        $DeployHome\<InstanceName>\.openhands
        $DeployHome\<InstanceName>.log         (container stdout)
        $DeployHome\<InstanceName>.err.log     (container stderr)
        $DeployHome\<InstanceName>.pid         (log-tailer PID)

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

.EXAMPLE
    # Two simultaneous instances bound to different ports / models.
    # They get distinct container names, distinct data dirs, distinct logs.
    .\examples\run-openhands.ps1 -Port 3010 -Model 'anthropic/claude-sonnet-4-5'
    .\examples\run-openhands.ps1 -Port 3020 -Model 'openai/gpt-5'

    # ...then in another shell:
    docker ps --filter name=openhands-
    # CONTAINER ID   IMAGE                     ...   NAMES
    # abc123...      openhands:custom_base     ...   openhands-3010
    # def456...      openhands:custom_base     ...   openhands-3020
#>

[CmdletBinding()]
param(
    [int]    $Port             = 3000,
    [string] $Model            = 'litellm_proxy/your-model-alias',
    [string] $BaseUrl          = 'http://host.docker.internal:4000',
    [string] $InstanceName,
    [string] $DeployHome,
    [string] $AgentServerRepo  = 'agent-server',
    [string] $AgentServerTag   = 'custom_base'
)

$ErrorActionPreference = 'Stop'

# ----- configuration --------------------------------------------------------
$Image = 'openhands:custom_base'   # built by ..\scripts\build.ps1

# Per-instance scoping. Defaults to "openhands-<Port>" so that two runs on
# different ports get distinct container names + state automatically. The
# user can also pass a friendlier name like 'claude-prod' if they prefer.
# Sanity: dropping any character docker rejects in container names,
# leaving only what is actually allowed: [a-zA-Z0-9_.-]. This protects us
# if someone passes -InstanceName "openhands prod" or similar.
if (-not $InstanceName) {
    $InstanceName = "openhands-$Port"
}
# Reject up-front if the input contains zero docker-legal characters
# (alnum / _ / .), otherwise we'd silently produce a name made of only
# replacement dashes.
if ($InstanceName -notmatch '[a-zA-Z0-9_.]') {
    Write-Host "InstanceName '$InstanceName' has no valid characters [a-zA-Z0-9_.]; cannot continue." -ForegroundColor Red
    exit 1
}
# Substitute all illegal chars with '-', collapse runs of '-', strip
# leading/trailing '-'.
$InstanceName = ($InstanceName -replace '[^a-zA-Z0-9_.\-]', '-')
$InstanceName = ($InstanceName -replace '-+', '-').Trim('-')
$ContainerName = $InstanceName

# Allow override via parameter or env var; otherwise default outside the repo.
# Mirror of $DEPLOY_HOME from the bash version.
if (-not $DeployHome) {
    $DeployHome = if ($env:DEPLOY_HOME) { $env:DEPLOY_HOME } else { Join-Path $HOME 'openhands-deployment' }
}

# Per-instance data dir. Replaces the previous fixed "data/" path. Each
# instance gets its OWN state, workspace, and .openhands folder so that
# two simultaneous instances cannot corrupt each other's conversation
# DB or settings store.
#
# MIGRATION: existing single-instance users had everything under
# $DeployHome\data\{state,workspace,.openhands}. To preserve their
# history when moving to this version, rename that directory once:
#   Rename-Item "$DeployHome\data" "$DeployHome\openhands-3000"
$DataDir = Join-Path $DeployHome $InstanceName

# Two log files because Start-Process refuses to redirect both streams to
# the same path. stdout has the bulk of useful logs; stderr is rarely
# populated by `docker logs -f` but kept separate so neither stream is
# silently dropped. To get a merged tail:
#   Get-Content $DeployHome\<instance>.log, $DeployHome\<instance>.err.log -Wait
$LogFile    = Join-Path $DeployHome ("{0}.log"     -f $InstanceName)
$LogFileErr = Join-Path $DeployHome ("{0}.err.log" -f $InstanceName)
$pidFile    = Join-Path $DeployHome ("{0}.pid"     -f $InstanceName)

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

# Remove any prior container WITH THE SAME INSTANCE NAME. Don't fail if
# absent. This deliberately does NOT touch other instances — re-running
# `-Port 3010` only restarts openhands-3010 and leaves openhands-3020
# running.
& docker rm -f $ContainerName *> $null

# Stop the prior `docker logs -f` tailer for THIS instance only, by
# reading the per-instance pidfile written at the end of the previous
# run. $pidFile was already computed above as $DeployHome\<instance>.pid.
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
Write-Status ('{0} backgrounded.' -f $InstanceName) Green
Write-Host  ('Instance:      {0}' -f $InstanceName)
Write-Host  ('UI:            http://localhost:{0}' -f $Port)
Write-Host  ('Web image:     {0}' -f $Image)
Write-Host  ('Sandbox img:   {0}:{1}' -f $AgentServerRepo, $AgentServerTag)
Write-Host  ('Data dir:      {0}' -f $DataDir)
Write-Host  ('Logs (stdout): {0}' -f $LogFile)
Write-Host  ('Logs (stderr): {0}' -f $LogFileErr)
Write-Host  ('Tailer PID:    {0}  (stop with: Stop-Process -Id {0})' -f $tailer.Id)
Write-Host  ''
Write-Host  'Stop this instance only:'
Write-Host  ('  docker rm -f {0}' -f $InstanceName)
Write-Host  ('  Stop-Process -Id {0}' -f $tailer.Id)
Write-Host  ''
Write-Host  'List all instances launched by this script:'
Write-Host  "  docker ps --filter name=openhands- --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'"
Write-Host  ''
Write-Host  'Verify the sandbox image is being used by spawning a conversation'
Write-Host  'in the UI, then run:'
Write-Host  "  docker ps --filter name=oh-agent-server- --format '{{.Image}}'"
