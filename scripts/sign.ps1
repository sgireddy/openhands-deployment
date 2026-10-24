<#
.SYNOPSIS
  Sign and/or verify the published hardened image digests with cosign.
  PowerShell port of scripts/sign.sh (behaviourally equivalent).

.DESCRIPTION
  Signs manifest-list DIGESTS (not tags) so signatures bind to immutable
  content. This script never generates or commits a private key — you own it.

  Key custody models:
    1. Keyed (default): local password-protected cosign key pair.
         cosign generate-key-pair      # cosign.key (PRIVATE, gitignored) + cosign.pub
       Commit ONLY cosign.pub.
    2. Keyless (OIDC/Fulcio): no local key; identity-bound, needs a browser.
         $env:SIGN_MODE="keyless"; ./scripts/sign.ps1 sign

.PARAMETER Action
  sign | verify

.NOTES
  Env: COSIGN_KEY (default cosign.key), COSIGN_PUB (default cosign.pub),
       COSIGN_PASSWORD, SIGN_MODE (keyed|keyless), DOCKER_CONFIG, IMAGES.
  Exit codes: 0 ok, 1 usage/tooling, 2 sign/verify failure.
#>
param([Parameter(Position = 0)][string]$Action = "")

$ErrorActionPreference = "Stop"
$SignMode  = if ($env:SIGN_MODE)  { $env:SIGN_MODE }  else { "keyed" }
$CosignKey = if ($env:COSIGN_KEY) { $env:COSIGN_KEY } else { "cosign.key" }
$CosignPub = if ($env:COSIGN_PUB) { $env:COSIGN_PUB } else { "cosign.pub" }
$Images    = if ($env:IMAGES) { $env:IMAGES -split '\s+' } else {
  @("docker.io/sgireddy/agent-server:custom_base-slim",
    "docker.io/sgireddy/openhands:custom_base-slim")
}

if (-not (Get-Command cosign -ErrorAction SilentlyContinue)) {
  Write-Error "cosign not found on PATH"; exit 1
}

function Resolve-Digest([string]$ref) {
  if ($ref -match '@sha256:') { return $ref }
  $repo = $ref.Substring(0, $ref.LastIndexOf(':'))
  $line = (docker buildx imagetools inspect $ref 2>$null | Select-String '^Digest:' | Select-Object -First 1)
  if (-not $line) { Write-Error "could not resolve digest for $ref"; return $null }
  $dig = ($line.ToString() -split '\s+')[1]
  return "$repo@$dig"
}

switch ($Action) {
  "sign" {
    $rc = 0
    foreach ($ref in $Images) {
      $target = Resolve-Digest $ref
      if (-not $target) { $rc = 2; continue }
      Write-Host ">>> signing $target"
      if ($SignMode -eq "keyless") {
        cosign sign --yes $target; if ($LASTEXITCODE -ne 0) { $rc = 2 }
      } else {
        if (-not (Test-Path $CosignKey)) { Write-Error "$CosignKey not found (run: cosign generate-key-pair)"; exit 1 }
        cosign sign --yes --key $CosignKey $target; if ($LASTEXITCODE -ne 0) { $rc = 2 }
      }
    }
    exit $rc
  }
  "verify" {
    $rc = 0
    foreach ($ref in $Images) {
      $target = Resolve-Digest $ref
      if (-not $target) { $rc = 2; continue }
      Write-Host ">>> verifying $target"
      if ($SignMode -eq "keyless") {
        Write-Host "   keyless verify needs --certificate-identity + --certificate-oidc-issuer"
        $rc = 2
      } else {
        if (-not (Test-Path $CosignPub)) { Write-Error "$CosignPub not found"; exit 1 }
        cosign verify --key $CosignPub $target *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host "   OK" } else { $rc = 2 }
      }
    }
    exit $rc
  }
  default {
    Write-Error "Usage: sign.ps1 {sign|verify} (see header for env/key-custody notes)"
    exit 1
  }
}
