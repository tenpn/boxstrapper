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
    # '' => <SystemDrive>\boxstrapper-jenkins-restore (a temp staging tree, cleaned up after). Kept SHORT
    # and space-free on purpose: restic recreates the snapshot's full absolute path under this dir, so a
    # long base (e.g. the MSI's "C:\Program Files\Jenkins\...") pushes Jenkins' deep plugin/build files
    # past Windows' 260-char MAX_PATH and breaks the tree walk/copy below.
    [string]$RestoreStaging = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Shared restic/secrets plumbing: Invoke-Native, Set-ResticEnv.
. (Join-Path $PSScriptRoot '..\Backup-Common.ps1')

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

function Find-RestoredHomeDir {
    # Locate the restored JENKINS_HOME under a restic --target dir WITHOUT Get-ChildItem -Recurse, which in
    # Windows PowerShell 5.1 returns NOTHING the moment the tree holds an access-denied OR >260-char path --
    # BOTH occur in a restored Jenkins tree (restic restores the source's NTFS ACLs, and plugin/build paths
    # run deep). Walk down breadth-first with NON-recursive listings instead: the home's config.xml sits only
    # a few levels under the target (restic recreates <target>\<drive>\<path>\config.xml), so we hit it before
    # ever descending into the deep/locked plugin & build dirs. Bounded visit count as a stop guard.
    param([Parameter(Mandatory)][string]$Root)
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($Root)
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 200) {
        $dir = $queue.Dequeue()
        $visited++
        if (Test-Path -LiteralPath (Join-Path $dir 'config.xml')) { return $dir }
        # -Force: restic restores source file attributes, so intermediate dirs like ProgramData come back
        # HIDDEN -- without -Force, Get-ChildItem skips them and the walk dead-ends before reaching the home.
        Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $queue.Enqueue($_.FullName) }
    }
    return $null
}

# --- credentials: blank => offsite backup not configured, nothing to restore from ---
if (-not $R2AccountId -or -not $R2Bucket -or -not $R2AccessKeyId -or -not $R2SecretKey -or -not $ResticPassword) {
    Write-Host "[boxstrapper] Offsite backup not configured; nothing to restore from." -ForegroundColor DarkGray
    return
}

