#Requires -Version 5
<#
.SYNOPSIS
    Apply the latest offsite restic snapshot to Gitea's on-disk data. Internal worker for Gitea-Setup.ps1.
.DESCRIPTION
    NOT meant to be run on its own -- Gitea-Setup.ps1 calls this AFTER configuring the gitea service but
    BEFORE starting it, so a rebuilt box comes up directly on its last backup. There is no built-in
    `gitea restore`, so this automates the documented manual procedure. Pipeline:
      1. blank R2/restic creds, or a repo with NO snapshot -> nothing to restore, exit cleanly.
      2. box already has data (<WorkDir>\data\gitea.db) -> skip, so a bootstrap re-run never clobbers a
         populated box (the only data guard there is -- restore only ever runs onto an empty box).
      3. restic restore <snap> -> recover the gitea-dump-*.zip into a staging dir.
      4. expand the zip, then apply it:
           - rebuild the SQLite DB from gitea-db.sql with sqlite3 (the dump stores the DB as a TEXT
             SQL dump, NOT the raw gitea.db -- so sqlite3 must be on PATH; it's in packages.config),
           - copy custom/ + data/ + repos/ into place under -WorkDir,
           - rewrite RUN_USER in the restored app.ini to THIS box's machine account (see RUN_USER).
    The caller owns the service lifecycle: this never starts/stops gitea or probes it. The service is
    already stopped when we run, and Gitea-Setup.ps1 starts it exactly once afterwards, on the restored
    data -- so gitea is never started-then-bounced.

    RUN_USER -- why the restored app.ini is patched:
    A dump carries the SOURCE box's app.ini, whose RUN_USER is that box's machine account
    ("<OLDCOMPUTERNAME>$"). Under NSSM's LocalSystem this box runs as "<THISCOMPUTERNAME>$"; Gitea
    refuses to start on a RUN_USER mismatch (see the gitea-app-ini-invariants gotcha in CLAUDE.md), so
    RUN_USER is rewritten to this box's account. WorkDir is assumed identical across boxes (boxstrapper
    hardcodes C:\gitea), so the DB PATH / repo ROOT inside the restored app.ini already line up.

    SECRETS: the R2 keys + restic password arrive as PARAMS. Update-Box.ps1 is the sole secrets.ini
    parser and passes them down via Gitea-Setup.ps1, exactly like the shared Register-ResticBackup.ps1 -- this script
    never reads secrets.ini itself (unlike the SYSTEM-task backup worker, which must self-read because a
    task argument can't carry secrets safely). Blank creds => nothing to restore from, exit cleanly.

    Runs elevated (the caller, Gitea-Setup.ps1, already requires it) and stays Windows PowerShell
    5.1-safe (no ternary / null-coalescing).
#>

[CmdletBinding()]
param(
    # R2 + restic credentials, passed down from Update-Box.ps1 via Gitea-Setup.ps1 (never parsed here).
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = '',
    [string]$WorkDir        = 'C:\gitea',
    # restic tag that scopes snapshot selection to GITEA's backups -- the repo is shared with Jenkins, so
    # without this 'latest' could resolve to a Jenkins snapshot. Mirrors Backup-Gitea.ps1's -Tag 'gitea'.
    [string]$Tag            = 'gitea',
    # 'latest' = restic's most recent snapshot; pass a snapshot id for point-in-time recovery.
    [string]$SnapshotId     = 'latest',
    [string]$RestoreStaging = 'C:\gitea\backup\restore'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Shared restic/secrets plumbing: Invoke-Native (with -StdinFile for sqlite3), Set-ResticEnv.
. (Join-Path $PSScriptRoot '..\Backup-Common.ps1')

function Get-IniValue {
    # Tiny INI reader: value of $Key in section [$Section] ('' = the top, pre-section, block).
    param([Parameter(Mandatory)][string]$Path, [string]$Section = '', [Parameter(Mandatory)][string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $cur = ''
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        if ($t.StartsWith('[') -and $t.EndsWith(']')) { $cur = $t.Substring(1, $t.Length - 2).Trim(); continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        if (($cur -ieq $Section) -and ($t.Substring(0, $i).Trim() -ieq $Key)) {
            return $t.Substring($i + 1).Trim()
        }
    }
    return $null
}

function Restore-Tree {
    # Copy the CONTENTS of $Src into $Dst (merge/overwrite), if $Src exists.
    param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) { return }
    if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
    # -Path (not -LiteralPath) so the trailing '*' expands to $Src's children.
    Copy-Item -Path (Join-Path $Src '*') -Destination $Dst -Recurse -Force
}

# --- credentials: blank => offsite backup not configured, nothing to restore from ---
if (-not $R2AccountId -or -not $R2Bucket -or -not $R2AccessKeyId -or -not $R2SecretKey -or -not $ResticPassword) {
    Write-Host "[boxstrapper] Offsite backup not configured; nothing to restore from." -ForegroundColor DarkGray
    return
}

# restic reads the repo + creds from the environment; process-scoped only. The inline caller
# (Gitea-Setup.ps1) clears them from its env after we return.
Set-ResticEnv -R2AccountId $R2AccountId -R2Bucket $R2Bucket -R2AccessKeyId $R2AccessKeyId `
              -R2SecretKey $R2SecretKey -ResticPassword $ResticPassword

# --- locate tools -----------------------------------------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH (install the 'restic' choco package)." }
$restic = $resticCmd.Source

$sqliteCmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqliteCmd) { throw "sqlite3 is not on PATH (install the 'sqlite' choco package; it's in packages.config). Needed to rebuild the DB from gitea-db.sql." }
$sqlite3 = $sqliteCmd.Source

# --- 1. is there anything to restore? (scope to the 'gitea' tag in the shared repo) -----------
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
    Write-Host "[boxstrapper] No '$Tag'-tagged snapshots in the restic repo; nothing to restore." -ForegroundColor DarkGray
    return
}

# --- 2. never clobber an already-populated box -----------------------------
$liveDb = Join-Path $WorkDir 'data\gitea.db'
if (Test-Path -LiteralPath $liveDb) {
    Write-Host "[boxstrapper] Gitea already has data ($liveDb); skipping restore." -ForegroundColor DarkGray
    return
}

try {
    # --- 3. restic restore into a clean staging dir -------------------------
    if (Test-Path -LiteralPath $RestoreStaging) { Remove-Item -LiteralPath $RestoreStaging -Recurse -Force }
    New-Item -ItemType Directory -Path $RestoreStaging -Force | Out-Null
    Write-Host "[boxstrapper] restic restore $SnapshotId (tag $Tag) -> $RestoreStaging" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('restore', $SnapshotId, '--tag', $Tag, '--target', $RestoreStaging)
    if ($r.Code -ne 0) { throw "restic restore failed (exit $($r.Code)): $($r.Output.Trim())" }

    # restic recreates the original (absolute) path under the target, so locate the dump by name.
    $zip = Get-ChildItem -LiteralPath $RestoreStaging -Recurse -Filter 'gitea-dump-*.zip' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) { throw "Restored snapshot contains no gitea-dump-*.zip under $RestoreStaging." }

    # --- 4. expand the dump -------------------------------------------------
    $expandDir = Join-Path $RestoreStaging 'expanded'
    Write-Host "[boxstrapper] Expanding $($zip.Name)..." -ForegroundColor Cyan
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expandDir -Force

    $dumpCustom = Join-Path $expandDir 'custom'
    $dumpData   = Join-Path $expandDir 'data'
    $dumpRepos  = Join-Path $expandDir 'repos'
    $dumpSql    = Join-Path $expandDir 'gitea-db.sql'
    if (-not (Test-Path -LiteralPath $dumpSql)) { throw "Dump has no gitea-db.sql at $dumpSql; cannot restore the database." }

    # --- 4a. files: custom/ + data/ into <WorkDir>; repos/ into the repo ROOT ---
    # data/ holds APP_DATA_PATH (lfs/avatars/etc), NOT the DB -- the DB is the SQL dump, rebuilt below.
    Write-Host "[boxstrapper] Restoring custom/, data/, repos/ into $WorkDir..." -ForegroundColor Cyan
    Restore-Tree -Src $dumpCustom -Dst (Join-Path $WorkDir 'custom')
    Restore-Tree -Src $dumpData   -Dst (Join-Path $WorkDir 'data')

    # Repo root: trust the restored app.ini's [repository] ROOT; fall back to the Gitea default.
    $appIni = Join-Path $WorkDir 'custom\conf\app.ini'
    if (-not (Test-Path -LiteralPath $appIni)) { throw "Restored app.ini missing at $appIni; dump may be incomplete." }
    $repoRoot = Get-IniValue -Path $appIni -Section 'repository' -Key 'ROOT'
    if (-not $repoRoot) { $repoRoot = Join-Path $WorkDir 'data\gitea-repositories' }
    $repoRoot = $repoRoot -replace '/', '\'
    Restore-Tree -Src $dumpRepos -Dst $repoRoot

    # --- 4b. rebuild the SQLite DB from the SQL dump ------------------------
    $dbPath = Get-IniValue -Path $appIni -Section 'database' -Key 'PATH'
    if (-not $dbPath) { $dbPath = Join-Path $WorkDir 'data\gitea.db' }
    $dbFs   = $dbPath -replace '/', '\'
    $dbDir  = Split-Path -Parent $dbFs
    if (-not (Test-Path -LiteralPath $dbDir)) { New-Item -ItemType Directory -Path $dbDir -Force | Out-Null }
    if (Test-Path -LiteralPath $dbFs) { Remove-Item -LiteralPath $dbFs -Force }
    Write-Host "[boxstrapper] Rebuilding SQLite DB at $dbFs from gitea-db.sql..." -ForegroundColor Cyan
    $r = Invoke-Native $sqlite3 @($dbFs) -StdinFile $dumpSql
    if ($r.Code -ne 0) { throw "sqlite3 restore failed (exit $($r.Code)): $($r.Output.Trim())" }
    if (-not (Test-Path -LiteralPath $dbFs)) { throw "sqlite3 reported success but $dbFs was not created." }

    # --- 4c. patch RUN_USER to THIS box's machine account -------------------
    # The dumped app.ini carries the source box's RUN_USER; a mismatch makes Gitea refuse to start.
    $runUser = "$env:COMPUTERNAME`$"
    $lines   = Get-Content -LiteralPath $appIni
    $patched = $false
    $out = foreach ($l in $lines) {
        if (-not $patched -and ($l.Trim() -match '^RUN_USER\s*=')) { "RUN_USER = $runUser"; $patched = $true }
        else { $l }
    }
    if (-not $patched) { $out = @("RUN_USER = $runUser") + $out }
    Set-Content -LiteralPath $appIni -Value $out -Encoding ASCII
    Write-Host "[boxstrapper] Set RUN_USER=$runUser in $appIni" -ForegroundColor DarkGray
} finally {
    # Best-effort cleanup of the (large) restore staging tree.
    if (Test-Path -LiteralPath $RestoreStaging) {
        Remove-Item -LiteralPath $RestoreStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[boxstrapper] Restore applied; Gitea-Setup will start Gitea on the restored data." -ForegroundColor Green
