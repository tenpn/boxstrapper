#Requires -Version 5
<#
.SYNOPSIS
    Register a scheduled task that heartbeats Healthchecks.io every few minutes. Idempotent.
.DESCRIPTION
    Healthchecks.io is a dead-man's-switch monitor: the box pings a unique URL on a
    schedule, and if a ping is missed (box down, power loss, scheduler stopped) Healthchecks
    raises an alert. Send-Heartbeat.ps1 (run by this task) also probes Gitea locally and
    signals /fail when the box is up but Gitea isn't -- so "box dead" and "Gitea crashed"
    look different in the dashboard.

    This COMPLEMENTS, and does not replace, an external poll of your public hostname: the
    heartbeat proves the box+Gitea are alive; only an outside check of https://<host> proves
    the Cloudflare Tunnel path is actually reachable end to end.

    The ping URL is a secret-ish token; it is never committed. Create a check at
    https://healthchecks.io (set its period to match -IntervalMin, plus a little grace), copy
    its ping URL into secrets.ini (key HC_PING_URL; see secrets.example), and Update-Box.ps1
    passes it in as -PingUrl. The SYSTEM task can't see a shell env var, so this script bakes
    the URL into the scheduled task's argument (Send-Heartbeat.ps1 -PingUrl <url>) -- that is the
    run-time source. If -PingUrl is blank (e.g. a throwaway sandbox), it explains how to enable
    it and skips -- non-fatal, so the rest of the box still provisions.

    Assumes Send-Heartbeat.ps1 sits next to this script (it does, in the repo).
#>

[CmdletBinding()]
param(
    [string]$TaskName    = 'boxstrapper-heartbeat',
    [string]$PingUrl     = '',
    [int]   $IntervalMin = 5
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
    Write-Warning "No Healthchecks ping URL provided; skipping heartbeat setup (the box still works)."
    Write-Host    "  To enable: create a check at https://healthchecks.io (period $IntervalMin min + grace),"
    Write-Host    "  copy its ping URL into secrets.ini (key HC_PING_URL; see secrets.example), then re-run Update-Box.ps1."
    return
}

$heartbeat = Join-Path $PSScriptRoot 'Send-Heartbeat.ps1'
if (-not (Test-Path $heartbeat)) { throw "Send-Heartbeat.ps1 not found next to this script ($heartbeat)." }

# --- (re)register the scheduled task (idempotent via -Force) ----------------
# The task runs as SYSTEM and won't inherit a shell env var, so the URL is baked into the task's
# argument (Send-Heartbeat.ps1 reads it from -PingUrl). secrets.ini stays the single source; this
# is a derived copy, refreshed whenever you re-run Update-Box.ps1.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$heartbeat`" -PingUrl `"$PingUrl`""
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
Write-Host "[boxstrapper] Heartbeat task '$TaskName' registered (every $IntervalMin min)." -ForegroundColor Green

# Fire one now so the check goes green immediately and a bad URL surfaces right away.
Start-ScheduledTask -TaskName $TaskName
Write-Host "[boxstrapper] Kicked off an immediate heartbeat." -ForegroundColor DarkGray