# restic reads the repo + creds from the environment; process-scoped only. The inline caller
# (Jenkins-Setup.ps1) clears them from its env after we return.
Set-ResticEnv -R2AccountId $R2AccountId -R2Bucket $R2Bucket -R2AccessKeyId $R2AccessKeyId `
              -R2SecretKey $R2SecretKey -ResticPassword $ResticPassword

# --- locate tools + JENKINS_HOME -------------------------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH (install the 'restic' choco package)." }
$restic = $resticCmd.Source

$paths = Resolve-JenkinsPaths -ServiceName $ServiceName
if (-not $JenkinsHome) { $JenkinsHome = $paths.JenkinsHome }
# Short, space-free staging on the system drive (NOT under the spaced MSI install dir) so the restored
# absolute paths stay clear of the 260-char MAX_PATH ceiling -- see the -RestoreStaging param note.
if (-not $RestoreStaging) { $RestoreStaging = Join-Path $env:SystemDrive 'boxstrapper-jenkins-restore' }

# --- 1. is there anything to restore? (scope to the 'jenkins' tag in the shared repo) ---
$r = Invoke-Native $restic @('snapshots', $SnapshotId, '--tag', $Tag, '--json')
if ($r.Code -ne 0) {
    # Repo unreachable / not initialised yet (e.g. a first-ever box). Nothing to restore.
    Write-Host "[boxstrapper] No restic repo to restore from yet; nothing to restore." -ForegroundColor DarkGray
    return
}
$snaps = @()
# Where-Object drops the scalar an empty '[]' becomes under 5.1 (whose .Count is 1), so an empty tag is
# a true 0-length array and takes the clean "nothing to restore" path instead of erroring on restore.
try { $snaps = @($r.Output | ConvertFrom-Json | Where-Object { $_ }) } catch { $snaps = @() }
if ($snaps.Count -eq 0) {
    Write-Host "[boxstrapper] No 'jenkins'-tagged snapshots in the restic repo; nothing to restore." -ForegroundColor DarkGray
    return
}
# The snapshot records the original (absolute) JENKINS_HOME it backed up (single path -- the Backup-Jenkins
# tree backup). We use it below to locate the restored home DETERMINISTICALLY instead of scanning the
# restored tree (a Get-ChildItem -Recurse over that tree silently finds nothing once a restored file is
# access-denied or exceeds MAX_PATH -- the bug this restore previously hit).
# NOTE: Windows PowerShell 5.1's ConvertFrom-Json unwraps a SINGLE-element JSON array into a scalar, so
# $snaps[0].paths is a bare string here (it's an array under pwsh 7). Handle BOTH -- calling .Count on the
# string throws under StrictMode, which is exactly what previously left this blank and broke the locate.
$srcHomePath = ''
try {
    $p = $snaps[0].paths
    if ($p -is [array]) { if ($p.Count -gt 0) { $srcHomePath = [string]$p[0] } }
    elseif ($p)         { $srcHomePath = [string]$p }
} catch { $srcHomePath = '' }

# --- 2. never clobber an already-populated box -----------------------------
# A fresh, MSI-booted Jenkins writes config.xml/secret.key but ZERO jobs, so "no marker AND no real job
# config" = a box safe to restore onto. The marker locks it after the first restore so re-runs no-op.
$marker  = Join-Path $JenkinsHome 'boxstrapper-restored.marker'
$jobsDir = Join-Path $JenkinsHome 'jobs'
# A job is a SUBDIRECTORY of jobs\ (jobs\<name>\config.xml); a fresh Jenkins has none. Check for any child
# directory rather than a -Recurse config.xml scan -- the latter SILENTLY RETURNS NOTHING once a populated
# jobs tree contains a >260-char path (deep build files), which would falsely report "no jobs" and let a
# re-run clobber a human's jobs. A shallow directory check is immune to MAX_PATH.
$hasRealJobs = $false
if (Test-Path -LiteralPath $jobsDir) {
    $hasRealJobs = [bool](Get-ChildItem -LiteralPath $jobsDir -Directory -Force -ErrorAction SilentlyContinue |
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

    # restic recreates the original (absolute) JENKINS_HOME path under the target, e.g.
    # <staging>\C\ProgramData\Jenkins\.jenkins for a snapshot of C:\ProgramData\Jenkins\.jenkins. DERIVE
    # that path from the snapshot's recorded home ($srcHomePath) -- map "C:\..." -> "C\..." and join under
    # the staging dir -- rather than a Get-ChildItem -Recurse scan, which silently returns NOTHING under 5.1
    # the moment the restored tree holds an access-denied or >260-char path (Jenkins' deep plugin/build
    # files do). The BFS walk (Find-RestoredHomeDir) is the fallback for an unexpected layout.
    $restoredHomeDir = $null
    if ($srcHomePath) {
        $rel       = $srcHomePath -replace '^([A-Za-z]):', '$1'   # "C:\...\.jenkins" -> "C\...\.jenkins"
        $candidate = Join-Path $RestoreStaging $rel
        if (Test-Path -LiteralPath (Join-Path $candidate 'config.xml')) { $restoredHomeDir = $candidate }
    }
    # Fallback for an unexpected layout: a breadth-first walk that is immune to the MAX_PATH/access-denied
    # silent-empty failure of Get-ChildItem -Recurse under 5.1 (see Find-RestoredHomeDir).
    if (-not $restoredHomeDir) { $restoredHomeDir = Find-RestoredHomeDir -Root $RestoreStaging }
    if (-not $restoredHomeDir) { throw "Restored snapshot contains no config.xml under $RestoreStaging; cannot locate JENKINS_HOME." }

    # --- 4. copy the restored tree over the live JENKINS_HOME ---------------
    # Overwrites the default files the auto-started Jenkins wrote (incl. secret.key, so credentials.xml
    # stays decryptable). Use robocopy, NOT Copy-Item -Recurse: robocopy copies the tree natively with no
    # 260-char MAX_PATH ceiling, so Jenkins' deep plugin/build paths come across intact. /E = all subdirs
    # incl. empty; overlay (no /MIR -- we lay the snapshot ON TOP of the fresh home, never purge). robocopy
    # exit codes 0-7 are success (bits: copied/extra/mismatch); >= 8 means a real failure.
    if (-not (Test-Path -LiteralPath $JenkinsHome)) { New-Item -ItemType Directory -Path $JenkinsHome -Force | Out-Null }
    Write-Host "[boxstrapper] Restoring Jenkins data into $JenkinsHome..." -ForegroundColor Cyan
    & robocopy $restoredHomeDir $JenkinsHome /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE) copying restored data into $JenkinsHome." }

    # --- 5. mark it restored so a bootstrap re-run is a clean no-op ---------
    Set-Content -LiteralPath $marker -Value (Get-Date -Format o) -Encoding ASCII
    Write-Host "[boxstrapper] Restore applied; Jenkins-Setup will start Jenkins on the restored data." -ForegroundColor Green
} finally {
    # Best-effort cleanup of the (large) restore staging tree.
    if (Test-Path -LiteralPath $RestoreStaging) {
        Remove-Item -LiteralPath $RestoreStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
