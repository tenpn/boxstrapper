#Requires -Version 5
<#
.SYNOPSIS
    Snapshot JENKINS_HOME to Cloudflare R2 via restic. Best-effort, monitored.
.DESCRIPTION
    Run on a WEEKLY schedule (as SYSTEM) by the task that the shared Register-ResticBackup.ps1 registers. Pipeline:
      1. stop the 'Jenkins' service  -> a consistent read (a running Jenkins holds Windows file handles,
                                        so restic would fail/skip locked files); restarted in a finally.
      2. restic backup <JENKINS_HOME> -> Cloudflare R2, client-side encrypted BEFORE upload, tagged
                                        'jenkins', with EXCLUDES for build artifacts + rebuildable state.
      3. restic forget --prune       -> GFS retention SCOPED to the 'jenkins' tag (keep 6 weekly / 6
                                        monthly) so it never touches Gitea's snapshots in the shared repo.
      4. ping Healthchecks.io        -> success URL on a clean run, <url>/fail (with a log tail) otherwise.

    WHY A DIRECT TREE BACKUP (no dump/zip, unlike Gitea):
    Jenkins has no `dump` command, and JENKINS_HOME is already a plain on-disk file tree (XML + logs +
    plugin jars), so restic backs it up directly and dedups it natively. A STABLE backup path (the home
    dir, same every run) also means restic's `forget` GFS policy groups all Jenkins snapshots together
    and actually retains correctly -- whereas Gitea backs up a timestamped zip (a new path each run).

    WEEKLY, not daily: Jenkins state (job configs, build records) churns far less than Gitea's repos.

    WHAT'S KEPT vs EXCLUDED:
      KEPT      config.xml + top-level *.xml, jobs/<name>/config.xml, build history
                (jobs/<name>/builds/<n>/build.xml + log + result XMLs), users/, secrets/ (the master keys
                that decrypt credentials.xml -- MUST be kept), credentials.xml, nodes/, userContent/,
                init.groovy.d/, plugins/ (the exact plugin set/versions that produced the history).
      EXCLUDED  build ARTIFACTS (jobs/.../builds/<n>/archive), workspaces, the exploded war, caches,
                rotating system logs, the fingerprint DB, update-center metadata, tmp, and the local
                restore marker. (Build logs are files named `log`, so the `**/logs` dir exclude misses
                them -- history is preserved.)

    SHARED REPO -- why the 'jenkins' tag matters:
    Gitea and Jenkins share ONE restic repo (same R2 bucket). `restic forget` evaluates the whole repo
    unless filtered, so the backup tags snapshots 'jenkins' and forget is scoped `--tag jenkins`; Gitea's
    untagged snapshots are never considered. (`--prune` only drops blobs unreferenced after that scoped
    forget, so Gitea data -- still referenced by Gitea snapshots -- is safe.)

    SECRETS -- why this worker reads secrets.ini directly:
    The R2 secret key and RESTIC_PASSWORD are NOT baked into the scheduled-task argument (it's stored in
    plaintext in the registry). The task is handed only the PATH to secrets.ini (-SecretsFile), and this
    worker parses it at run time -- the same single source Update-Box.ps1 parses, same "value = everything
    after the first '='" rule. Keys read here:
      R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, RESTIC_PASSWORD
      HC_JENKINS_BACKUP_PING_URL (optional -- a SEPARATE Healthchecks check from the Jenkins heartbeat)
    Blank R2/restic creds => pings /fail (if a URL is set) and exits; never throws.

    HEARTBEAT -- suspend heartbeats for the backup period, so it doesn't send a fail while we're down for backup.

    Because this stops a service, MANUAL runs need an ELEVATED shell; the scheduled task already runs as
    SYSTEM, so the weekly run is unaffected. A backup must never wedge the box, so every stage is wrapped
    and any failure is reported to Healthchecks rather than thrown. Stays Windows PowerShell 5.1-safe
    (no ternary / null-coalescing) because the scheduled task launches powershell.exe, not pwsh.

    RESTORE: a rebuilt box restores itself automatically -- Jenkins-Setup.ps1 runs the internal
    Restore-Jenkins.ps1 worker during the bootstrap (after stopping the auto-started default Jenkins,
    before starting it again), so an EMPTY box comes up on its last backup. To restore ad-hoc onto an
    EXISTING instance, do it by hand with restic (env vars set from secrets.ini):
           RESTIC_REPOSITORY     = s3:https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com/<R2_BUCKET>
           RESTIC_PASSWORD       = <RESTIC_PASSWORD>
           AWS_ACCESS_KEY_ID     = <R2_ACCESS_KEY_ID>
           AWS_SECRET_ACCESS_KEY = <R2_SECRET_ACCESS_KEY>
           AWS_DEFAULT_REGION    = auto
      1. restic snapshots --tag jenkins                     # pick a snapshot id
         restic restore <id> --target C:\restore
      2. Stop the 'Jenkins' service, copy the restored JENKINS_HOME tree over the live one, start it.
      3. restic check verifies repo integrity; do a periodic test-restore to prove recoverability.
      KEEP RESTIC_PASSWORD SAFE: without it the offsite backups are unrecoverable. Escrow a copy in a
      password manager off the box, not only in secrets.ini.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SecretsFile,
    [string]$ServiceName = 'Jenkins',
    # '' => resolve JENKINS_HOME from jenkins.xml (same way Jenkins-Setup.ps1 does).
    [string]$JenkinsHome = '',
    # restic tag scoping both backup and forget to Jenkins snapshots in the shared (Gitea) repo.
    [string]$Tag         = 'jenkins',
    # Jenkins' Healthchecks heartbeat task (the name Jenkins-Setup.ps1 registers), suspended while the
    # service is stopped for the snapshot so the planned stop isn't reported as an outage (see HEARTBEAT).
    [string]$HeartbeatTaskName = 'boxstrapper-heartbeat-jenkins',
    # Weekly cadence => GFS in weeks/months; no --keep-daily (a weekly job has ~1 snapshot per day-used).
    [int]   $KeepWeekly  = 6,
    [int]   $KeepMonthly = 6,
    [int]   $TimeoutSec  = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Shared restic/secrets/ping plumbing: Read-Secrets, Invoke-Native, Set-ResticEnv, Send-BackupPing.
