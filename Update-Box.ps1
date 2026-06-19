#Requires -Version 5
<#
.SYNOPSIS
    Idempotent "update the box": apply the choco manifest and configure tools.
.DESCRIPTION
    Safe to re-run any time. Installs everything in packages.config (skipping
    what is already present), then installs the VS Code extensions listed in
    vs-extensions.txt. Add further idempotent setup steps as a new numbered section below.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-Path {
    # Pull newly-installed tools onto PATH for the current session.
    if (-not $env:ChocolateyInstall) {
        $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey'
    }
    $profileModule = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    if (Test-Path $profileModule) {
        Import-Module $profileModule -ErrorAction SilentlyContinue
        if (Get-Command 'Update-SessionEnvironment' -ErrorAction SilentlyContinue) {
            Update-SessionEnvironment
        }
    }
}

function Read-Secrets {
    # Parse the INI secrets file into a hashtable. Value = everything after the first '='
    # (so base64 tokens ending in '==' survive); '#' comments and blank lines are ignored.
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

if (-not (Test-Admin)) {
    throw 'Update-Box.ps1 must run in an elevated PowerShell (Chocolatey needs admin).'
}

# --- 0. secrets ------------------------------------------------------------
# The single source of secrets for the box. On a fresh box this file doesn't exist yet, so we
# seed it from the committed template and stop, letting the user fill it in before we provision.
$secretsFile = Join-Path $PSScriptRoot 'secrets.ini'
$exampleFile = Join-Path $PSScriptRoot 'secrets.example'
if (-not (Test-Path $secretsFile)) {
    if (-not (Test-Path $exampleFile)) { throw "Neither secrets.ini nor secrets.example found in $PSScriptRoot." }
    Copy-Item -LiteralPath $exampleFile -Destination $secretsFile
    Write-Host    "[boxstrapper] Created $secretsFile from the template." -ForegroundColor Cyan
    Write-Warning "Fill in your secrets (leave a key blank to skip that feature), then re-run Update-Box.ps1."
    return
}
$secrets = Read-Secrets -Path $secretsFile

# --- 1. apply the choco manifest -------------------------------------------
$manifest = Join-Path $PSScriptRoot 'packages.config'
# Jenkins' choco package ABORTS if no JDK is visible, and choco does not refresh THIS process's env
# mid-manifest -- so install the JDK first and pull JAVA_HOME onto this session before the manifest
# reaches the jenkins package. temurin21 is also in packages.config; this is just an ordering fix.
Write-Host "[boxstrapper] Ensuring a JDK is present for Jenkins (temurin21)..." -ForegroundColor Cyan
choco install temurin21 -y
Update-Path
Write-Host "[boxstrapper] Applying choco manifest: $manifest" -ForegroundColor Cyan
choco install $manifest -y
Update-Path

# --- 2. VS Code extensions -------------------------------------------------
$extFile = Join-Path $PSScriptRoot 'vs-extensions.txt'
if (Get-Command 'code' -ErrorAction SilentlyContinue) {
    if (Test-Path $extFile) {
        Write-Host "[boxstrapper] Installing VS Code extensions from $extFile" -ForegroundColor Cyan
        Get-Content $extFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object {
                Write-Host "  + $_"
                code --install-extension $_
            }
    }
} else {
    Write-Warning "VS Code ('code') is not on PATH yet; skipping extensions. Open a new shell and re-run Update-Box.ps1."
}

# --- 3. Gitea service (nssm-supervised; restores the latest offsite backup on an empty box, see ---
#        Gitea-Setup.ps1 -- it configures the service, restores if there's a snapshot, then starts once).
#        The R2/restic creds are the same ones passed to the backup setup in section 8.
& (Join-Path $PSScriptRoot 'gitea\Gitea-Setup.ps1') `
    -R2AccountId    $secrets['R2_ACCOUNT_ID'] `
    -R2Bucket       $secrets['R2_BUCKET'] `
    -R2AccessKeyId  $secrets['R2_ACCESS_KEY_ID'] `
    -R2SecretKey    $secrets['R2_SECRET_ACCESS_KEY'] `
    -ResticPassword $secrets['RESTIC_PASSWORD']

# --- 4. Jenkins service (choco installs its OWN auto-start WinSW service; Jenkins-Setup.ps1 just ---
#        rebinds it loopback-only at 127.0.0.1:8080 and serves it under /jenkins -- no secrets). ---
& (Join-Path $PSScriptRoot 'Jenkins-Setup.ps1')

# --- 5. Tailscale (joins the tailnet + publishes Gitea (/) and Jenkins (/jenkins); skips if no auth key) ---
& (Join-Path $PSScriptRoot 'Tailscale-Setup.ps1') -AuthKey $secrets['TS_AUTHKEY']

# --- 6. Healthchecks.io heartbeat (dead-man's switch; skips if no URL) -------
& (Join-Path $PSScriptRoot 'Healthchecks-Setup.ps1') -PingUrl $secrets['HC_PING_URL']

# --- 7. Autologon for the admin desktop session (skips if no password) ------
& (Join-Path $PSScriptRoot 'Autologon-Setup.ps1') -Password $secrets['AUTOLOGON_PASSWORD']

# --- 8. Gitea offsite backup (gitea dump -> restic -> Cloudflare R2; skips if unconfigured) ---
& (Join-Path $PSScriptRoot 'gitea\Gitea-Backup-Setup.ps1') `
    -SecretsFile    $secretsFile `
    -R2AccountId    $secrets['R2_ACCOUNT_ID'] `
    -R2Bucket       $secrets['R2_BUCKET'] `
    -R2AccessKeyId  $secrets['R2_ACCESS_KEY_ID'] `
    -R2SecretKey    $secrets['R2_SECRET_ACCESS_KEY'] `
    -ResticPassword $secrets['RESTIC_PASSWORD']

# --- 9. other idempotent setup steps go here -------------------------------
# (settings sync, dotfiles, etc.)

Write-Host '[boxstrapper] Done.' -ForegroundColor Green
