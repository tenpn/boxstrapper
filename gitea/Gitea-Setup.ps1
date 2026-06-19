#Requires -Version 5
<#
.SYNOPSIS
    Register Gitea as a Windows service supervised by NSSM. Idempotent.
.DESCRIPTION
    Follows the general path of https://docs.gitea.com/installation/windows-service
    but uses NSSM (the Non-Sucking Service Manager) instead of sc.exe to install
    and supervise the service, so crashes get restarted and stdout/stderr are logged.

    Assumes the 'gitea' and 'nssm' choco packages are already installed -- Update-Box.ps1
    installs them from packages.config before calling this. Safe to re-run: an existing
    service is reconfigured in place rather than recreated.

    On first start with no app.ini, Gitea serves its web installer on
    http://localhost:3000 -- finish setup there (or drop in a pre-baked app.ini). Remote access is
    over Tailscale (Tailscale-Setup.ps1 runs `tailscale serve` against this loopback port).

    RESTORE: if the R2/restic creds are given (Update-Box.ps1 passes them, same as it does to
    Gitea-Backup-Setup.ps1), this configures the service but does NOT start it, calls the internal
    Restore-Gitea.ps1 worker while it's stopped, then starts the service exactly once. So a rebuilt box
    that has an offsite backup comes up directly on the restored data instead of being started empty by
    setup and then bounced by a separate restore. A no-op unless the box has no data yet AND a snapshot
    exists; an unconfigured/sandbox box just starts to the web installer as before.
#>

[CmdletBinding()]
param(
    [string]$ServiceName = 'gitea',
    # Keep this path space-free: the service's command line is stored unquoted,
    # so a space in the config path would split Gitea's --config argument.
    [string]$WorkDir     = 'C:\gitea',
    # Public hostname Gitea is reached at on the tailnet -- its MagicDNS name, e.g.
    # 'box.tailnet-name.ts.net'. Sets ROOT_URL/DOMAIN so Gitea emits correct links.
    # Leave empty for local sandbox testing (Gitea derives the URL from the request).
    [string]$PublicHostname = '',
    # R2 + restic credentials for the optional pre-start restore (forwarded to the Restore-Gitea.ps1
    # worker). Update-Box.ps1 passes these from secrets.ini, same as it does to Gitea-Backup-Setup.ps1.
    # Blank => no restore (e.g. local sandbox testing); the box just starts to the web installer.
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Gitea-Setup.ps1 must run in an elevated PowerShell (creating a service needs admin).'
}
if ($WorkDir -match '\s') {
    throw "WorkDir '$WorkDir' contains spaces. Pick a space-free path to avoid service argument-quoting issues."
}
if (-not $env:ChocolateyInstall) {
    $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey'
}

# --- locate the tools we depend on -----------------------------------------
$nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
if (-not $nssmCmd) { throw "nssm is not on PATH. Install the 'nssm' choco package first (it's in packages.config)." }
$nssm = $nssmCmd.Source

