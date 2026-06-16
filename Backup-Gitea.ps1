#Requires -Version 5
<#
.SYNOPSIS
    Dump Gitea and push an encrypted snapshot to Cloudflare R2 via restic. Best-effort, monitored.
.DESCRIPTION
    Run on a daily schedule (as SYSTEM) by the task that Gitea-Backup-Setup.ps1 registers. Pipeline:
      1. gitea dump            -> one consistent .zip (repos + SQLite DB + config + LFS + attachments)
      2. restic backup <.zip>  -> Cloudflare R2, client-side encrypted BEFORE upload
      3. restic forget --prune -> GFS retention (keep 7 daily / 4 weekly / 6 monthly)
      4. trim local staging    -> keep only the newest archive (a fast, no-network restore copy)
      5. ping Healthchecks.io  -> success URL on a clean run, <url>/fail (with a log tail) otherwise

    SECRETS -- why this worker reads secrets.ini directly:
    The R2 secret key and RESTIC_PASSWORD are NOT baked into the scheduled-task argument, because that
    argument is stored in plaintext in the Task Scheduler/registry. The task is handed only the PATH to
    secrets.ini (-SecretsFile), and this worker parses it at run time -- the same single source
    Update-Box.ps1 parses, with the same "value = everything after the first '='" rule. An ACL'd derived
    creds file was deliberately rejected: secrets.ini already sits in plaintext on the box, so an ACL'd
    copy adds a file to keep in sync without any real protection. Keys read here:
      R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, RESTIC_PASSWORD
      HC_BACKUP_PING_URL (optional -- a SEPARATE Healthchecks check from the box heartbeat)
    Blank R2/restic creds => pings /fail (if a URL is set) and exits; never throws.

    A backup must never wedge the box, so every stage is wrapped and any failure is reported to
    Healthchecks rather than thrown. Stays Windows PowerShell 5.1-safe (no ternary / null-coalescing)
    because the scheduled task launches powershell.exe, not pwsh.

    RESTORE (disaster runbook):
      1. Install restic and set these env vars (from secrets.ini):
           RESTIC_REPOSITORY  = s3:https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com/<R2_BUCKET>
           RESTIC_PASSWORD    = <RESTIC_PASSWORD>
           AWS_ACCESS_KEY_ID  = <R2_ACCESS_KEY_ID>
           AWS_SECRET_ACCESS_KEY = <R2_SECRET_ACCESS_KEY>
           AWS_DEFAULT_REGION = auto
      2. restic snapshots                                   # pick a snapshot id
         restic restore <id> --target C:\restore
      3. Unzip the recovered gitea-dump-*.zip, then follow Gitea's restore steps: stop the service,
         restore data/gitea.db + the repo dirs + custom/ + data/ into C:\gitea, start the service.
      4. restic check verifies repo integrity; do a periodic test-restore to prove recoverability.
      KEEP RESTIC_PASSWORD SAFE: without it the offsite backups are unrecoverable. Escrow a copy in a
      password manager off the box, not only in secrets.ini.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SecretsFile,
    [string]$WorkDir     = 'C:\gitea',
    [string]$StagingDir  = 'C:\gitea\backup\staging',
    [int]   $KeepDaily   = 7,
    [int]   $KeepWeekly  = 4,
    [int]   $KeepMonthly = 6,
    [int]   $KeepLocal   = 1,
    [int]   $TimeoutSec  = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Secrets {
    # Same parse as Update-Box.ps1: value = everything after the first '=' (so base64 tokens ending
    # in '==' survive); '#' comments and blank lines are ignored. This worker re-reads the single
    # source because a detached SYSTEM task can't be handed secrets as params safely (see header).
    param([Parameter(Mandatory)][string]$Path)
    $secrets = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $secrets[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $secrets
}

function Resolve-GiteaExe {
    # Point at the REAL gitea.exe, never the choco 'bin' shim (mirrors Gitea-Setup.ps1).
    if (-not $env:ChocolateyInstall) { $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey' }
    $direct = Join-Path $env:ChocolateyInstall 'lib\gitea\tools\gitea.exe'
    if (Test-Path $direct) { return (Resolve-Path $direct).Path }
    $libRoot = Join-Path $env:ChocolateyInstall 'lib'
    if (Test-Path $libRoot) {
        $hit = Get-ChildItem $libRoot -Recurse -Filter 'gitea.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\bin\\' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command gitea -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Could not locate gitea.exe. Is the 'gitea' choco package installed?"
}

function Invoke-Native {
    # Run a native exe, capturing combined stdout+stderr without letting native stderr trip
    # $ErrorActionPreference='Stop' (a real PS 5.1 gotcha). Caller checks .Code.
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

# --- read secrets directly (the SYSTEM task can't be handed them as params) --
if (-not (Test-Path -LiteralPath $SecretsFile)) {
    Write-Warning "[boxstrapper] Secrets file not found ($SecretsFile); cannot back up."
    return
}
$secrets = Read-Secrets -Path $SecretsFile
$pingUrl = ([string]$secrets['HC_BACKUP_PING_URL']).TrimEnd('/')

$ok     = $false
$detail = ''

try {
    # --- credentials --------------------------------------------------------
    $r2Account = [string]$secrets['R2_ACCOUNT_ID']
    $r2Bucket  = [string]$secrets['R2_BUCKET']
    $r2Key     = [string]$secrets['R2_ACCESS_KEY_ID']
    $r2Secret  = [string]$secrets['R2_SECRET_ACCESS_KEY']
    $resticPw  = [string]$secrets['RESTIC_PASSWORD']
    if (-not $r2Account -or -not $r2Bucket -or -not $r2Key -or -not $r2Secret -or -not $resticPw) {
        throw 'R2 credentials or RESTIC_PASSWORD missing in secrets.ini; backup is not configured.'
    }

    # restic reads these from the environment; process-scoped only, never persisted.
    $env:RESTIC_REPOSITORY     = "s3:https://$r2Account.r2.cloudflarestorage.com/$r2Bucket"
    $env:RESTIC_PASSWORD       = $resticPw
    $env:AWS_ACCESS_KEY_ID     = $r2Key
    $env:AWS_SECRET_ACCESS_KEY = $r2Secret
    $env:AWS_DEFAULT_REGION    = 'auto'

    # --- locate tools -------------------------------------------------------
    $resticCmd = Get-Command restic -ErrorAction SilentlyContinue
    if (-not $resticCmd) { throw "restic is not on PATH (install the 'restic' choco package)." }
    $restic   = $resticCmd.Source
    $giteaExe = Resolve-GiteaExe

    if (-not (Test-Path -LiteralPath $StagingDir)) {
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }

    # --- 1. gitea dump ------------------------------------------------------
    # Staging lives under C:\gitea\backup (NOT under data/ or the repo root), so the dump never
    # tries to include itself. gitea writes temp files into the cwd, so run from the staging dir.
    $stamp      = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $dumpFile   = Join-Path $StagingDir "gitea-dump-$stamp.zip"
    $configPath = Join-Path $WorkDir 'custom\conf\app.ini'
    $env:GITEA_WORK_DIR = $WorkDir
    Write-Host "[boxstrapper] Dumping Gitea -> $dumpFile" -ForegroundColor Cyan
    Push-Location -LiteralPath $StagingDir
    try {
        $r = Invoke-Native $giteaExe @('dump', '--config', $configPath, '--type', 'zip', '--file', $dumpFile)
    } finally {
        Pop-Location
    }
    if ($r.Code -ne 0) { throw "gitea dump failed (exit $($r.Code)): $($r.Output.Trim())" }
    if (-not (Test-Path -LiteralPath $dumpFile)) { throw "gitea dump reported success but $dumpFile is missing." }

    # --- 2. restic backup (client-side encrypted, uploaded to R2) -----------
    Write-Host "[boxstrapper] restic backup -> $($env:RESTIC_REPOSITORY)" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('backup', $dumpFile)
    if ($r.Code -ne 0) { throw "restic backup failed (exit $($r.Code)): $($r.Output.Trim())" }

    # --- 3. retention (GFS) -------------------------------------------------
    Write-Host "[boxstrapper] restic forget --prune (keep ${KeepDaily}d/${KeepWeekly}w/${KeepMonthly}m)" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('forget', '--keep-daily', "$KeepDaily", '--keep-weekly', "$KeepWeekly",
                                 '--keep-monthly', "$KeepMonthly", '--prune')
    if ($r.Code -ne 0) { throw "restic forget/prune failed (exit $($r.Code)): $($r.Output.Trim())" }

    # --- 4. trim local staging to the newest $KeepLocal archive(s) ----------
    Get-ChildItem -LiteralPath $StagingDir -Filter 'gitea-dump-*.zip' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLocal |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $ok     = $true
    $detail = "Backup OK: $([System.IO.Path]::GetFileName($dumpFile))"
    Write-Host "[boxstrapper] $detail" -ForegroundColor Green
} catch {
    $ok     = $false
    $detail = $_.Exception.Message
    Write-Warning "[boxstrapper] Backup failed: $detail"
}

# --- report to Healthchecks (best-effort; a monitoring failure must not throw) ---
if ($pingUrl) {
    $target = $pingUrl
    if (-not $ok) { $target = "$pingUrl/fail" }
    $body = $detail
    if ($body.Length -gt 1000) { $body = $body.Substring(0, 1000) }
    try {
        Invoke-RestMethod -Uri $target -Method Post -Body $body -TimeoutSec $TimeoutSec | Out-Null
        Write-Host "[boxstrapper] Backup status pinged: $target"
    } catch {
        Write-Warning "[boxstrapper] Healthchecks ping to $target failed: $($_.Exception.Message)"
    }
} else {
    Write-Host "[boxstrapper] No HC_BACKUP_PING_URL set; skipped status ping." -ForegroundColor DarkGray
}
