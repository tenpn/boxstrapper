#Requires -Version 5
<#
.SYNOPSIS
    Shared helpers for the restic -> Cloudflare R2 backup/restore scripts. Dot-sourced, not run directly.
.DESCRIPTION
    The whole backup family shares this service-agnostic plumbing, the same way Gitea-Setup/Jenkins-Setup
    share Healthchecks-Setup.ps1 + Send-Heartbeat.ps1 for their heartbeat:
      - Register-ResticBackup.ps1            (the SYSTEM-task registrar, at the repo root)
      - gitea\Backup-Gitea.ps1 / jenkins\Backup-Jenkins.ps1   (the backup workers)
      - gitea\Restore-Gitea.ps1 / jenkins\Restore-Jenkins.ps1 (the restore workers)
    Each dot-sources this file: from a root script via `. (Join-Path $PSScriptRoot 'Backup-Common.ps1')`,
    from a gitea\ / jenkins\ script via `. (Join-Path $PSScriptRoot '..\Backup-Common.ps1')`.

    It also holds Suspend-HeartbeatTask / Resume-HeartbeatTask, so backups don't trigger false-positive health check failures.

    This file ONLY defines functions (no top-level side effects), so dot-sourcing is safe; callers own
    their own Set-StrictMode / $ErrorActionPreference. The service-SPECIFIC bits deliberately stay in each
    service's own script: gitea dump+zip vs the JENKINS_HOME tree, the SQLite/RUN_USER restore vs the
    marker/tree-copy restore, Resolve-GiteaExe vs Resolve-JenkinsHome, and each forget policy/tag.

    Stays Windows PowerShell 5.1-safe (no ternary / null-coalescing) because the workers run as
    powershell.exe SYSTEM scheduled tasks, not pwsh.
#>

