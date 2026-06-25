#Requires -Version 5
<#
.SYNOPSIS
    Dump Gitea and push an encrypted snapshot to Cloudflare R2 via restic. Best-effort, monitored.
.DESCRIPTION
    Run on a daily schedule (as SYSTEM) by the task that Gitea-Backup-Setup.ps1 registers. Pipeline:
      1. gitea dump            -> one consistent .zip (repos + SQLite DB + config + LFS + attachments).
                                  The 'gitea' service is STOPPED for the dump and restarted right after
                                  (see SERVICE below); only this step needs it down.
      2. restic backup <.zip>  -> Cloudflare R2, client-side encrypted BEFORE upload, tagged 'gitea'
      3. restic forget --prune -> GFS retention SCOPED to the 'gitea' tag (keep 7 daily / 4 weekly /
                                  6 monthly) -- see RETENTION below
      4. trim local staging    -> keep only the newest archive (a fast, no-network restore copy)
      5. ping Healthchecks.io  -> success URL on a clean run, <url>/fail (with a log tail) otherwise

    RETENTION -- why the backup/forget are tagged 'gitea' and forget groups by host,tags:
    Gitea and Jenkins back up to the SAME restic repo, and each dump is gitea-dump-<timestamp>.zip -- a
    UNIQUE path every run. A plain `restic forget --keep-*` groups by host,paths (its default), so every
    Gitea snapshot lands in its own one-member group and NOTHING is ever expired (a latent no-op), and it
    would also evaluate Jenkins' snapshots. So the backup tags snapshots 'gitea' and forget runs
    `--tag gitea --group-by host,tags`: the tag restricts the candidate set to Gitea's snapshots (Jenkins'
    are untouched), and grouping by tags collapses all of Gitea's into ONE group so GFS actually expires
    old ones. (Contrast Backup-Jenkins.ps1, which backs up a STABLE path and so needs only `--tag jenkins`.)
    NOTE: snapshots taken before this tagging existed are UNtagged, so `forget --tag gitea` won't expire
    them -- tag or forget those once by hand (`restic tag --add gitea <id>` or `restic forget <id>`).

    SERVICE -- why the dump stops Gitea:
    gitea dump packs the whole data dir, and while Gitea runs it holds an exclusive Windows handle on
    data\queues\common\LOCK (the LevelDB queue lock); Windows then refuses to let the dump read it and
    the dump aborts. So the service is stopped for the dump and restarted in a finally -- it always
    comes back up even when the dump throws, so the box is never left with Gitea down. Downtime is just
    the dump (~15-20s) once a day. Because this stops a service, MANUAL runs need an ELEVATED shell;
    the scheduled task already runs as SYSTEM, so the nightly run is unaffected.

    SECRETS -- why this worker reads secrets.ini directly:
    The R2 secret key and RESTIC_PASSWORD are NOT baked into the scheduled-task argument, because that
    argument is stored in plaintext in the Task Scheduler/registry. The task is handed only the PATH to
    secrets.ini (-SecretsFile), and this worker parses it at run time -- the same single source
    Update-Box.ps1 parses, with the same "value = everything after the first '='" rule. An ACL'd derived
    creds file was deliberately rejected: secrets.ini already sits in plaintext on the box, so an ACL'd
    copy adds a file to keep in sync without any real protection. Keys read here:
      R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, RESTIC_PASSWORD
      HC_GITEA_BACKUP_PING_URL (optional -- a SEPARATE Healthchecks check from the box heartbeat)
    Blank R2/restic creds => pings /fail (if a URL is set) and exits; never throws.

    A backup must never wedge the box, so every stage is wrapped and any failure is reported to
    Healthchecks rather than thrown. Stays Windows PowerShell 5.1-safe (no ternary / null-coalescing)
    because the scheduled task launches powershell.exe, not pwsh.

    RESTORE: a rebuilt box restores itself automatically -- Gitea-Setup.ps1 runs the internal
    Restore-Gitea.ps1 worker during the bootstrap (after configuring the service, before starting it),
    so an EMPTY box comes up on its last backup (restic restore latest -> rebuild the SQLite DB from
    gitea-db.sql -> place custom/ + data/ + repos/ -> patch RUN_USER -> single start). Disaster recovery
    is therefore just "re-bootstrap the box". To restore ad-hoc onto an EXISTING instance, do it by hand
    with restic + sqlite3 (env vars set from secrets.ini):
           RESTIC_REPOSITORY  = s3:https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com/<R2_BUCKET>
           RESTIC_PASSWORD    = <RESTIC_PASSWORD>
           AWS_ACCESS_KEY_ID  = <R2_ACCESS_KEY_ID>
           AWS_SECRET_ACCESS_KEY = <R2_SECRET_ACCESS_KEY>
           AWS_DEFAULT_REGION = auto
      1. restic snapshots --tag gitea                       # pick a snapshot id (Gitea's, not Jenkins')
         restic restore <id> --target C:\restore
      2. Unzip the recovered gitea-dump-*.zip, then follow Gitea's restore steps: stop the service,
         rebuild the DB (sqlite3 gitea.db < gitea-db.sql -- the dump stores SQL text, not a raw .db),
         restore custom/ + data/ + repos/ into C:\gitea, start the service.
      3. restic check verifies repo integrity; do a periodic test-restore to prove recoverability.
      KEEP RESTIC_PASSWORD SAFE: without it the offsite backups are unrecoverable. Escrow a copy in a
      password manager off the box, not only in secrets.ini.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SecretsFile,
    [string]$WorkDir     = 'C:\gitea',
    [string]$ServiceName = 'gitea',
    [string]$StagingDir  = 'C:\gitea\backup\staging',
    # restic tag scoping both backup and forget to Gitea snapshots in the shared (Jenkins) repo (see
    # RETENTION in the header). Mirrors Backup-Jenkins.ps1's -Tag 'jenkins'.
    [string]$Tag         = 'gitea',
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
$pingUrl = ([string]$secrets['HC_GITEA_BACKUP_PING_URL']).TrimEnd('/')

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

    # --- 1. gitea dump (service stopped so the data\queues LevelDB LOCK is free) ---
    # Staging lives under C:\gitea\backup (NOT under data/ or the repo root), so the dump never
    # tries to include itself. gitea writes temp files into the cwd, so run from the staging dir.
    # While Gitea runs it holds an exclusive Windows handle on data\queues\common\LOCK, which the
    # dump (it packs the whole data dir) cannot read -> the dump aborts. So stop the service for the
    # dump, then ALWAYS restart it (finally) -- a dump failure still propagates to the outer catch
    # (and pings /fail), but the box never ends with Gitea down. Only the dump needs it stopped;
    # the restic upload/prune below run with Gitea already back up, keeping downtime to the dump.
    $stamp      = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $dumpFile   = Join-Path $StagingDir "gitea-dump-$stamp.zip"
    $configPath = Join-Path $WorkDir 'custom\conf\app.ini'
    $env:GITEA_WORK_DIR = $WorkDir

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $stoppedService = $false
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host "[boxstrapper] Stopping '$ServiceName' for a consistent dump..." -ForegroundColor Cyan
        Stop-Service -Name $ServiceName
        Start-Sleep -Seconds 2            # let NSSM fully release the data\queues LevelDB LOCK
        $stoppedService = $true
    }
    try {
        Write-Host "[boxstrapper] Dumping Gitea -> $dumpFile" -ForegroundColor Cyan
        Push-Location -LiteralPath $StagingDir
        try {
            $r = Invoke-Native $giteaExe @('dump', '--config', $configPath, '--type', 'zip', '--file', $dumpFile)
        } finally {
            Pop-Location
        }
        if ($r.Code -ne 0) { throw "gitea dump failed (exit $($r.Code)): $($r.Output.Trim())" }
        if (-not (Test-Path -LiteralPath $dumpFile)) { throw "gitea dump reported success but $dumpFile is missing." }
    } finally {
        if ($stoppedService) {
            Write-Host "[boxstrapper] Restarting '$ServiceName'..." -ForegroundColor Cyan
            try { Start-Service -Name $ServiceName }
            catch { Write-Warning "[boxstrapper] Failed to restart '$ServiceName': $($_.Exception.Message)" }
        }
    }

    # --- 2. restic backup (client-side encrypted, uploaded to R2, tagged) ---
    Write-Host "[boxstrapper] restic backup --tag $Tag -> $($env:RESTIC_REPOSITORY)" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('backup', $dumpFile, '--tag', $Tag)
    if ($r.Code -ne 0) { throw "restic backup failed (exit $($r.Code)): $($r.Output.Trim())" }

    # --- 3. retention (GFS), SCOPED to this service's tag -------------------
    # TWO reasons for '--tag $Tag --group-by host,tags' (NOT a plain forget):
    #   (1) SHARED REPO -- Gitea and Jenkins back up to the same restic repo, so '--tag $Tag' restricts
    #       the candidate set to Gitea's own snapshots; Jenkins' snapshots are never forgotten/considered.
    #   (2) TIMESTAMPED PATH -- each dump is gitea-dump-<stamp>.zip, a UNIQUE path per run. restic's
    #       default '--group-by host,paths' would then put every snapshot in its OWN one-member group, so
    #       the keep policy would retain ALL of them (the old latent no-op). '--group-by host,tags'
    #       collapses all $Tag-tagged snapshots into ONE group, so GFS actually expires old ones.
    # (Backup-Jenkins.ps1 needs only '--tag jenkins' -- it backs up a STABLE path, so default grouping
    # already collapses its snapshots; only Gitea's per-run path forces the explicit --group-by here.)
    Write-Host "[boxstrapper] restic forget --tag $Tag --prune (keep ${KeepDaily}d/${KeepWeekly}w/${KeepMonthly}m)" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('forget', '--tag', $Tag, '--group-by', 'host,tags',
                                 '--keep-daily', "$KeepDaily", '--keep-weekly', "$KeepWeekly",
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
    Write-Host "[boxstrapper] No HC_GITEA_BACKUP_PING_URL set; skipped status ping." -ForegroundColor DarkGray
}
