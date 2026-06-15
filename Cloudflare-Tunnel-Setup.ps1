#Requires -Version 5
<#
.SYNOPSIS
    Install the Cloudflare Tunnel connector (cloudflared) as a Windows service. Idempotent.
.DESCRIPTION
    Uses a REMOTE-MANAGED tunnel: create the tunnel once in the Cloudflare Zero Trust
    dashboard (Networks > Tunnels), route your hostname to http://localhost:3000, and
    copy the connector TOKEN. The hostname->service routing lives in Cloudflare, so this
    box only needs the token -- nothing else to configure locally.

    The token is a SECRET and is never committed to the repo. Update-Box.ps1 reads it from
    secrets.ini (key CF_TUNNEL_TOKEN; see secrets.example) and passes it in as -Token. If it's
    blank (e.g. a throwaway sandbox), the script explains how to enable it and skips -- non-fatal,
    so the rest of the box still provisions.

    Assumes the 'cloudflared' choco package is already installed (Update-Box.ps1 installs
    it from packages.config before calling this). Safe to re-run.
#>

[CmdletBinding()]
param(
    [string]$Token = ''
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

# --- a connector token must be provided, else there's nothing to install ----
if (-not $Token) {
    Write-Warning "No Cloudflare Tunnel token provided; skipping tunnel setup (the box still works locally)."
    Write-Host    "  To enable remote access: create a tunnel at https://one.dash.cloudflare.com"
    Write-Host    "  (Networks > Tunnels), route your hostname to http://localhost:3000, then put the"
    Write-Host    "  connector token in secrets.ini (key CF_TUNNEL_TOKEN; see secrets.example) and re-run Update-Box.ps1."
    return
}

# --- install the connector as a service (idempotent) ------------------------
if (Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue) {
    Write-Host "[boxstrapper] cloudflared service already installed." -ForegroundColor Green
} else {
    Write-Host "[boxstrapper] Installing Cloudflare Tunnel connector service..." -ForegroundColor Cyan
    # 'service install <token>' registers AND starts the cloudflared Windows service.
    & $cloudflared service install $Token
    if ($LASTEXITCODE -ne 0) { throw "cloudflared service install failed (exit code $LASTEXITCODE)." }
}

# --- ensure it's running ----------------------------------------------------
$svc = Get-Service -Name 'cloudflared' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Write-Host "[boxstrapper] Starting cloudflared..." -ForegroundColor Cyan
    Start-Service -Name 'cloudflared'
}

Write-Host "[boxstrapper] Cloudflare Tunnel connector ready." -ForegroundColor Green