# (A detached SYSTEM task can still dot-source this: $PSScriptRoot is this jenkins\ dir at run time, and
# the worker + Backup-Common.ps1 move together with the repo -- see Backup-Common.ps1's header.)
. (Join-Path $PSScriptRoot '..\Backup-Common.ps1')

function Resolve-JenkinsHome {
    # Mirror Jenkins-Setup.ps1: installDir from the service's PathName (jenkins.exe), JENKINS_HOME from
    # jenkins.xml's <env> (WinSW expands %BASE% to the install dir), with the same fallbacks. Duplicated
    # rather than shared, the way Gitea duplicates Resolve-GiteaExe across its scripts.
    param([Parameter(Mandatory)][string]$ServiceName)
    $pathName = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).PathName
    $installDir = $null
    if ($pathName) {
        $exePath = $pathName.Trim().Trim('"')
        if (Test-Path -LiteralPath $exePath) { $installDir = Split-Path -Parent $exePath }
    }
    if (-not $installDir) { $installDir = Join-Path ${env:ProgramFiles} 'Jenkins' }
    $xmlPath = Join-Path $installDir 'jenkins.xml'
    $jhome = $null
    if (Test-Path -LiteralPath $xmlPath) {
        try {
            [xml]$xdoc = Get-Content -LiteralPath $xmlPath -Raw
            foreach ($e in @($xdoc.service.env)) {
                if ($e -and $e.name -eq 'JENKINS_HOME') { $jhome = $e.value }
            }
        } catch { }
    }
    if ($jhome) { $jhome = $jhome.Replace('%BASE%', $installDir) }
    else        { $jhome = Join-Path $installDir '.jenkins' }
    return $jhome
}

