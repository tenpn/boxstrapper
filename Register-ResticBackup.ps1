#Requires -Version 5
<#
.SYNOPSIS
    Register a SYSTEM scheduled task that runs a restic -> Cloudflare R2 backup worker, and ensure the
    (shared) restic repo exists. Idempotent. Shared by Gitea and Jenkins.
.DESCRIPTION
    The service-agnostic half of the backup setup: Gitea-Setup.ps1 and Jenkins-Setup.ps1 each call this
    with their own worker / task name / schedule -- the way they both call Healthchecks-Setup.ps1 for
    their heartbeat. It:
      - initialises the restic repo on R2 if absent (Initialize-ResticRepo, which also validates the R2
        creds + RESTIC_PASSWORD end to end before scheduling). The repo is SHARED by both services, so on
        a box that already has the other service's backups this just confirms the repo exists; it
        self-inits on a single-service box.
      - registers a SYSTEM scheduled task (-Daily or -Weekly) that runs -Worker with ONLY the secrets.ini
        PATH baked into its argument -- never the R2 keys / restic password (a task argument is stored in
        plaintext in the registry). The worker re-reads secrets.ini at run time.

    SECRETS: the R2 keys + restic password arrive as params (Update-Box.ps1 -> each service's *-Setup.ps1
    -> here) and are used ONLY here, at provision time, to init/validate the repo. Blank (e.g. a throwaway
    sandbox) => this explains how to enable backups and skips, non-fatal.

    Shared plumbing (Set-ResticEnv / Initialize-ResticRepo / Clear-ResticEnv) lives in Backup-Common.ps1.
    The per-service worker (gitea\Backup-Gitea.ps1 / jenkins\Backup-Jenkins.ps1) owns the actual
    dump/tree + forget policy. To rotate creds or change the schedule: edit secrets.ini (or the caller's
    params) and re-run Update-Box.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskName,
    # Absolute path to the backup worker the task runs (gitea\Backup-Gitea.ps1 / jenkins\Backup-Jenkins.ps1).
    [Parameter(Mandatory)][string]$Worker,
    # Absolute path to secrets.ini, baked into the task argument (a path, not a secret). Blank => repo root.
    [string]$SecretsFile    = '',
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = '',
    [ValidateSet('Daily','Weekly')][string]$Schedule = 'Daily',
    [string]$DayOfWeek      = 'Sunday',   # used only when -Schedule Weekly
    [string]$RunAt          = '03:00'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Backup-Common.ps1')

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Register-ResticBackup.ps1 must run in an elevated PowerShell (registering a SYSTEM scheduled task needs admin).'
}

# --- backup must be configured, else there's nothing to schedule ------------
if (-not $R2AccountId -or -not $R2Bucket -or -not $R2AccessKeyId -or -not $R2SecretKey -or -not $ResticPassword) {
    Write-Warning "Cloudflare R2 / restic backup not configured; skipping backup task '$TaskName' (the box still works)."
    Write-Host    "  To enable: create an R2 bucket + a scoped R2 API token, choose a restic password, then fill"
    Write-Host    "  R2_ACCOUNT_ID / R2_BUCKET / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / RESTIC_PASSWORD in"
    Write-Host    "  secrets.ini (see secrets.example) and re-run Update-Box.ps1."
    Write-Host    "  Keep RESTIC_PASSWORD escrowed off-box too -- without it the backups are unrecoverable."
    return
}

if (-not $SecretsFile) { $SecretsFile = Join-Path $PSScriptRoot 'secrets.ini' }   # repo root
if (-not (Test-Path -LiteralPath $SecretsFile)) { throw "Secrets file not found ($SecretsFile)." }
$SecretsFile = (Resolve-Path -LiteralPath $SecretsFile).Path   # absolute, for the SYSTEM task

if (-not (Test-Path -LiteralPath $Worker)) { throw "Backup worker not found ($Worker)." }
$Worker = (Resolve-Path -LiteralPath $Worker).Path

# --- locate restic + ensure the (shared) repo exists ------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH. Install the 'restic' choco package first (it's in packages.config)." }
$restic = $resticCmd.Source

Set-ResticEnv -R2AccountId $R2AccountId -R2Bucket $R2Bucket -R2AccessKeyId $R2AccessKeyId `
              -R2SecretKey $R2SecretKey -ResticPassword $ResticPassword
try {
    Initialize-ResticRepo -ResticExe $restic
} finally {
    Clear-ResticEnv   # don't leave secrets in the provisioning shell after we're done initialising
}

# --- (re)register the backup task (idempotent via -Force) -------------------
# Runs as SYSTEM. The argument carries ONLY the secrets.ini PATH; the worker reads the creds at run time.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Worker`" -SecretsFile `"$SecretsFile`""
if ($Schedule -eq 'Weekly') {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At ([datetime]$RunAt)
    $when    = "weekly, $DayOfWeek at $RunAt"
} else {
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]$RunAt)
    $when    = "daily at $RunAt"
}
# Run whether or not anyone is logged in; don't let battery state suppress it; and skip a run rather
# than stack a second copy if one overruns.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[boxstrapper] Backup task '$TaskName' registered ($when)." -ForegroundColor Green
Write-Host "[boxstrapper] Worker: $Worker" -ForegroundColor DarkGray
Write-Host "[boxstrapper] Test it now with: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
