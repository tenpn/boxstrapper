#Requires -Version 5
<#
.SYNOPSIS
    Heartbeat Healthchecks.io after confirming a local service is serving. Best-effort, generic.
.DESCRIPTION
    Run on a schedule (every few minutes) by a task that Healthchecks-Setup.ps1 registers. This
    script is service-agnostic: it probes whatever -HealthUrl points at (Gitea's /api/healthz,
    Jenkins' /jenkins/login, etc.) and reports to Healthchecks.io:
      - healthy (HTTP 200) -> ping the success URL  (<ping-url>)
      - unhealthy          -> ping the failure URL  (<ping-url>/fail)  [box up, service down]
      - task never ran     -> no ping at all; Healthchecks raises "down" after the grace
                              period                                   [box/power/scheduler dead]
    So a missed ping and a /fail ping mean different things: dead box vs crashed service.
    -Label only tags the local/Healthchecks log lines so multiple heartbeats are distinguishable.

    The ping URL is a secret-ish token (anyone with it can keep your check green), so it is
    never committed. It arrives as -PingUrl: Healthchecks-Setup.ps1 bakes it (and -HealthUrl)
    into this task's argument (from secrets.ini) because the SYSTEM task can't see a shell env
    var. Re-run Update-Box.ps1 after editing secrets.ini to refresh it.

    A heartbeat must never take the box down, so every failure here is swallowed and logged.
#>

[CmdletBinding()]
param(
    [string]$PingUrl    = '',
    [string]$HealthUrl  = 'http://localhost:3000/api/healthz',
    [string]$Label      = 'Gitea',
    [int]   $TimeoutSec = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- a ping URL must be provided, else there's nothing to send --------------
if (-not $PingUrl) {
    Write-Warning "No Healthchecks ping URL provided (-PingUrl); nothing to send."
    return
}
$pingUrl = $PingUrl.TrimEnd('/')

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
    Write-Host "[boxstrapper] $Label heartbeat sent ($status): $target"
} catch {
    Write-Warning "[boxstrapper] $Label heartbeat ping to $target failed: $($_.Exception.Message)"
}
