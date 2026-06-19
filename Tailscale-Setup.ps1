#Requires -Version 5
<#
.SYNOPSIS
    Join the box to your Tailscale tailnet and reset `tailscale serve` to a clean slate. Idempotent.
.DESCRIPTION
    Remote access is over Tailscale. This script does just the SHARED substrate: it joins the box to
    your tailnet with an auth key, then resets the `tailscale serve` config so the published surface is
    empty. It does NOT publish any service itself -- each service owns its own routing: Gitea-Setup.ps1
    publishes Gitea at /git (and sets its ROOT_URL from this box's MagicDNS name), and Jenkins-Setup.ps1
    publishes Jenkins at /jenkins. Update-Box.ps1 runs THIS script BEFORE those two on purpose, so the
    box is on the tailnet and its public name exists by the time they publish themselves.

    Two things are set up ONCE in the Tailscale admin console (https://login.tailscale.com), out of
    band:
      1. Generate an AUTH KEY (Settings > Keys > Generate auth key). A reusable + pre-approved key
         keeps re-bootstrapping painless; tag it if you use ACL tags. Put it in secrets.ini (key
         TS_AUTHKEY; see secrets.example).
      2. Enable HTTPS Certificates (and MagicDNS) for the tailnet (DNS page). `tailscale serve` needs
         them to mint the https://...ts.net certificate. Without this, the per-service serve steps fail
         (non-fatal): the box is still on the tailnet, just not yet serving over HTTPS.

    The auth key is a SECRET and is never committed. Update-Box.ps1 reads it from secrets.ini
    (key TS_AUTHKEY) and passes it in as -AuthKey. If it's blank (e.g. a throwaway sandbox), this
    script explains how to enable it and skips -- non-fatal, so the rest of the box still provisions
    (and the service scripts detect "not on the tailnet" and stay loopback-only).

    --unattended keeps the tailnet connection alive across logoff: this is a headless server box, and
    without it Windows drops Tailscale when no user is signed in.

    Assumes the 'tailscale' choco package is already installed (Update-Box.ps1 installs it from
    packages.config before calling this). Safe to re-run: an already-connected box leaves its session
    alone (re-running `up` could burn a single-use key); the reset then re-clears the surface, which the
    service scripts re-populate right after.
#>

[CmdletBinding()]
param(
    [string]$AuthKey = ''
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

# --- reset the published `serve` surface to a clean slate ------------------
# `tailscale serve` config is sticky: an earlier run -- or an older boxstrapper that published Gitea at
# the ROOT (`serve --bg 3000`) -- leaves stale mounts behind. We reset here, then Gitea-Setup.ps1 and
# Jenkins-Setup.ps1 (which run AFTER this) each re-add their own mount, so the published surface always
# equals exactly what the service scripts declare this run -- no stale routes survive. Best-effort: a
# reset failure (e.g. nothing configured yet) must not wedge provisioning, and native non-zero exits
# don't throw under $ErrorActionPreference anyway.
Write-Host "[boxstrapper] Resetting 'tailscale serve' (services re-publish themselves next)..." -ForegroundColor Cyan
& $tailscale serve reset 2>$null

Write-Host "[boxstrapper] Tailscale ready -- box is on the tailnet; serve surface cleared for the service scripts." -ForegroundColor Green
