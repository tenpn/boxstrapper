#Requires -Version 5
<#
.SYNOPSIS
    Heartbeat Healthchecks.io after confirming Gitea is serving locally. Best-effort.
.DESCRIPTION
    Run on a schedule (every few minutes) by the task that Healthchecks-Setup.ps1
    registers. Probes Gitea's local health endpoint and reports to Healthchecks.io:
      - healthy           -> ping the success URL  (<ping-url>)
      - unhealthy         -> ping the failure URL  (<ping-url>/fail)  [box up, Gitea down]
      - task never ran    -> no ping at all; Healthchecks raises "down" after the grace
                             period                                   [box/power/scheduler dead]
    So a missed ping and a /fail ping mean different things: dead box vs crashed Gitea.

    The ping URL is a secret-ish token (anyone with it can keep your check green), so it
    is never committed. It is read from, in order:
      1. $env:HC_PING_URL
      2. a local file (default C:\ProgramData\boxstrapper\hc-ping-url.txt)
    NOTE: the scheduled task runs as SYSTEM and will NOT see an env var from your
    interactive shell -- in practice the file is the source. Healthchecks-Setup.ps1
    persists the URL there for exactly this reason.

    A heartbeat must never take the box down, so every failure here is swallowed and logged.
#>

[CmdletBinding()]
param(
    [string]$UrlFile    = (Join-Path $env:ProgramData 'boxstrapper\hc-ping-url.txt'),
    [string]$HealthUrl  = 'http://localhost:3000/api/healthz',
    [int]   $TimeoutSec = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- resolve the ping URL (a secret; never in the repo) ---------------------
$pingUrl = $env:HC_PING_URL
if (-not $pingUrl -and (Test-Path $UrlFile)) {
    $pingUrl = (Get-Content $UrlFile -Raw).Trim()
}
if (-not $pingUrl) {
    Write-Warning "No Healthchecks ping URL found (env:HC_PING_URL or $UrlFile); nothing to send."
    return
}
$pingUrl = $pingUrl.TrimEnd('/')

# --- probe Gitea locally ----------------------------------------------------
# A 200 from /api/healthz is the real "Gitea is serving" signal. Any non-200 or a
# connection error (service stopped, crash-looping under nssm) lands in catch -> unhealthy.
$healthy = $false
$detail  = ''
try {
    $resp    = Invoke-WebRequest $HealthUrl -UseBasicParsing -TimeoutSec $TimeoutSec
    $healthy = ($resp.StatusCode -eq 200)
    $detail  = "HTTP $($resp.StatusCode) $($resp.Content)"
} catch {
    $detail = $_.Exception.Message
    if ($_.Exception.Response) {
        $detail = "HTTP $([int]$_.Exception.Response.StatusCode) $detail"
    }
}

# --- report to Healthchecks (best-effort) -----------------------------------
# Healthchecks stores the last few ping bodies as a log, so include the probe detail
# (trimmed) to make "why did it fail" visible in the dashboard.
$target = if ($healthy) { $pingUrl } else { "$pingUrl/fail" }
$status = if ($healthy) { 'up' }     else { 'fail' }
$body   = if ($detail.Length -gt 1000) { $detail.Substring(0, 1000) } else { $detail }
try {
    Invoke-RestMethod -Uri $target -Method Post -Body $body -TimeoutSec $TimeoutSec | Out-Null
    Write-Host "[boxstrapper] Heartbeat sent ($status): $target"
} catch {
    Write-Warning "[boxstrapper] Heartbeat ping to $target failed: $($_.Exception.Message)"
}
