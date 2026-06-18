#Requires -Version 5
<#
.SYNOPSIS
    Join the box to your Tailscale tailnet and publish Gitea on it via `tailscale serve`. Idempotent.
.DESCRIPTION
    Remote access to Gitea is over Tailscale: the box joins your tailnet with an auth key, 
    then `tailscale serve --bg 3000` publishes the loopback Gitea (http://127.0.0.1:3000) to the tailnet 
    over HTTPS at https://<machine>.<tailnet>.ts.net -- reachable only by devices on your tailnet, 
    never the LAN/WAN.

    Two things are set up ONCE in the Tailscale admin console (https://login.tailscale.com), out of
    band:
      1. Generate an AUTH KEY (Settings > Keys > Generate auth key). A reusable + pre-approved key
         keeps re-bootstrapping painless; tag it if you use ACL tags. Put it in secrets.ini (key
         TS_AUTHKEY; see secrets.example).
      2. Enable HTTPS Certificates (and MagicDNS) for the tailnet (DNS page). `tailscale serve` needs
         them to mint the https://...ts.net certificate. Without this, serve fails and this script
         WARNS (non-fatal): the box is still on the tailnet, just not yet serving Gitea over HTTPS.

    The auth key is a SECRET and is never committed. Update-Box.ps1 reads it from secrets.ini
    (key TS_AUTHKEY) and passes it in as -AuthKey. If it's blank (e.g. a throwaway sandbox), this
    script explains how to enable it and skips -- non-fatal, so the rest of the box still provisions.

    --unattended keeps the tailnet connection alive across logoff: this is a headless server box, and
    without it Windows drops Tailscale when no user is signed in.

    Assumes the 'tailscale' choco package is already installed (Update-Box.ps1 installs it from
    packages.config before calling this). Safe to re-run: an already-connected box leaves its session
    alone (re-running `up` could burn a single-use key), and `serve` just re-applies the same config.
#>

[CmdletBinding()]
param(
    [string]$AuthKey = '',
    [int]   $Port    = 3000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Tailscale-Setup.ps1 must run in an elevated PowerShell (joining the tailnet needs admin).'
}

function Resolve-TailscaleExe {
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # The Tailscale MSI installs here and adds it to PATH, but a freshly-installed session may not
    # have picked the PATH change up yet, so fall back to the known install location.
    $known = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $known) { return $known }
    throw "tailscale is not on PATH. Install the 'tailscale' choco package first (it's in packages.config)."
}
$tailscale = Resolve-TailscaleExe

# --- an auth key must be provided, else there's nothing to join ------------
if (-not $AuthKey) {
    Write-Warning "No Tailscale auth key provided; skipping Tailscale setup (the box still works locally)."
    Write-Host    "  To enable remote access: generate an auth key at https://login.tailscale.com/admin/settings/keys,"
    Write-Host    "  enable HTTPS Certificates + MagicDNS for the tailnet, then put the key in secrets.ini"
    Write-Host    "  (key TS_AUTHKEY; see secrets.example) and re-run Update-Box.ps1."
    return
}

# --- join the tailnet (skip if already connected) --------------------------
# Re-running `tailscale up` with a single-use auth key would fail once the key is spent, so we
# only join when the backend isn't already Running. ConvertFrom-Json can throw on empty/garbage
# output (daemon not ready, never logged in); the catch just leaves $alreadyUp false so we join.
$alreadyUp = $false
try {
    $status = & $tailscale status --json 2>$null | ConvertFrom-Json
    if ($status -and $status.BackendState -eq 'Running') { $alreadyUp = $true }
} catch { }

if ($alreadyUp) {
    Write-Host "[boxstrapper] Tailscale already connected; leaving the existing session alone." -ForegroundColor Green
} else {
    Write-Host "[boxstrapper] Joining the tailnet..." -ForegroundColor Cyan
    & $tailscale up --authkey $AuthKey --unattended
    if ($LASTEXITCODE -ne 0) { throw "tailscale up failed (exit code $LASTEXITCODE). Is the auth key valid and unexpired?" }
}

# --- publish Gitea on the tailnet over HTTPS -------------------------------
# Non-fatal on failure: `tailscale serve` needs HTTPS Certificates + MagicDNS enabled for the
# tailnet (an out-of-band admin-console setting), so a failure here shouldn't wedge the rest of
# Update-Box -- the box is still on the tailnet, only the HTTPS publish is pending.
Write-Host "[boxstrapper] Publishing Gitea (127.0.0.1:$Port) to the tailnet via 'tailscale serve'..." -ForegroundColor Cyan
& $tailscale serve --bg $Port
if ($LASTEXITCODE -ne 0) {
    Write-Warning "tailscale serve failed (exit code $LASTEXITCODE); Gitea is NOT yet published to the tailnet."
    Write-Host    "  Enable 'HTTPS Certificates' and MagicDNS for the tailnet at https://login.tailscale.com/admin/dns,"
    Write-Host    "  then re-run Update-Box.ps1. (The box is on the tailnet; only the HTTPS publish is pending.)"
    return
}

Write-Host "[boxstrapper] Tailscale ready -- Gitea is on the tailnet (run 'tailscale serve status' for the URL)." -ForegroundColor Green
