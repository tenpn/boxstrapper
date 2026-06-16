#Requires -Version 5
<#
.SYNOPSIS
    Register a daily SYSTEM task that backs up Gitea to Cloudflare R2 via restic. Idempotent.
.DESCRIPTION
    Sets up an offsite, encrypted backup for the Gitea box:
      - initialises a restic repository on Cloudflare R2 (only if it doesn't exist yet), which also
        validates the R2 credentials + RESTIC_PASSWORD end to end before scheduling anything;
      - registers a daily scheduled task (as SYSTEM) that runs Backup-Gitea.ps1, which does
        gitea dump -> restic backup -> forget/prune -> local trim -> Healthchecks ping.

    Cloudflare R2 is the offsite store (10 GB free tier, zero egress, S3-compatible) -- it reuses the
    same Cloudflare account as the tunnel. A personal Gitea dump comfortably fits the free tier.

    SECRETS: the R2 keys + restic password arrive as params (Update-Box.ps1 parses them out of
    secrets.ini, same pattern as the other setup steps) -- this script needs them at provision time to
    `restic init`. The scheduled task, however, is handed ONLY the path to secrets.ini, never the
    secret values: a task argument is stored in plaintext in the registry, and an ACL'd derived creds
    file would add a file to keep in sync without real protection (secrets.ini is already plaintext on
    the box). Backup-Gitea.ps1 therefore re-reads secrets.ini at run time. If the R2/restic creds are
    blank (e.g. a throwaway sandbox), this script explains how to enable backups and skips -- non-fatal,
    so the rest of the box still provisions.

    To rotate creds or change the schedule: edit secrets.ini (or the params) and re-run Update-Box.ps1.
    Assumes restic (choco package) is installed and Backup-Gitea.ps1 sits next to this script.
#>

[CmdletBinding()]
param(
    [string]$TaskName       = 'boxstrapper-gitea-backup',
    # Absolute path to secrets.ini, baked into the task argument (a path, not a secret).
    [string]$SecretsFile    = '',
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = '',
    [string]$StagingDir     = 'C:\gitea\backup\staging',
    [string]$RunAt          = '03:00'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Gitea-Backup-Setup.ps1 must run in an elevated PowerShell (registering a SYSTEM scheduled task needs admin).'
}

# --- backup must be configured, else there's nothing to schedule ------------
if (-not $R2AccountId -or -not $R2Bucket -or -not $R2AccessKeyId -or -not $R2SecretKey -or -not $ResticPassword) {
    Write-Warning "Cloudflare R2 / restic backup not configured; skipping backup setup (the box still works)."
    Write-Host    "  To enable: create an R2 bucket + a scoped R2 API token, choose a restic password, then fill"
    Write-Host    "  R2_ACCOUNT_ID / R2_BUCKET / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / RESTIC_PASSWORD in"
    Write-Host    "  secrets.ini (see secrets.example) and re-run Update-Box.ps1."
    Write-Host    "  Keep RESTIC_PASSWORD escrowed off-box too -- without it the backups are unrecoverable."
    return
}

if (-not $SecretsFile) { $SecretsFile = Join-Path $PSScriptRoot 'secrets.ini' }
if (-not (Test-Path -LiteralPath $SecretsFile)) { throw "Secrets file not found ($SecretsFile)." }
$SecretsFile = (Resolve-Path -LiteralPath $SecretsFile).Path   # absolute, for the SYSTEM task

$worker = Join-Path $PSScriptRoot 'Backup-Gitea.ps1'
if (-not (Test-Path $worker)) { throw "Backup-Gitea.ps1 not found next to this script ($worker)." }

if (-not (Test-Path -LiteralPath $StagingDir)) {
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
}

# --- locate restic ----------------------------------------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH. Install the 'restic' choco package first (it's in packages.config)." }
$restic = $resticCmd.Source

# --- initialise the restic repo on R2 (only if absent) ----------------------
# restic refuses to re-init an existing repo, so probe with 'cat config' first. This call also proves
# the R2 creds + password work before we schedule anything. Env is process-scoped only.
$env:RESTIC_REPOSITORY     = "s3:https://$R2AccountId.r2.cloudflarestorage.com/$R2Bucket"
$env:RESTIC_PASSWORD       = $ResticPassword
$env:AWS_ACCESS_KEY_ID     = $R2AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $R2SecretKey
$env:AWS_DEFAULT_REGION    = 'auto'

$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $restic cat config 2>&1 | Out-Null
$repoExists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $eap

if ($repoExists) {
    Write-Host "[boxstrapper] restic repo already initialised at $($env:RESTIC_REPOSITORY)." -ForegroundColor Green
} else {
    Write-Host "[boxstrapper] Initialising restic repo at $($env:RESTIC_REPOSITORY)..." -ForegroundColor Cyan
    & $restic init
    if ($LASTEXITCODE -ne 0) { throw "restic init failed (exit $LASTEXITCODE). Check the R2 creds/bucket and RESTIC_PASSWORD." }
    Write-Host "[boxstrapper] restic repo initialised." -ForegroundColor Green
}

# --- (re)register the daily backup task (idempotent via -Force) -------------
# Runs as SYSTEM (it can read Gitea's data + DB). The argument carries only the secrets.ini PATH,
# never the R2 keys/restic password -- Backup-Gitea.ps1 reads those from the file at run time.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$worker`" -SecretsFile `"$SecretsFile`""
$trigger   = New-ScheduledTaskTrigger -Daily -At ([datetime]$RunAt)
# Run whether or not anyone is logged in; don't let battery state suppress it; and skip a run rather
# than stack a second copy if one overruns.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[boxstrapper] Gitea backup task '$TaskName' registered (daily at $RunAt)." -ForegroundColor Green
Write-Host "[boxstrapper] Pipeline: gitea dump -> restic -> $($env:RESTIC_REPOSITORY)" -ForegroundColor DarkGray
Write-Host "[boxstrapper] Test it now with: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray

# Don't leave secrets in the provisioning shell's environment after we're done.
Remove-Item Env:RESTIC_PASSWORD, Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
