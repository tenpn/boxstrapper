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
