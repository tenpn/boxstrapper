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

function Resolve-JavaHome {
    # The temurin21 MSI sets the machine PATH but NOT JAVA_HOME by default, and the jenkins choco
    # package ABORTS unless JAVA_HOME is set -- so derive the JDK location ourselves. Prefer a
    # JAVA_HOME the MSI did set, else find the installed JDK by its well-known install roots.
    $jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($jh -and (Test-Path (Join-Path $jh 'bin\java.exe'))) { return $jh }
    foreach ($root in @((Join-Path ${env:ProgramFiles} 'Eclipse Adoptium'),
                        (Join-Path ${env:ProgramFiles} 'Microsoft\jdk'))) {
        if (Test-Path $root) {
            $hit = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                   Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
                   Sort-Object Name -Descending | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
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
# Jenkins' choco package ABORTS unless JAVA_HOME is set, but temurin21's MSI sets the machine PATH
# and NOT JAVA_HOME -- so install the JDK first, then set JAVA_HOME (this process so the manifest's
# choco child inherits it, and permanently so re-runs/other tools see it) BEFORE the manifest reaches
# the jenkins package. temurin21 is also in packages.config; this is the ordering + JAVA_HOME fix.
Write-Host "[boxstrapper] Ensuring a JDK is present for Jenkins (temurin21)..." -ForegroundColor Cyan
choco install temurin21 -y
Update-Path
$javaHome = Resolve-JavaHome
if ($javaHome) {
    $env:JAVA_HOME = $javaHome
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'Machine')
    Write-Host "[boxstrapper] JAVA_HOME = $javaHome" -ForegroundColor DarkGray
} else {
    Write-Warning "Installed temurin21 but could not locate the JDK to set JAVA_HOME; the jenkins package may fail to install."
}
# sysinternals' choco package pins a SHA256 for SysinternalsSuite.zip, but Microsoft republishes that
# zip IN PLACE at the same URL, so the pinned hash goes stale (and the manifest install fails on it)
# until the maintainer catches up. The download is from Microsoft's own URL, so install it here with
# --ignore-checksums scoped to JUST this package; the manifest then skips it (already installed).
# Drop this line once the upstream package refreshes its checksum.
Write-Host "[boxstrapper] Installing sysinternals (skipping its stale upstream checksum)..." -ForegroundColor Cyan
choco install sysinternals -y --ignore-checksums
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

# --- 3. Tailscale (join the tailnet + reset the published `serve` surface to a clean slate) --------
#        Runs BEFORE Gitea/Jenkins ON PURPOSE: it gets the box onto the tailnet so the public MagicDNS
#        name exists, and each service script then publishes ITSELF on the tailnet (and Gitea reads that
#        name for its ROOT_URL). Skips (box stays local) if no auth key.
& (Join-Path $PSScriptRoot 'Tailscale-Setup.ps1') -AuthKey $secrets['TS_AUTHKEY']

# --- 4. Gitea service (nssm-supervised; Gitea-Setup.ps1 configures the service and ALSO owns -- as ---
#        self-contained sub-features, so this ONE call toggles them all -- its ROOT_URL/tailnet publish at
#        /git, its Healthchecks heartbeat, an auto-RESTORE of the latest offsite backup onto an empty box
#        before first start, AND the daily gitea-dump->restic->R2 BACKUP task (it calls Gitea-Backup-Setup
#        itself, the way it calls Healthchecks-Setup). We only PARSE the secrets here and hand them in as
#        params (HC_GITEA_PING_URL -> -HeartbeatPingUrl); the R2/restic creds + the secrets.ini PATH feed
#        both the restore and the backup. The script itself never reads secrets.ini. ---
& (Join-Path $PSScriptRoot 'gitea\Gitea-Setup.ps1') `
    -R2AccountId      $secrets['R2_ACCOUNT_ID'] `
    -R2Bucket         $secrets['R2_BUCKET'] `
    -R2AccessKeyId    $secrets['R2_ACCESS_KEY_ID'] `
    -R2SecretKey      $secrets['R2_SECRET_ACCESS_KEY'] `
    -ResticPassword   $secrets['RESTIC_PASSWORD'] `
    -HeartbeatPingUrl $secrets['HC_GITEA_PING_URL'] `
    -SecretsFile      $secretsFile

# --- 5. Jenkins service (choco installs its OWN auto-start WinSW service; Jenkins-Setup.ps1 rebinds ---
#        it loopback-only at 127.0.0.1:8080, serves it under /jenkins, pre-installs jenkins\plugins.txt,
#        and seeds an admin user (skipping the setup wizard). Jenkins-Setup ALSO owns -- as self-contained
#        sub-features, so this ONE call toggles them all -- its tailnet publish, its Healthchecks heartbeat,
#        an auto-RESTORE of the latest offsite snapshot onto a fresh box before first start, AND the weekly
#        restic->R2 BACKUP task (it calls Jenkins-Backup-Setup itself, the way it calls Healthchecks-Setup).
#        We only PARSE the secrets here and hand them in as params; a blank JENKINS_ADMIN_PASSWORD keeps the
#        interactive wizard. The R2/restic creds + the secrets.ini PATH feed both the restore and backup. ---
& (Join-Path $PSScriptRoot 'jenkins\Jenkins-Setup.ps1') `
    -AdminUser        $secrets['JENKINS_ADMIN_USER'] `
    -AdminPassword    $secrets['JENKINS_ADMIN_PASSWORD'] `
    -HeartbeatPingUrl $secrets['HC_JENKINS_PING_URL'] `
    -SecretsFile      $secretsFile `
    -R2AccountId      $secrets['R2_ACCOUNT_ID'] `
    -R2Bucket         $secrets['R2_BUCKET'] `
    -R2AccessKeyId    $secrets['R2_ACCESS_KEY_ID'] `
    -R2SecretKey      $secrets['R2_SECRET_ACCESS_KEY'] `
    -ResticPassword   $secrets['RESTIC_PASSWORD']

# --- 6. Autologon for the admin desktop session (skips if no password) ------
& (Join-Path $PSScriptRoot 'Autologon-Setup.ps1') -Password $secrets['AUTOLOGON_PASSWORD']

# --- 7. other idempotent setup steps go here -------------------------------
# (settings sync, dotfiles, etc.)

Write-Host '[boxstrapper] Done.' -ForegroundColor Green
