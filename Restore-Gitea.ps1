#Requires -Version 5
<#
.SYNOPSIS
    Restore Gitea from the latest offsite restic snapshot. Counterpart to Backup-Gitea.ps1.
.DESCRIPTION
    Pulls a `gitea dump` snapshot down from Cloudflare R2 (via restic) and applies it to this box, so
    a rebuilt machine comes back up on its last good backup instead of an empty web installer. There is
    no built-in `gitea restore`, so this automates the documented manual procedure. Pipeline:
      1. restic snapshots      -> if the repo has NO snapshot, there's nothing to restore: exit cleanly.
      2. (guard existing data) -> see DATA GUARD below.
      3. stop the 'gitea' service (restarted in a finally, same lock reason as the backup worker).
      4. restic restore <snap> -> recover the gitea-dump-*.zip into a staging dir.
      5. expand the zip, then apply it:
           - rebuild the SQLite DB from gitea-db.sql with sqlite3 (the dump stores the DB as a TEXT
             SQL dump, NOT the raw gitea.db -- so sqlite3 must be on PATH; it's in packages.config),
           - copy custom/ + data/ + repos/ into place under -WorkDir,
           - rewrite RUN_USER in the restored app.ini to THIS box's machine account (see RUN_USER).
      6. restart 'gitea' and probe http://localhost:3000 for real readiness.

    DATA GUARD -- why a populated box isn't clobbered:
    "Has data" is signalled by an existing <WorkDir>\data\gitea.db. With -OnlyIfEmpty (how Update-Box.ps1
    calls this during a bootstrap) a populated box is a silent no-op, so re-running the bootstrap never
    overwrites live data. Run directly (no -OnlyIfEmpty) and, if data exists, you're PROMPTED before the
    overwrite; -Force skips the prompt (and is required for a non-interactive overwrite).

    RUN_USER -- why the restored app.ini is patched:
    A dump carries the SOURCE box's app.ini, whose RUN_USER is that box's machine account
    ("<OLDCOMPUTERNAME>$"). Under NSSM's LocalSystem this box runs as "<THISCOMPUTERNAME>$"; Gitea
    refuses to start on a RUN_USER mismatch (see the gitea-app-ini-invariants gotcha in CLAUDE.md), so
    RUN_USER is rewritten to this box's account. WorkDir is assumed identical across boxes (boxstrapper
    hardcodes C:\gitea), so the DB PATH / repo ROOT inside the restored app.ini already line up.

    SECRETS -- read directly from secrets.ini (same as Backup-Gitea.ps1): R2_ACCOUNT_ID, R2_BUCKET,
    R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, RESTIC_PASSWORD. Blank creds => nothing to restore from, so
    it warns and exits without touching the box.

    Stays Windows PowerShell 5.1-safe (no ternary / null-coalescing). MANUAL runs need an ELEVATED shell
    (it stops/starts a service); Update-Box.ps1's auto call is already elevated.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SecretsFile,
    [string]$WorkDir       = 'C:\gitea',
    [string]$ServiceName   = 'gitea',
    # 'latest' = restic's most recent snapshot; pass a snapshot id for point-in-time recovery.
    [string]$SnapshotId    = 'latest',
    [string]$RestoreStaging = 'C:\gitea\backup\restore',
    # Only restore when this box has NO Gitea data yet (how Update-Box.ps1 calls it). A no-op otherwise.
    [switch]$OnlyIfEmpty,
    # Overwrite existing data without the interactive prompt.
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Restore-Gitea.ps1 must run in an elevated PowerShell (it stops/starts the gitea service).'
}