function Read-Secrets {
    # Parse the INI secrets file into a hashtable. Value = everything after the first '=' (so base64
    # tokens ending in '==' survive); '#' comments and blank lines are ignored. Same rule as Update-Box.ps1.
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
    # $ErrorActionPreference='Stop' (a real PS 5.1 gotcha). Caller checks .Code. Optionally feed a file
    # to stdin (for sqlite3 < dump.sql).
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

function Set-ResticEnv {
    # Point restic at the R2 repo via process-scoped env (never persisted). Caller guards blank creds.
    param(
        [string]$R2AccountId, [string]$R2Bucket, [string]$R2AccessKeyId,
        [string]$R2SecretKey, [string]$ResticPassword
    )
    $env:RESTIC_REPOSITORY     = "s3:https://$R2AccountId.r2.cloudflarestorage.com/$R2Bucket"
    $env:RESTIC_PASSWORD       = $ResticPassword
    $env:AWS_ACCESS_KEY_ID     = $R2AccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $R2SecretKey
    $env:AWS_DEFAULT_REGION    = 'auto'
}

function Clear-ResticEnv {
    # Drop the restic/R2 env this process set, so secrets don't linger in the provisioning shell.
    Remove-Item Env:RESTIC_REPOSITORY, Env:RESTIC_PASSWORD, Env:AWS_ACCESS_KEY_ID, `
                Env:AWS_SECRET_ACCESS_KEY, Env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
}

function Initialize-ResticRepo {
    # Create the restic repo on R2 if absent (restic refuses to re-init), probing with 'cat config' first
    # -- which also validates the R2 creds + password end to end. Assumes Set-ResticEnv has run. The repo
    # is shared by both services, so this is usually a no-op confirming it exists. Throws on real failure.
    param([Parameter(Mandatory)][string]$ResticExe)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $ResticExe cat config 2>&1 | Out-Null
    $exists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $eap
    if ($exists) {
        Write-Host "[boxstrapper] restic repo already initialised at $($env:RESTIC_REPOSITORY)." -ForegroundColor Green
    } else {
        Write-Host "[boxstrapper] Initialising restic repo at $($env:RESTIC_REPOSITORY)..." -ForegroundColor Cyan
        & $ResticExe init
        if ($LASTEXITCODE -ne 0) { throw "restic init failed (exit $LASTEXITCODE). Check the R2 creds/bucket and RESTIC_PASSWORD." }
        Write-Host "[boxstrapper] restic repo initialised." -ForegroundColor Green
    }
}

function Send-BackupPing {
    # Best-effort Healthchecks.io ping: the success URL on a clean run, <url>/fail otherwise, with a
    # capped log tail as the body. A monitoring failure must NEVER throw. Blank URL => skip.
    param([string]$PingUrl, [bool]$Ok, [string]$Detail = '', [int]$TimeoutSec = 10)
    if (-not $PingUrl) {
        Write-Host "[boxstrapper] No backup ping URL set; skipped status ping." -ForegroundColor DarkGray
        return
    }
    $target = $PingUrl
    if (-not $Ok) { $target = "$PingUrl/fail" }
    $body = $Detail
    if ($body.Length -gt 1000) { $body = $body.Substring(0, 1000) }
    try {
        Invoke-RestMethod -Uri $target -Method Post -Body $body -TimeoutSec $TimeoutSec | Out-Null
        Write-Host "[boxstrapper] Backup status pinged: $target"
    } catch {
        Write-Warning "[boxstrapper] Healthchecks ping to $target failed: $($_.Exception.Message)"
    }
}

function Suspend-HeartbeatTask {
    # Disable a service's Healthchecks heartbeat task (Healthchecks-Setup.ps1's 'boxstrapper-heartbeat*')
    # for the window in which a backup worker has that service STOPPED, so a planned stop isn't reported
    # as an outage
    # Returns $true only if the task existed, was enabled, and is now disabled (the caller must then 
    # Resume-HeartbeatTask in its finally). 
    # Best-effort: a missing task (heartbeat not configured) or a scheduler hiccup just returns $false 
    # -- monitoring must never affect the backup itself.
    param([Parameter(Mandatory)][string]$TaskName)
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "[boxstrapper] No heartbeat task '$TaskName'; nothing to suspend." -ForegroundColor DarkGray
            return $false
        }
        if ($task.State -eq 'Disabled') { return $false }   # not ours to re-enable
        Disable-ScheduledTask -TaskName $TaskName | Out-Null
        Write-Host "[boxstrapper] Suspended heartbeat task '$TaskName' for the backup window." -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Warning "[boxstrapper] Could not suspend heartbeat task '$TaskName': $($_.Exception.Message)"
        return $false
    }
}

function Resume-HeartbeatTask {
    # Undo Suspend-HeartbeatTask once the service is back: wait for the service to actually answer,
    # re-enable the task, then fire it once so a fresh SUCCESS ping goes out right away.
    #   1. wait for HTTP 200 on the task's own -HealthUrl so we know it's up.
    #   2. Enable-ScheduledTask -- if the scheduler decides a run was missed while disabled
    #      (StartWhenAvailable), it fires now against a service that is already ready;
    #   3. Start-ScheduledTask -- make double-sure we don't leave a gap.
    # Best-effort throughout: a timeout just re-enables anyway (the next scheduled probe reports the truth).
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [int]$ReadyWaitSec = 180
    )
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { return }
        $healthUrl = ''
        $args = [string]$task.Actions[0].Arguments
        if ($args -match '-HealthUrl\s+"([^"]+)"') { $healthUrl = $matches[1] }
        if ($healthUrl) {
            $deadline = (Get-Date).AddSeconds($ReadyWaitSec)
            $ready = $false
            while ((Get-Date) -lt $deadline) {
                try {
                    $resp = Invoke-WebRequest $healthUrl -UseBasicParsing -TimeoutSec 5
                    if ($resp.StatusCode -eq 200) { $ready = $true; break }
                } catch { }
                Start-Sleep -Seconds 3
            }
            if ($ready) { Write-Host "[boxstrapper] $healthUrl is answering again." -ForegroundColor DarkGray }
            else        { Write-Warning "[boxstrapper] $healthUrl not answering after ${ReadyWaitSec}s; re-enabling the heartbeat anyway." }
        }
        Enable-ScheduledTask -TaskName $TaskName | Out-Null
        Start-ScheduledTask  -TaskName $TaskName
        Write-Host "[boxstrapper] Resumed heartbeat task '$TaskName' and sent a fresh ping." -ForegroundColor DarkGray
    } catch {
        Write-Warning "[boxstrapper] Could not resume heartbeat task '$TaskName': $($_.Exception.Message) -- re-enable it by hand (Enable-ScheduledTask)."
    }
}

function Resolve-RestoreRequest {
    # Validate the -Restore / -BeforeDate pair (as passed to bootstrap.ps1 / Update-Box.ps1) into a
    # normalised mode plus, for 'Before', a [datetimeoffset] boundary. The ONE authority for the restore
    # argument rules, so both entry points reject the same bad combinations with the same clear message.
    # Throws (before the box is touched) on: an unknown keyword, -Restore Before with no date, a
    # -BeforeDate given with any other keyword, or an unparseable date. See [[gitea-restore-from-snapshot]].
    param([string]$Restore = 'None', [string]$BeforeDate = '')
    $mode = $Restore
    if (-not $mode) { $mode = 'None' }
    # Case-insensitive normalise to the canonical keyword (ValidateSet already gates the entry-point
    # params, but this stays correct even when called directly / from a test).
    switch -Regex ($mode) {
        '^(?i)none$'          { $mode = 'None' }
        '^(?i)latest$'        { $mode = 'Latest' }
        '^(?i)showsnapshots$' { $mode = 'ShowSnapshots' }
        '^(?i)before$'        { $mode = 'Before' }
        default { throw "Unknown -Restore '$Restore'. Use None | Latest | Before | ShowSnapshots." }
    }
    $boundary = $null
    if ($mode -eq 'Before') {
        if (-not $BeforeDate) { throw "-Restore Before requires -BeforeDate <yyyy-MM-dd>." }
        # InvariantCulture so 'yyyy-MM-dd' is unambiguous on non-US boxes; AssumeLocal so a bare date
        # means local midnight (the strictly-before boundary). A full 'yyyy-MM-dd HH:mm' is accepted too.
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParse($BeforeDate, [cultureinfo]::InvariantCulture,
                 [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dt)) {
            throw "Could not parse -BeforeDate '$BeforeDate'. Use an ISO date like 2026-07-15."
        }
        $boundary = [datetimeoffset]::new($dt)
    } elseif ($BeforeDate) {
        throw "-BeforeDate only applies to -Restore Before (got -Restore $mode)."
    }
    return [pscustomobject]@{ Mode = $mode; Boundary = $boundary }
}

function Get-ResticSnapshots {
    # List one tag's snapshots in the shared repo as easy-to-select objects. Assumes Set-ResticEnv has run.
    # Returns $null when the repo is UNREACHABLE / not initialised (restic exit != 0) -- distinct from @()
    # for a reachable-but-empty tag; callers must tell these apart (use `if ($null -eq $snaps)`, never
    # `$snaps -eq $null`). The full .Id is carried downstream (not the 8-hex short id) to avoid any
    # ambiguity in the repo Gitea and Jenkins share. StrictMode-safe: only touches id/short_id/time.
    param([Parameter(Mandatory)][string]$ResticExe, [Parameter(Mandatory)][string]$Tag)
    # -q keeps any restic progress chatter out of the JSON that Invoke-Native merges via 2>&1.
    $r = Invoke-Native $ResticExe @('snapshots', '--tag', $Tag, '--json', '-q')
    if ($r.Code -ne 0) { return $null }
    $raw = @()
    # An empty result is '[]', which ConvertFrom-Json yields as a single scalar whose .Count is 1 under
    # 5.1 -- the `| Where-Object { $_ }` filter drops it so an empty tag is a true 0-length array.
    try { $raw = @($r.Output | ConvertFrom-Json | Where-Object { $_ }) } catch { $raw = @() }
    $out = @()
    foreach ($s in $raw) {
        $t = $null
        # restic 'time' is RFC3339 with an offset and stays a String under 5.1; parse to an absolute
        # instant so comparisons are timezone-correct. RoundtripKind tolerates the fractional seconds.
        try {
            $t = [datetimeoffset]::Parse([string]$s.time, [cultureinfo]::InvariantCulture,
                 [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch { $t = $null }
        $out += [pscustomobject]@{ Id = [string]$s.id; ShortId = [string]$s.short_id; Time = $t; TimeRaw = [string]$s.time }
    }
    return ,$out    # unary comma preserves array shape for a single-element result
}
