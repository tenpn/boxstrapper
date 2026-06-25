#Requires -Version 5
<#
.SYNOPSIS
    Apply the latest offsite restic snapshot to Jenkins' on-disk data. Internal worker for Jenkins-Setup.ps1.
.DESCRIPTION
    NOT meant to be run on its own -- Jenkins-Setup.ps1 calls this with the 'Jenkins' service STOPPED,
    before it (re)starts it, so a rebuilt box comes up directly on its last backup. Pipeline:
      1. blank R2/restic creds, or a repo with NO 'jenkins'-tagged snapshot -> nothing to restore, exit.
      2. box already has real data (a boxstrapper marker, or any jobs\**\config.xml) -> skip, so a
         bootstrap re-run never clobbers a populated box (see DATA GUARD).
      3. restic restore <snap> --tag jenkins -> recover the JENKINS_HOME tree into a staging dir.
      4. copy the restored tree over the live JENKINS_HOME, then write the marker.
    The caller owns the service lifecycle: this never starts/stops Jenkins. It's already stopped when we
    run, and Jenkins-Setup.ps1 starts it exactly once afterwards on the restored data.

    DATA GUARD -- why a marker, not "does config.xml exist?":
    Unlike Gitea (whose NSSM service Gitea-Setup creates and doesn't start until after restore), the
    'jenkins' choco package AUTO-STARTS the Jenkins service at install -- before Jenkins-Setup runs -- so
    a fresh box already has a DEFAULT JENKINS_HOME (config.xml, secret.key, ...). A "skip if config.xml
    exists" guard would therefore never restore. Instead we restore onto a box that looks fresh -- no
    boxstrapper-restored.marker AND no jobs\**\config.xml (a brand-new Jenkins has ZERO jobs) -- and the
    first successful restore writes the marker so re-runs are clean no-ops. A box where a human created
    any job trips the jobs guard and is never clobbered.

    NO host-specific patching (unlike Gitea's RUN_USER / SQLite rebuild): Jenkins config is portable as-is
    across boxes, and restoring secrets/ (the master keys) keeps credentials.xml decryptable. Plugins come
    back from the snapshot too, and Jenkins-Setup's own plugin step then reconciles them against
    plugins.txt on top of the restored tree.

    SECRETS: the R2 keys + restic password arrive as PARAMS. Update-Box.ps1 is the sole secrets.ini parser
    and passes them down via Jenkins-Setup.ps1 -- this script never reads secrets.ini (unlike the
    SYSTEM-task backup worker, which must self-read because a task argument can't carry secrets safely).
    Blank creds => nothing to restore from, exit cleanly.

    Runs elevated (the caller, Jenkins-Setup.ps1, already requires it) and stays Windows PowerShell
    5.1-safe (no ternary / null-coalescing). Skip messages use DarkGray -- "nothing to restore" is the
    normal case on a healthy/fresh box.
#>

[CmdletBinding()]
param(
    # R2 + restic credentials, passed down from Update-Box.ps1 via Jenkins-Setup.ps1 (never parsed here).
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = '',
    [string]$ServiceName    = 'Jenkins',
    # '' => resolve JENKINS_HOME from jenkins.xml (same way Jenkins-Setup.ps1 / Backup-Jenkins.ps1 do).
    [string]$JenkinsHome    = '',
    [string]$Tag            = 'jenkins',
    # 'latest' = restic's most recent snapshot; pass a snapshot id for point-in-time recovery.
    [string]$SnapshotId     = 'latest',
    # '' => <installDir>\boxstrapper-restore (a temp staging tree, cleaned up after).
    [string]$RestoreStaging = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-JenkinsPaths {
    # Mirror Jenkins-Setup.ps1: installDir from the service's PathName (jenkins.exe), JENKINS_HOME from
    # jenkins.xml's <env> (WinSW expands %BASE% to the install dir), with the same fallbacks. Returns
    # both because the default restore-staging dir lives under installDir.
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
    return [pscustomobject]@{ InstallDir = $installDir; JenkinsHome = $jhome }
}

# --- credentials: blank => offsite backup not configured, nothing to restore from ---
if (-not $R2AccountId -or -not $R2Bucket -or -not $R2AccessKeyId -or -not $R2SecretKey -or -not $ResticPassword) {
    Write-Host "[boxstrapper] Offsite backup not configured; nothing to restore from." -ForegroundColor DarkGray
    return
}

# restic reads these from the environment; process-scoped only. The inline caller (Jenkins-Setup.ps1)
# clears them from its env after we return.
$env:RESTIC_REPOSITORY     = "s3:https://$R2AccountId.r2.cloudflarestorage.com/$R2Bucket"
$env:RESTIC_PASSWORD       = $ResticPassword
$env:AWS_ACCESS_KEY_ID     = $R2AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $R2SecretKey
$env:AWS_DEFAULT_REGION    = 'auto'

# --- locate tools + JENKINS_HOME -------------------------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH (install the 'restic' choco package)." }
$restic = $resticCmd.Source

$paths = Resolve-JenkinsPaths -ServiceName $ServiceName
if (-not $JenkinsHome) { $JenkinsHome = $paths.JenkinsHome }
if (-not $RestoreStaging) { $RestoreStaging = Join-Path $paths.InstallDir 'boxstrapper-restore' }

# --- 1. is there anything to restore? (scope to the 'jenkins' tag in the shared repo) ---
$r = Invoke-Native $restic @('snapshots', $SnapshotId, '--tag', $Tag, '--json')
if ($r.Code -ne 0) {
    # Repo unreachable / not initialised yet (e.g. a first-ever box). Nothing to restore.
    Write-Host "[boxstrapper] No restic repo to restore from yet; nothing to restore." -ForegroundColor DarkGray
    return
}
$snaps = @()
try { $snaps = @($r.Output | ConvertFrom-Json) } catch { $snaps = @() }
if ($snaps.Count -eq 0) {
    Write-Host "[boxstrapper] No 'jenkins'-tagged snapshots in the restic repo; nothing to restore." -ForegroundColor DarkGray
    return
}

# --- 2. never clobber an already-populated box -----------------------------
# A fresh, MSI-booted Jenkins writes config.xml/secret.key but ZERO jobs, so "no marker AND no real job
# config" = a box safe to restore onto. The marker locks it after the first restore so re-runs no-op.
$marker  = Join-Path $JenkinsHome 'boxstrapper-restored.marker'
$jobsDir = Join-Path $JenkinsHome 'jobs'
$hasRealJobs = $false
if (Test-Path -LiteralPath $jobsDir) {
    $hasRealJobs = [bool](Get-ChildItem -LiteralPath $jobsDir -Recurse -Filter 'config.xml' -File -ErrorAction SilentlyContinue |
                          Select-Object -First 1)
}
if ((Test-Path -LiteralPath $marker) -or $hasRealJobs) {
    Write-Host "[boxstrapper] Jenkins already has data (marker or jobs present); skipping restore." -ForegroundColor DarkGray
    return
}

try {
    # --- 3. restic restore into a clean staging dir -------------------------
    if (Test-Path -LiteralPath $RestoreStaging) { Remove-Item -LiteralPath $RestoreStaging -Recurse -Force }
    New-Item -ItemType Directory -Path $RestoreStaging -Force | Out-Null
    Write-Host "[boxstrapper] restic restore $SnapshotId (tag $Tag) -> $RestoreStaging" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('restore', $SnapshotId, '--tag', $Tag, '--target', $RestoreStaging)
    if ($r.Code -ne 0) { throw "restic restore failed (exit $($r.Code)): $($r.Output.Trim())" }

    # restic recreates the original (absolute) JENKINS_HOME path under the target; the source box's
    # install dir may differ from ours, so locate the restored home by its config.xml (shortest path
    # wins -- the home's own config.xml, not a job's deeper jobs\<name>\config.xml).
    $restoredHome = Get-ChildItem -LiteralPath $RestoreStaging -Recurse -Filter 'config.xml' -File -ErrorAction SilentlyContinue |
                    Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if (-not $restoredHome) { throw "Restored snapshot contains no config.xml under $RestoreStaging; cannot locate JENKINS_HOME." }
    $restoredHomeDir = $restoredHome.Directory.FullName

    # --- 4. copy the restored tree over the live JENKINS_HOME ---------------
    # Overwrites the default files the auto-started Jenkins wrote. -Path (not -LiteralPath) so the
    # trailing '*' expands to the restored home's children.
    if (-not (Test-Path -LiteralPath $JenkinsHome)) { New-Item -ItemType Directory -Path $JenkinsHome -Force | Out-Null }
    Write-Host "[boxstrapper] Restoring Jenkins data into $JenkinsHome..." -ForegroundColor Cyan
    Copy-Item -Path (Join-Path $restoredHomeDir '*') -Destination $JenkinsHome -Recurse -Force

    # --- 5. mark it restored so a bootstrap re-run is a clean no-op ---------
    Set-Content -LiteralPath $marker -Value (Get-Date -Format o) -Encoding ASCII
    Write-Host "[boxstrapper] Restore applied; Jenkins-Setup will start Jenkins on the restored data." -ForegroundColor Green
} finally {
    # Best-effort cleanup of the (large) restore staging tree.
    if (Test-Path -LiteralPath $RestoreStaging) {
        Remove-Item -LiteralPath $RestoreStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