function Resolve-GiteaExe {
    # Point NSSM at the REAL gitea.exe, never the choco 'bin' shim: a shim process
    # exits right after launching its target, which NSSM would read as a crash loop.
    $direct = Join-Path $env:ChocolateyInstall 'lib\gitea\tools\gitea.exe'
    if (Test-Path $direct) { return (Resolve-Path $direct).Path }
    $libRoot = Join-Path $env:ChocolateyInstall 'lib'
    if (Test-Path $libRoot) {
        $hit = Get-ChildItem $libRoot -Recurse -Filter 'gitea.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\bin\\' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command gitea -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Could not locate gitea.exe. Is the 'gitea' choco package installed?"
}

$giteaExe   = Resolve-GiteaExe
$confDir    = Join-Path $WorkDir 'custom\conf'
$configPath = Join-Path $confDir 'app.ini'
$logDir     = Join-Path $WorkDir 'log'

Write-Host "[boxstrapper] Gitea exe : $giteaExe" -ForegroundColor DarkGray
Write-Host "[boxstrapper] Gitea home: $WorkDir"   -ForegroundColor DarkGray

# --- working directories (Gitea writes data/config/logs under here) --------
foreach ($d in @($WorkDir, $confDir, $logDir, (Join-Path $WorkDir 'data'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# --- pre-seed a minimal app.ini (only if absent) ---------------------------
# Gitea checks the OS user it runs as against RUN_USER and refuses to start on a
# mismatch. Under nssm's default LocalSystem the service runs as the machine
# account "<COMPUTERNAME>$", so that must be RUN_USER. We also pin an ABSOLUTE
# SQLite path (relative paths break under a service). Everything else is left to
# Gitea's web installer at http://localhost:3000, which rewrites this file on
# completion -- hence we never overwrite an existing one.
if (-not (Test-Path $configPath)) {
    $runUser = "$env:COMPUTERNAME`$"
    $dbPath  = ($WorkDir -replace '\\', '/') + '/data/gitea.db'
    # When fronted by Tailscale serve, ROOT_URL/DOMAIN make Gitea emit correct links.
    $hostLines = ''
    if ($PublicHostname) {
        $hostLines = "ROOT_URL = https://$PublicHostname/`r`nDOMAIN   = $PublicHostname`r`n"
    }
    @"
RUN_USER = $runUser

[server]
; Bind to loopback only -- the box is reached via `tailscale serve` running locally
; (it proxies the tailnet to this port), so Gitea must never be exposed on the LAN/WAN directly.
HTTP_ADDR = 127.0.0.1
HTTP_PORT = 3000
$hostLines
[database]
DB_TYPE = sqlite3
PATH    = $dbPath

[service]
; Collaborator instance: no open sign-ups, and nothing is visible without a login.
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW  = true
"@ | Set-Content -Path $configPath -Encoding ASCII
    Write-Host "[boxstrapper] Wrote seed config $configPath (RUN_USER=$runUser, bind=127.0.0.1)" -ForegroundColor DarkGray
} else {
    Write-Host "[boxstrapper] Config already present at $configPath; left untouched." -ForegroundColor DarkGray
}

# --- install the service if it doesn't exist yet ---------------------------
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "[boxstrapper] Service '$ServiceName' exists; updating its configuration." -ForegroundColor Green
} else {
    Write-Host "[boxstrapper] Installing '$ServiceName' service via nssm..." -ForegroundColor Cyan
    & $nssm install $ServiceName $giteaExe
    if ($LASTEXITCODE -ne 0) { throw "nssm install $ServiceName failed (exit code $LASTEXITCODE)." }
}

# --- (re)apply configuration (idempotent: setting identical values is a no-op)
& $nssm set $ServiceName Application         $giteaExe                          | Out-Null
& $nssm set $ServiceName AppDirectory        $WorkDir                           | Out-Null
& $nssm set $ServiceName AppParameters       "web --config $configPath"         | Out-Null
& $nssm set $ServiceName AppEnvironmentExtra "GITEA_WORK_DIR=$WorkDir"          | Out-Null
& $nssm set $ServiceName DisplayName         'Gitea'                            | Out-Null
& $nssm set $ServiceName Description         'Gitea self-hosted git service'    | Out-Null
& $nssm set $ServiceName Start               'SERVICE_AUTO_START'               | Out-Null
& $nssm set $ServiceName AppStdout           (Join-Path $logDir 'service-stdout.log') | Out-Null
& $nssm set $ServiceName AppStderr           (Join-Path $logDir 'service-stderr.log') | Out-Null
# To run under a dedicated account instead of LocalSystem (remember to set RUN_USER
# in app.ini to that account, and grant it "Log on as a service"):
#   & $nssm set $ServiceName ObjectName ".\gitea" "<password>"
# Optional, per the docs -- delayed start on busy boxes, or wait for a DB service:
#   & $nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START
#   & $nssm set $ServiceName DependOnService mariadb   # if using an external DB service

# --- restore an offsite backup BEFORE the first start, if applicable -------
# The service is configured but NOT started yet, so a fresh box that has an offsite backup is restored
# onto disk here and then started once (below) on the recovered data -- no start-then-bounce churn.
# The worker leaves the service alone (we own the start). Best-effort: a restore hiccup must never wedge
# provisioning, so we note it and carry on to a normal start (the box then shows the web installer).
# A no-op without R2 creds, on a box that already has data, or when there's no snapshot to restore.
if ($R2AccountId) {
    try {
        & (Join-Path $PSScriptRoot 'Restore-Gitea.ps1') `
            -R2AccountId $R2AccountId -R2Bucket $R2Bucket -R2AccessKeyId $R2AccessKeyId `
            -R2SecretKey $R2SecretKey -ResticPassword $ResticPassword -WorkDir $WorkDir
    } catch {
        Write-Host "[boxstrapper] Auto-restore skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
    } finally {
        # Restore-Gitea.ps1 runs inline (same process) and sets restic/R2 creds in this env; clear them.
        Remove-Item Env:RESTIC_REPOSITORY, Env:RESTIC_PASSWORD, Env:AWS_ACCESS_KEY_ID, `
                    Env:AWS_SECRET_ACCESS_KEY, Env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
    }
}

# --- ensure it's running (single start point, on restored data if we just restored) ---
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) { throw "Service '$ServiceName' not found after install." }
if ($svc.Status -ne 'Running') {
    Write-Host "[boxstrapper] Starting '$ServiceName'..." -ForegroundColor Cyan
    # Start-Service waits for the SCM to report Running and throws on a start
    # failure -- cleaner and more honest than 'nssm start', whose CLI prints a
    # scary-looking "Unexpected status SERVICE_START_PENDING" while it's merely
    # still initializing.
    Start-Service -Name $ServiceName
} else {
    Write-Host "[boxstrapper] '$ServiceName' already running." -ForegroundColor Green
}

# A 'Running' service only means nssm's wrapper is up -- nssm will keep restarting
# a crashing gitea.exe while still reporting Running. Probe the web port for the
# real health signal.
$ready = $false
foreach ($attempt in 1..10) {
    try {
        Invoke-WebRequest 'http://localhost:3000' -UseBasicParsing -TimeoutSec 3 | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
if ($ready) {
    Write-Host "[boxstrapper] Gitea is responding -- finish setup at http://localhost:3000" -ForegroundColor Green
} else {
    Write-Warning "Gitea service registered but http://localhost:3000 isn't answering yet. Check $logDir\service-stderr.log."
}
