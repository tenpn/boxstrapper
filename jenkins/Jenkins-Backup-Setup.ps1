#Requires -Version 5
<#
.SYNOPSIS
    Register a WEEKLY SYSTEM task that backs up JENKINS_HOME to Cloudflare R2 via restic. Idempotent.
.DESCRIPTION
    Sets up an offsite, encrypted backup of Jenkins:
      - initialises a restic repository on Cloudflare R2 (only if it doesn't exist yet), which also
        validates the R2 credentials + RESTIC_PASSWORD end to end before scheduling anything;
      - registers a WEEKLY scheduled task (as SYSTEM) that runs Backup-Jenkins.ps1, which does
        stop service -> restic backup <JENKINS_HOME> (tagged 'jenkins', artifacts excluded) -> restart
        -> forget/prune -> Healthchecks ping.

    SHARED REPO: Jenkins and Gitea use the SAME restic repo (same R2 bucket). The 'cat config' probe
    below therefore usually finds the repo already initialised by Gitea-Backup-Setup.ps1 and just skips
    init -- but it still self-inits on a Jenkins-only box, and always re-validates the R2 creds. Jenkins
    snapshots are tagged 'jenkins' so their retention never touches Gitea's (see Backup-Jenkins.ps1).

    WEEKLY, not daily like Gitea: Jenkins state (job configs, build records) churns far less than Gitea's
    repos, so a weekly snapshot is plenty. Staggered to 03:30, 30 min after Gitea's 03:00 daily run.

    SECRETS: the R2 keys + restic password arrive as params (Update-Box.ps1 parses them out of
    secrets.ini, same pattern as the other setup steps) -- this script needs them at provision time to
    `restic init`. The scheduled task, however, is handed ONLY the path to secrets.ini, never the secret
    values (a task argument is stored in plaintext in the registry); Backup-Jenkins.ps1 re-reads
    secrets.ini at run time. If the R2/restic creds are blank (e.g. a throwaway sandbox), this script
    explains how to enable backups and skips -- non-fatal, so the rest of the box still provisions.

    To rotate creds or change the schedule: edit secrets.ini (or the params) and re-run Update-Box.ps1.
    Assumes restic (choco package) is installed and Backup-Jenkins.ps1 sits next to this script.
#>

[CmdletBinding()]
param(
    [string]$TaskName       = 'boxstrapper-jenkins-backup',
    # Absolute path to secrets.ini, baked into the task argument (a path, not a secret).
    [string]$SecretsFile    = '',
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = '',
    [string]$DayOfWeek      = 'Sunday',   # weekly cadence (Jenkins churns less than Gitea)
    [string]$RunAt          = '03:30'     # staggered 30 min after Gitea's 03:00 daily run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Jenkins-Backup-Setup.ps1 must run in an elevated PowerShell (registering a SYSTEM scheduled task needs admin).'
}

# --- backup must be configured, else there's nothing to schedule ------------
if (-not $R2AccountId -or -not $R2Bucket -or -not $R2AccessKeyId -or -not $R2SecretKey -or -not $ResticPassword) {
    Write-Warning "Cloudflare R2 / restic backup not configured; skipping Jenkins backup setup (the box still works)."
    Write-Host    "  To enable: create an R2 bucket + a scoped R2 API token, choose a restic password, then fill"
    Write-Host    "  R2_ACCOUNT_ID / R2_BUCKET / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / RESTIC_PASSWORD in"
    Write-Host    "  secrets.ini (see secrets.example) and re-run Update-Box.ps1."
    Write-Host    "  Keep RESTIC_PASSWORD escrowed off-box too -- without it the backups are unrecoverable."
    return
}

if (-not $SecretsFile) { $SecretsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets.ini' }  # repo root, one level up from jenkins\
if (-not (Test-Path -LiteralPath $SecretsFile)) { throw "Secrets file not found ($SecretsFile)." }
$SecretsFile = (Resolve-Path -LiteralPath $SecretsFile).Path   # absolute, for the SYSTEM task

$worker = Join-Path $PSScriptRoot 'Backup-Jenkins.ps1'
if (-not (Test-Path $worker)) { throw "Backup-Jenkins.ps1 not found next to this script ($worker)." }

# --- locate restic ----------------------------------------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH. Install the 'restic' choco package first (it's in packages.config)." }
$restic = $resticCmd.Source

# --- initialise the restic repo on R2 (only if absent) ----------------------
# restic refuses to re-init an existing repo, so probe with 'cat config' first. This call also proves
# the R2 creds + password work before we schedule anything. The repo is SHARED with Gitea, so on a box
# with Gitea backups already set up this just confirms the repo exists. Env is process-scoped only.
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

# --- (re)register the weekly backup task (idempotent via -Force) ------------
# Runs as SYSTEM (it can read JENKINS_HOME + stop/start the service). The argument carries only the
# secrets.ini PATH, never the R2 keys/restic password -- Backup-Jenkins.ps1 reads those at run time.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$worker`" -SecretsFile `"$SecretsFile`""
$trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At ([datetime]$RunAt)
# Run whether or not anyone is logged in; don't let battery state suppress it; and skip a run rather
# than stack a second copy if one overruns.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[boxstrapper] Jenkins backup task '$TaskName' registered (weekly, $DayOfWeek at $RunAt)." -ForegroundColor Green
Write-Host "[boxstrapper] Pipeline: stop Jenkins -> restic backup (tag 'jenkins') -> $($env:RESTIC_REPOSITORY)" -ForegroundColor DarkGray
Write-Host "[boxstrapper] Test it now with: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray

# Don't leave secrets in the provisioning shell's environment after we're done.
Remove-Item Env:RESTIC_PASSWORD, Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
