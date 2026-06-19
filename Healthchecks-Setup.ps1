#Requires -Version 5
<#
.SYNOPSIS
    Register a scheduled task that heartbeats Healthchecks.io for one service every few minutes.
    Idempotent and generic -- call once per service (Gitea, Jenkins, ...).
.DESCRIPTION
    Healthchecks.io is a dead-man's-switch monitor: the box pings a unique URL on a
    schedule, and if a ping is missed (box down, power loss, scheduler stopped) Healthchecks
    raises an alert. Send-Heartbeat.ps1 (run by this task) also probes the service at -HealthUrl
    locally and signals /fail when the box is up but that service isn't -- so "box dead" and
    "<service> crashed" look different in the dashboard.

    This script is service-agnostic: each call registers its OWN task (-TaskName) that probes its
    OWN endpoint (-HealthUrl) and pings its OWN check (-PingUrl). Update-Box.ps1 calls it once for
    Gitea (defaults) and once for Jenkins. -Label tags the log lines; -SecretKey names the
    secrets.ini key in the skip hint.

    This COMPLEMENTS, and does not replace, an external poll of your public hostname: the
    heartbeat proves the box+service are alive; only an outside check of https://<host>.ts.net
    proves the Tailscale serve path is actually reachable end to end.

    The ping URL is a secret-ish token; it is never committed. Create a check at
    https://healthchecks.io (set its period to match -IntervalMin, plus a little grace), copy
    its ping URL into secrets.ini (key -SecretKey; see secrets.example), and Update-Box.ps1
    passes it in as -PingUrl. The SYSTEM task can't see a shell env var, so this script bakes
    both -PingUrl and -HealthUrl into the scheduled task's argument (Send-Heartbeat.ps1 ...) --
    that is the run-time source. If -PingUrl is blank (e.g. a throwaway sandbox), it explains how
    to enable it and skips -- non-fatal, so the rest of the box still provisions.

    Assumes Send-Heartbeat.ps1 sits next to this script (it does, in the repo).
#>

[CmdletBinding()]
param(
    [string]$TaskName    = 'boxstrapper-heartbeat',
    [string]$PingUrl     = '',
    [string]$HealthUrl   = 'http://localhost:3000/api/healthz',
    [string]$Label       = 'Gitea',
    [string]$SecretKey   = 'HC_GITEA_PING_URL',
    [int]   $IntervalMin = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Healthchecks-Setup.ps1 must run in an elevated PowerShell (registering a SYSTEM scheduled task needs admin).'
}

# --- a ping URL must be provided, else there's nothing to schedule ----------
if (-not $PingUrl) {
    Write-Warning "No Healthchecks ping URL provided; skipping $Label heartbeat setup (the box still works)."
    Write-Host    "  To enable: create a check at https://healthchecks.io (period $IntervalMin min + grace),"
    Write-Host    "  copy its ping URL into secrets.ini (key $SecretKey; see secrets.example), then re-run Update-Box.ps1."
    return
}

$heartbeat = Join-Path $PSScriptRoot 'Send-Heartbeat.ps1'
if (-not (Test-Path $heartbeat)) { throw "Send-Heartbeat.ps1 not found next to this script ($heartbeat)." }

# --- (re)register the scheduled task (idempotent via -Force) ----------------
# The task runs as SYSTEM and won't inherit a shell env var, so the URL (and the endpoint to probe)
# are baked into the task's argument (Send-Heartbeat.ps1 reads them from -PingUrl/-HealthUrl).
# secrets.ini stays the single source; this is a derived copy, refreshed on each Update-Box.ps1 run.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$heartbeat`" -PingUrl `"$PingUrl`" -HealthUrl `"$HealthUrl`" -Label `"$Label`""
# Empty RepetitionDuration => repeat indefinitely (verified on Win10/11; no MaxValue hack).
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
# Run whether or not anyone is logged in; don't let battery state suppress it; and skip a
# run rather than stack a second copy if one overruns.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[boxstrapper] $Label heartbeat task '$TaskName' registered (every $IntervalMin min, probing $HealthUrl)." -ForegroundColor Green

# Fire one now so the check goes green immediately and a bad URL surfaces right away.
Start-ScheduledTask -TaskName $TaskName
Write-Host "[boxstrapper] Kicked off an immediate heartbeat." -ForegroundColor DarkGray
