#Requires -Version 5
<#
.SYNOPSIS
    Load secrets.ini and point THIS shell at the restic -> Cloudflare R2 repo, so you can run
    `restic snapshots`, `restic restore`, etc. by hand.
.DESCRIPTION
    A dev convenience that does what the backup tasks do internally: parse secrets.ini and call
    Set-ResticEnv (from ..\Backup-Common.ps1) with the five R2/restic creds. The normal flow never
    needs this -- the SYSTEM backup/restore tasks set their own env -- it's only for poking at the
    shared offsite repo interactively: confirming a snapshot landed before wiping a box, listing or
    forgetting snapshots, an ad-hoc restore.

    DOT-SOURCE IT so the env survives in your shell:

        . .\testing\Enter-ResticEnv.ps1
        restic snapshots --tag gitea --last
        restic snapshots --tag jenkins --last
        Clear-ResticEnv          # drop the creds from the shell when done

    Running it normally (.\testing\Enter-ResticEnv.ps1) would set the env only in the script's child
    scope, which vanishes the moment it returns -- so it warns and does nothing. Dot-sourcing also
    brings Backup-Common's helpers (Set-ResticEnv / Clear-ResticEnv / Read-Secrets / ...) into your shell.

    This does NOT need an elevated shell -- it only sets env vars; nothing here touches a service.
.PARAMETER SecretsFile
    Path to secrets.ini. Defaults to the repo-root one beside Update-Box.ps1 (the single source of secrets).
#>
[CmdletBinding()]
param(
    [string]$SecretsFile
)

# Resolve this script's folder to anchor ..\Backup-Common.ps1 / ..\secrets.ini. This MUST be done in
# the body, not a param default: in some PowerShell versions $PSScriptRoot is EMPTY inside a param()
# default when the script is dot-sourced (the body still has it), which is the Join-Path binding error
# that bit us. $PSScriptRoot is also empty when the code is pasted / run via the editor's "Run
# Selection" -- there $PSCommandPath and MyInvocation.MyCommand.Path are empty too, so we can't anchor
# and must tell the user to dot-source the FILE. Fall back through all three before giving up.
$scriptDir = $PSScriptRoot
if (-not $scriptDir -and $PSCommandPath)               { $scriptDir = Split-Path -Parent $PSCommandPath }
if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) {
    Write-Warning "Run this by DOT-SOURCING THE FILE, not by pasting it or using the editor's 'Run Selection':"
    Write-Host    "[boxstrapper] > . .\testing\Enter-ResticEnv.ps1" -ForegroundColor Cyan
    return
}

# The env we set only outlives this script if it ran in the caller's scope, i.e. dot-sourced.
# When dot-sourced, InvocationName is '.'; otherwise warn and bail rather than silently no-op.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Warning "Run this DOT-SOURCED so the restic env persists in your shell:"
    Write-Host    "[boxstrapper] > . $($MyInvocation.MyCommand.Path)" -ForegroundColor Cyan
    return
}

if (-not $SecretsFile) { $SecretsFile = Join-Path $scriptDir '..\secrets.ini' }

. (Join-Path $scriptDir '..\Backup-Common.ps1')

if (-not (Test-Path -LiteralPath $SecretsFile)) {
    Write-Warning "[boxstrapper] No secrets file at $SecretsFile; nothing to load."
    return
}
$secrets = Read-Secrets -Path $SecretsFile

# The five creds Set-ResticEnv needs, under the same keys Update-Box.ps1 parses.
$accountId = $secrets['R2_ACCOUNT_ID']
$bucket    = $secrets['R2_BUCKET']
$accessKey = $secrets['R2_ACCESS_KEY_ID']
$secretKey = $secrets['R2_SECRET_ACCESS_KEY']
$password  = $secrets['RESTIC_PASSWORD']

$missing = @()
foreach ($pair in @(@('R2_ACCOUNT_ID', $accountId),       @('R2_BUCKET', $bucket),
                    @('R2_ACCESS_KEY_ID', $accessKey),    @('R2_SECRET_ACCESS_KEY', $secretKey),
                    @('RESTIC_PASSWORD', $password))) {
    if (-not $pair[1]) { $missing += $pair[0] }
}
if ($missing.Count) {
    Write-Warning "[boxstrapper] secrets.ini is missing/blank: $($missing -join ', '). Cloudflare R2 backups aren't configured; not setting restic env."
    return
}

Set-ResticEnv -R2AccountId $accountId -R2Bucket $bucket -R2AccessKeyId $accessKey `
              -R2SecretKey $secretKey -ResticPassword $password

Write-Host "[boxstrapper] restic env set for this shell -> $($env:RESTIC_REPOSITORY)" -ForegroundColor Green
Write-Host "[boxstrapper] Try:  restic snapshots --tag gitea --last" -ForegroundColor DarkGray
Write-Host "[boxstrapper]       restic snapshots --tag jenkins --last" -ForegroundColor DarkGray
Write-Host "[boxstrapper] Done: Clear-ResticEnv  (drops the creds from this shell)" -ForegroundColor DarkGray