# --- read secrets directly (the SYSTEM task can't be handed them as params) --
if (-not (Test-Path -LiteralPath $SecretsFile)) {
    Write-Warning "[boxstrapper] Secrets file not found ($SecretsFile); cannot back up."
    return
}
$secrets = Read-Secrets -Path $SecretsFile
$pingUrl = ([string]$secrets['HC_JENKINS_BACKUP_PING_URL']).TrimEnd('/')

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

    # restic reads the repo + creds from the environment; process-scoped only, never persisted.
    Set-ResticEnv -R2AccountId $r2Account -R2Bucket $r2Bucket -R2AccessKeyId $r2Key `
                  -R2SecretKey $r2Secret -ResticPassword $resticPw

    # --- locate tools + JENKINS_HOME ---------------------------------------
    $resticCmd = Get-Command restic -ErrorAction SilentlyContinue
    if (-not $resticCmd) { throw "restic is not on PATH (install the 'restic' choco package)." }
    $restic = $resticCmd.Source

    if (-not $JenkinsHome) { $JenkinsHome = Resolve-JenkinsHome -ServiceName $ServiceName }
    if (-not (Test-Path -LiteralPath $JenkinsHome)) { throw "JENKINS_HOME not found at $JenkinsHome." }

    # --- excludes: artifacts (the explicit ask) + transient/rebuildable state ---
    # Matched against the full path; a leading '**/' anchors at any depth (covers nested/multibranch
    # jobs). plugins/ is intentionally NOT excluded -- we keep the exact plugin set that produced the
    # job history. Build LOGS are files named 'log', so '**/logs' (the system-log dir) leaves them alone.
    $excludes = @(
        '--exclude', '**/builds/*/archive',          # build artifacts
        '--exclude', '**/workspace',                 # controller build workspaces (rebuildable)
        '--exclude', '**/war',                       # exploded jenkins.war (rebuilt on boot)
        '--exclude', '**/caches',
        '--exclude', '**/logs',                      # rotating system logs (NOT per-build logs)
        '--exclude', '**/fingerprints',              # fingerprint DB (rebuildable, can be large)
        '--exclude', '**/updates',                   # update-center metadata (re-downloaded)
        '--exclude', '**/tmp',
        '--exclude', 'boxstrapper-restored.marker'   # local restore marker, not data
    )

    # --- stop Jenkins for a consistent snapshot (restic reads the live tree) ---
    # A running Jenkins holds exclusive Windows handles on logs/locks/plugin jars; restic can't read
    # those. Stop for the backup and ALWAYS restart in the finally -- a failure still propagates to the
    # outer catch (and pings /fail), but the box never ends with Jenkins down. forget/prune below run
    # with Jenkins already back up (they only touch the remote repo).
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $stoppedService     = $false
    $heartbeatSuspended = $false
    if ($svc -and $svc.Status -eq 'Running') {
        # Park the heartbeat FIRST so its hourly /jenkins/login probe can't land inside the stopped
        # window and /fail (see HEARTBEAT in the header). Resumed in the finally.
        $heartbeatSuspended = Suspend-HeartbeatTask -TaskName $HeartbeatTaskName
        Write-Host "[boxstrapper] Stopping '$ServiceName' for a consistent snapshot..." -ForegroundColor Cyan
        Stop-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 2            # let WinSW fully release file handles
        $stoppedService = $true
    }
    try {
        # --- restic backup (client-side encrypted, uploaded to R2, tagged 'jenkins') ---
        Write-Host "[boxstrapper] restic backup $JenkinsHome --tag $Tag -> $($env:RESTIC_REPOSITORY)" -ForegroundColor Cyan
        $r = Invoke-Native $restic (@('backup', $JenkinsHome, '--tag', $Tag) + $excludes)
        if ($r.Code -ne 0) { throw "restic backup failed (exit $($r.Code)): $($r.Output.Trim())" }
    } finally {
        if ($stoppedService) {
            Write-Host "[boxstrapper] Restarting '$ServiceName'..." -ForegroundColor Cyan
            try { Start-Service -Name $ServiceName }
            catch { Write-Warning "[boxstrapper] Failed to restart '$ServiceName': $($_.Exception.Message)" }
        }
        # Always un-park the heartbeat: waits for /jenkins/login to answer (Jetty takes a minute or more
        # after Start-Service), re-enables the task, sends a fresh success ping. A failed restart still
        # surfaces -- the resumed probe then /fails for real.
        if ($heartbeatSuspended) { Resume-HeartbeatTask -TaskName $HeartbeatTaskName }
    }

    # --- retention (GFS), SCOPED to the 'jenkins' tag so Gitea snapshots are untouched ---
    Write-Host "[boxstrapper] restic forget --tag $Tag --prune (keep ${KeepWeekly}w/${KeepMonthly}m)" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('forget', '--tag', $Tag, '--keep-weekly', "$KeepWeekly",
                                 '--keep-monthly', "$KeepMonthly", '--prune')
    if ($r.Code -ne 0) { throw "restic forget/prune failed (exit $($r.Code)): $($r.Output.Trim())" }

    $ok     = $true
    $detail = "Backup OK: $JenkinsHome (tag $Tag)"
    Write-Host "[boxstrapper] $detail" -ForegroundColor Green
} catch {
    $ok     = $false
    $detail = $_.Exception.Message
    Write-Warning "[boxstrapper] Backup failed: $detail"
}

# --- report to Healthchecks (best-effort; a monitoring failure must not throw) ---
Send-BackupPing -PingUrl $pingUrl -Ok $ok -Detail $detail -TimeoutSec $TimeoutSec