function Read-Secrets {
    # Same parse as Update-Box.ps1 / Backup-Gitea.ps1: value = everything after the first '='.
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

function Invoke-Native {
    # Run a native exe, capturing combined stdout+stderr without letting native stderr trip
    # $ErrorActionPreference='Stop'. Optionally feed a file to stdin (for sqlite3 < dump.sql).
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [string]$StdinFile)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($StdinFile) {
            $out = Get-Content -LiteralPath $StdinFile -Raw | & $Exe @Arguments 2>&1 | Out-String
        } else {
            $out = & $Exe @Arguments 2>&1 | Out-String
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

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

# --- read secrets + credentials --------------------------------------------
if (-not (Test-Path -LiteralPath $SecretsFile)) {
    Write-Warning "[boxstrapper] Secrets file not found ($SecretsFile); cannot restore."
    return
}
$secrets   = Read-Secrets -Path $SecretsFile
$r2Account = [string]$secrets['R2_ACCOUNT_ID']
$r2Bucket  = [string]$secrets['R2_BUCKET']
$r2Key     = [string]$secrets['R2_ACCESS_KEY_ID']
$r2Secret  = [string]$secrets['R2_SECRET_ACCESS_KEY']
$resticPw  = [string]$secrets['RESTIC_PASSWORD']
if (-not $r2Account -or -not $r2Bucket -or -not $r2Key -or -not $r2Secret -or -not $resticPw) {
    Write-Host "[boxstrapper] Offsite backup not configured; nothing to restore from." -ForegroundColor DarkGray
    return
}

# restic reads these from the environment; process-scoped only. Standalone runs are their own
# process; the inline Update-Box.ps1 call clears them from its env in a finally after this returns.
$env:RESTIC_REPOSITORY     = "s3:https://$r2Account.r2.cloudflarestorage.com/$r2Bucket"
$env:RESTIC_PASSWORD       = $resticPw
$env:AWS_ACCESS_KEY_ID     = $r2Key
$env:AWS_SECRET_ACCESS_KEY = $r2Secret
$env:AWS_DEFAULT_REGION    = 'auto'

# --- locate tools -----------------------------------------------------------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic is not on PATH (install the 'restic' choco package)." }
$restic = $resticCmd.Source

$sqliteCmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqliteCmd) { throw "sqlite3 is not on PATH (install the 'sqlite' choco package; it's in packages.config). Needed to rebuild the DB from gitea-db.sql." }
$sqlite3 = $sqliteCmd.Source

# --- 1. is there anything to restore? --------------------------------------
$r = Invoke-Native $restic @('snapshots', $SnapshotId, '--json')
if ($r.Code -ne 0) {
    # Repo unreachable / not initialised. In auto mode that's just "no backup yet" -- skip quietly.
    if ($OnlyIfEmpty) {
        Write-Host "[boxstrapper] No restic repo to restore from yet; nothing to restore." -ForegroundColor DarkGray
        return
    }
    throw "restic could not read snapshots (exit $($r.Code)): $($r.Output.Trim())"
}
$snaps = @()
try { $snaps = @($r.Output | ConvertFrom-Json) } catch { $snaps = @() }
if ($snaps.Count -eq 0) {
    Write-Host "[boxstrapper] No snapshots in the restic repo; nothing to restore." -ForegroundColor DarkGray
    return
}

# --- 2. guard existing data -------------------------------------------------
$liveDb = Join-Path $WorkDir 'data\gitea.db'
$hasData = Test-Path -LiteralPath $liveDb
if ($hasData) {
    if ($OnlyIfEmpty) {
        Write-Host "[boxstrapper] Gitea already has data ($liveDb); skipping auto-restore." -ForegroundColor DarkGray
        return
    }
    if (-not $Force) {
        $ok = $false
        try {
            $choice = $Host.UI.PromptForChoice(
                'Existing Gitea data found',
                "Restore snapshot '$SnapshotId' OVER the current Gitea (replaces DB, repos, custom/ and data/)?",
                @('&Yes, overwrite', '&No, cancel'), 1)
            $ok = ($choice -eq 0)
        } catch {
            throw "Existing data at $liveDb and this host can't prompt. Re-run with -Force to overwrite."
        }
        if (-not $ok) {
            Write-Host "[boxstrapper] Restore cancelled; existing data left untouched." -ForegroundColor DarkGray
            return
        }
    }
}

# --- 3. stop the service (released for a clean overwrite; always restarted) --
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$stoppedService = $false
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "[boxstrapper] Stopping '$ServiceName' for the restore..." -ForegroundColor Cyan
    Stop-Service -Name $ServiceName
    Start-Sleep -Seconds 2            # let NSSM release file handles under the data dir
    $stoppedService = $true
}

try {
    # --- 4. restic restore into a clean staging dir -------------------------
    if (Test-Path -LiteralPath $RestoreStaging) { Remove-Item -LiteralPath $RestoreStaging -Recurse -Force }
    New-Item -ItemType Directory -Path $RestoreStaging -Force | Out-Null
    Write-Host "[boxstrapper] restic restore $SnapshotId -> $RestoreStaging" -ForegroundColor Cyan
    $r = Invoke-Native $restic @('restore', $SnapshotId, '--target', $RestoreStaging)
    if ($r.Code -ne 0) { throw "restic restore failed (exit $($r.Code)): $($r.Output.Trim())" }

    # restic recreates the original (absolute) path under the target, so locate the dump by name.
    $zip = Get-ChildItem -LiteralPath $RestoreStaging -Recurse -Filter 'gitea-dump-*.zip' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) { throw "Restored snapshot contains no gitea-dump-*.zip under $RestoreStaging." }

    # --- 5. expand the dump -------------------------------------------------
    $expandDir = Join-Path $RestoreStaging 'expanded'
    Write-Host "[boxstrapper] Expanding $($zip.Name)..." -ForegroundColor Cyan
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expandDir -Force

    $dumpCustom = Join-Path $expandDir 'custom'
    $dumpData   = Join-Path $expandDir 'data'
    $dumpRepos  = Join-Path $expandDir 'repos'
    $dumpSql    = Join-Path $expandDir 'gitea-db.sql'
    if (-not (Test-Path -LiteralPath $dumpSql)) { throw "Dump has no gitea-db.sql at $dumpSql; cannot restore the database." }

    # --- 5a. files: custom/ + data/ into <WorkDir>; repos/ into the repo ROOT ---
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

    # --- 5b. rebuild the SQLite DB from the SQL dump ------------------------
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

    # --- 5c. patch RUN_USER to THIS box's machine account -------------------
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
    if ($stoppedService) {
        Write-Host "[boxstrapper] Restarting '$ServiceName'..." -ForegroundColor Cyan
        try { Start-Service -Name $ServiceName }
        catch { Write-Warning "[boxstrapper] Failed to restart '$ServiceName': $($_.Exception.Message)" }
    }
    # Best-effort cleanup of the (large) restore staging tree.
    if (Test-Path -LiteralPath $RestoreStaging) {
        Remove-Item -LiteralPath $RestoreStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 6. probe for real readiness (a 'Running' NSSM service can still be crash-looping) ---
$ready = $false
foreach ($attempt in 1..10) {
    try {
        Invoke-WebRequest 'http://localhost:3000' -UseBasicParsing -TimeoutSec 3 | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
if ($ready) {
    Write-Host "[boxstrapper] Restore complete -- Gitea is responding at http://localhost:3000" -ForegroundColor Green
} else {
    Write-Warning "Restore applied but http://localhost:3000 isn't answering yet. Check $WorkDir\log\service-stderr.log (a RUN_USER or path mismatch is the usual cause)."
}
