#Requires -Version 5
<#
.SYNOPSIS
    Install the Cloudflare Tunnel connector (cloudflared) as a Windows service. Idempotent.
.DESCRIPTION
    Uses a REMOTE-MANAGED tunnel: create the tunnel once in the Cloudflare Zero Trust
    dashboard (Networks > Tunnels), route your hostname to http://localhost:3000, and
    copy the connector TOKEN. The hostname->service routing lives in Cloudflare, so this
    box only needs the token -- nothing else to configure locally.

    The token is a SECRET and is never committed to the repo. It is read from, in order:
      1. $env:CF_TUNNEL_TOKEN
      2. a local file (default C:\ProgramData\boxstrapper\cf-tunnel-token.txt)
    If neither is present (e.g. a throwaway sandbox), the script explains how to enable
    it and skips -- non-fatal, so the rest of the box still provisions.

    Assumes the 'cloudflared' choco package is already installed (Update-Box.ps1 installs
    it from packages.config before calling this). Safe to re-run.
#>

[CmdletBinding()]
param(
    [string]$TokenFile = (Join-Path $env:ProgramData 'boxstrapper\cf-tunnel-token.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Cloudflare-Tunnel-Setup.ps1 must run in an elevated PowerShell (installing a service needs admin).'
}

$cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cfCmd) { throw "cloudflared is not on PATH. Install the 'cloudflared' choco package first (it's in packages.config)." }
$cloudflared = $cfCmd.Source

# --- resolve the connector token (a secret; never in the repo) --------------
$token = $env:CF_TUNNEL_TOKEN
if (-not $token -and (Test-Path $TokenFile)) {
    $token = (Get-Content $TokenFile -Raw).Trim()
}
if (-not $token) {
    Write-Warning "No Cloudflare Tunnel token found; skipping tunnel setup (the box still works locally)."
    Write-Host    "  To enable remote access: create a tunnel at https://one.dash.cloudflare.com"
    Write-Host    "  (Networks > Tunnels), route your hostname to http://localhost:3000, then put the"
    Write-Host    "  connector token in `$env:CF_TUNNEL_TOKEN or $TokenFile and re-run Update-Box.ps1."
    return
}

# --- install the connector as a service (idempotent) ------------------------
if (Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue) {
    Write-Host "[boxstrapper] cloudflared service already installed." -ForegroundColor Green
} else {
    Write-Host "[boxstrapper] Installing Cloudflare Tunnel connector service..." -ForegroundColor Cyan
    # 'service install <token>' registers AND starts the cloudflared Windows service.
    & $cloudflared service install $token
    if ($LASTEXITCODE -ne 0) { throw "cloudflared service install failed (exit code $LASTEXITCODE)." }
}

# --- ensure it's running ----------------------------------------------------
$svc = Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Write-Host "[boxstrapper] Starting cloudflared..." -ForegroundColor Cyan
    Start-Service -Name 'cloudflared'
}

Write-Host "[boxstrapper] Cloudflare Tunnel connector ready." -ForegroundColor Green
