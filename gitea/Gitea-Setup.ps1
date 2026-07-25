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
    http://localhost:3000 -- finish setup there (or drop in a pre-baked app.ini).

    REMOTE ACCESS / ROUTING is owned HERE. Update-Box.ps1 runs Tailscale-Setup.ps1 first (joins the
    tailnet, clears the `serve` surface), so by the time this runs the box's MagicDNS name exists. This
    script reads that name, sets Gitea's ROOT_URL to https://<name>/git/ (and DOMAIN/SSH_DOMAIN to
    <name>), and publishes Gitea at
    /git via `tailscale serve` (a BARE serve target -- Gitea uses the strip subpath model, serving at
    root while ROOT_URL makes it emit /git-prefixed links). Off the tailnet (sandbox / no auth key) all
    of that is skipped and Gitea just stays loopback-only.

    RESTORE: if the R2/restic creds are given (Update-Box.ps1 passes them from secrets.ini) AND
    -RestoreSnapshotId is non-blank, this configures the service but does NOT start it, calls the
    internal Restore-Gitea.ps1 worker (with that snapshot) while it's stopped, then starts the service
    exactly once. So a rebuilt box that has an offsite backup comes up directly on the restored data
    instead of being started empty by setup and then bounced by a separate restore. -RestoreSnapshotId
    is chosen by Update-Box.ps1 from its -Restore flag: '' = -Restore None (skip restore, backups still
    set up below), 'latest', or a specific snapshot id (-Restore Before). A no-op unless the box has no
    data yet AND that snapshot exists; an unconfigured/sandbox box just starts to the web installer.

    BACKUP: this script also OWNS Gitea's offsite backup (the self-contained-element convention, like the
    heartbeat): when the R2/restic creds are supplied it registers the daily gitea-dump->restic->R2 task
    via the shared Register-ResticBackup.ps1 (handing it the -SecretsFile path the SYSTEM task re-reads). So
    commenting out Gitea's one Update-Box.ps1 call drops the service, its monitoring, its restore, AND its
    backup together. Skips when the creds are blank.
#>

[CmdletBinding()]
param(
    [string]$ServiceName = 'gitea',
    # Keep this path space-free: the service's command line is stored unquoted,
    # so a space in the config path would split Gitea's --config argument.
    [string]$WorkDir     = 'C:\gitea',
    # OPTIONAL override for the public hostname. Normally left empty: this script reads the box's
    # MagicDNS name from Tailscale (Update-Box.ps1 brings Tailscale up FIRST) and uses that for ROOT_URL.
    # Set it only for local/manual use where you want a specific hostname without deriving it.
    [string]$PublicHostname = '',
    # Tailnet sub-path Gitea is published under -- both the `tailscale serve` mount AND the sub-path
    # baked into ROOT_URL (https://<host><Prefix>/). '' = published at the tailnet root.
    [string]$Prefix = '/git',
    # R2 + restic credentials. Power TWO self-contained sub-features this script OWNS: the optional
    # pre-start RESTORE (forwarded to Restore-Gitea.ps1) and the daily restic->R2 BACKUP task (the
    # Register-ResticBackup call near the end). Update-Box.ps1 passes these from secrets.ini.
    # Blank => no restore AND no backup (e.g. local sandbox); the box just starts to the web installer.
    [string]$R2AccountId    = '',
    [string]$R2Bucket       = '',
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$ResticPassword = '',
    # Which snapshot to restore before the first start, chosen by Update-Box.ps1 (it resolves -Restore
    # None|Latest|Before to a concrete value once, up front): '' = don't restore (backups still set up),
    # 'latest' = the most recent, or a full snapshot id. Forwarded to Restore-Gitea.ps1 as -SnapshotId.
    # Defaults to 'latest' so a direct/standalone call keeps the old auto-restore-latest behaviour.
    [string]$RestoreSnapshotId = 'latest',
    # Healthchecks.io ping URL for THIS service's heartbeat (Update-Box.ps1 passes HC_GITEA_PING_URL
    # from secrets.ini). Blank => no heartbeat (non-fatal). Owned here so disabling Gitea -- commenting
    # its one Update-Box call -- also drops its monitoring (the self-contained-element convention).
    [string]$HeartbeatPingUrl = '',
    # Absolute path to secrets.ini, forwarded to the Gitea backup setup so its daily SYSTEM task can
    # re-read secrets at run time (a task argument can't carry secrets safely). Blank => the backup setup
    # falls back to the repo-root secrets.ini next to this gitea\ folder.
    [string]$SecretsFile      = ''
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
# Normalize the sub-path: leading slash, no trailing slash (or '' for root) so ROOT_URL interpolates
# to a clean https://<host><Prefix>/ and `--set-path=<Prefix>` is well-formed.
if ($Prefix -and -not $Prefix.StartsWith('/')) { $Prefix = '/' + $Prefix }
$Prefix = $Prefix.TrimEnd('/')
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

function Resolve-TailscaleExe {
    # Returns the tailscale.exe path, or $null on a box without Tailscale (e.g. a local sandbox) --
    # routing is then skipped, not fatal.
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $known = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $known) { return $known }
    return $null
}

function Get-TailnetHostname {
    # This box's MagicDNS FQDN (trailing dot trimmed) if Tailscale is CONNECTED, else $null. A non-null
    # result implies the backend is Running, which is exactly what gates the serve step below.
    param([string]$TailscaleExe)
    if (-not $TailscaleExe) { return $null }
    try {
        $st = & $TailscaleExe status --json 2>$null | ConvertFrom-Json
        if ($st -and $st.BackendState -eq 'Running' -and $st.Self -and $st.Self.DNSName) {
            return $st.Self.DNSName.TrimEnd('.')
        }
    } catch { }
    return $null
}

function Set-GiteaServerKey {
    # Ensure "<Key> = <Value>" exists in app.ini's [server] section: replace the existing line if
    # present, else insert it right after the [server] header. Line-by-line (not one big regex) so
    # CRLF/LF endings and other sections are left untouched. Returns the (possibly unchanged) text.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $lines     = $Text -split "`r?`n"
    $out       = New-Object System.Collections.Generic.List[string]
    $section   = ''
    $serverIdx = -1
    $done      = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $t   = $raw.Trim()
        if ($t -match '^\[(.+)\]$') {
            $section = $matches[1].Trim().ToLower()
            if ($section -eq 'server') { $serverIdx = $out.Count }
            $out.Add($raw); continue
        }
        if (-not $done -and $section -eq 'server' -and
            $t -match ('^' + [regex]::Escape($Key) + '\s*=')) {
            $out.Add("$Key = $Value"); $done = $true; continue
        }
        $out.Add($raw)
    }
    if (-not $done) {
        if ($serverIdx -ge 0) {
            $out.Insert($serverIdx + 1, "$Key = $Value")
        } else {
            $out.Add(''); $out.Add('[server]'); $out.Add("$Key = $Value")
        }
    }
    return ($out -join "`r`n")
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
    # ROOT_URL/DOMAIN are intentionally NOT seeded here -- the routing step below sets them from the
    # box's tailnet name (or -PublicHostname) once it's known, then restarts the service if needed.
    @"
RUN_USER = $runUser

[server]
; Bind to loopback only -- the box is reached via `tailscale serve` running locally
; (it proxies the tailnet to this port), so Gitea must never be exposed on the LAN/WAN directly.
HTTP_ADDR = 127.0.0.1
HTTP_PORT = 3000

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
# A no-op without R2 creds, when -RestoreSnapshotId is '' (-Restore None), on a box that already has
# data, or when there's no snapshot to restore. (Backups are still set up below regardless of restore.)
if ($R2AccountId -and $RestoreSnapshotId) {
    try {
        & (Join-Path $PSScriptRoot 'Restore-Gitea.ps1') `
            -R2AccountId $R2AccountId -R2Bucket $R2Bucket -R2AccessKeyId $R2AccessKeyId `
            -R2SecretKey $R2SecretKey -ResticPassword $ResticPassword -WorkDir $WorkDir `
            -SnapshotId $RestoreSnapshotId
    } catch {
        Write-Host "[boxstrapper] Auto-restore skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
    } finally {
        # Restore-Gitea.ps1 runs inline (same process) and sets restic/R2 creds in this env; clear them.
        Remove-Item Env:RESTIC_REPOSITORY, Env:RESTIC_PASSWORD, Env:AWS_ACCESS_KEY_ID, `
                    Env:AWS_SECRET_ACCESS_KEY, Env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
    }
}

# --- routing: set ROOT_URL from this box's tailnet name (the authority for its public URL) -------
# Gitea is loopback-only and can't know its own public hostname. Update-Box.ps1 brought Tailscale up
# FIRST, so the box's MagicDNS name is available now; read it (or take an explicit -PublicHostname
# override) and ensure app.ini's [server] ROOT_URL=https://<host><Prefix>/ + DOMAIN=<host> +
# SSH_DOMAIN=<host>, so Gitea emits <Prefix>-prefixed links behind the proxy AND its SSH clone URLs name
# THIS box. SSH_DOMAIN matters after a RESTORE: the restored app.ini carries the SOURCE box's SSH_DOMAIN
# (DOMAIN/ROOT_URL get re-derived but SSH_DOMAIN would otherwise stay stale), so we re-derive all three.
# Track whether the file changed so the start
# step below restarts an already-running service to pick it up. Best-effort: a hiccup just warns.
$tailscale   = Resolve-TailscaleExe
$derivedHost = Get-TailnetHostname -TailscaleExe $tailscale   # $null unless on the tailnet
$tailnetHost = if ($PublicHostname) { $PublicHostname } else { $derivedHost }

$rootUrlChanged = $false
if ($tailnetHost -and (Test-Path -LiteralPath $configPath)) {
    try {
        $rootUrl = "https://$tailnetHost$Prefix/"
        $orig    = Get-Content -LiteralPath $configPath -Raw
        $patched = Set-GiteaServerKey -Text $orig    -Key 'ROOT_URL'   -Value $rootUrl
        $patched = Set-GiteaServerKey -Text $patched -Key 'DOMAIN'     -Value $tailnetHost
        $patched = Set-GiteaServerKey -Text $patched -Key 'SSH_DOMAIN' -Value $tailnetHost
        if ($patched -ne $orig) {
            # ASCII matches the seed app.ini above; no BOM either way.
            [System.IO.File]::WriteAllText($configPath, $patched, [System.Text.Encoding]::ASCII)
            $rootUrlChanged = $true
            $src = if ($PublicHostname) { 'override' } else { 'MagicDNS name' }
            Write-Host "[boxstrapper] Set Gitea ROOT_URL=$rootUrl (from $src)." -ForegroundColor DarkGray
        } else {
            Write-Host "[boxstrapper] Gitea ROOT_URL already $rootUrl; left untouched." -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "Could not set Gitea ROOT_URL: $($_.Exception.Message) (Gitea keeps its current ROOT_URL)."
    }
} else {
    Write-Host "[boxstrapper] Not on the tailnet (no hostname); leaving ROOT_URL to Gitea's default / web installer." -ForegroundColor DarkGray
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
} elseif ($rootUrlChanged) {
    Write-Host "[boxstrapper] Restarting '$ServiceName' to apply the new ROOT_URL..." -ForegroundColor Cyan
    Restart-Service -Name $ServiceName -Force
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

# --- publish Gitea on the tailnet at $Prefix (only when we're actually on the tailnet) -----------
# BARE serve target (no path on the backend URL): `tailscale serve --set-path` STRIPS the mount prefix
# before proxying, and Gitea uses the strip subpath model -- it serves at root and relies on the
# ROOT_URL set above to emit <Prefix>-prefixed links, so the stripped '/' is exactly what the backend
# wants. (Contrast Jenkins-Setup.ps1, which ROUTES its own --prefix and must put the path BACK on its
# serve target.) Tailscale-Setup.ps1 already ran `serve reset`, so we just add our own mount. Non-fatal:
# `tailscale serve` needs HTTPS Certificates + MagicDNS on the tailnet; a failure here just warns.
if ($derivedHost -and $tailscale) {
    if ($Prefix) {
        Write-Host "[boxstrapper] Publishing Gitea on the tailnet at '$Prefix'..." -ForegroundColor Cyan
        & $tailscale serve --bg --set-path=$Prefix 3000
    } else {
        Write-Host "[boxstrapper] Publishing Gitea on the tailnet at the root..." -ForegroundColor Cyan
        & $tailscale serve --bg 3000
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "tailscale serve for Gitea failed (exit $LASTEXITCODE); Gitea isn't published at '$Prefix' yet."
        Write-Host    "  Enable HTTPS Certificates + MagicDNS for the tailnet at https://login.tailscale.com/admin/dns, then re-run."
    } else {
        Write-Host "[boxstrapper] Gitea published on the tailnet at '$Prefix' (run 'tailscale serve status' for the URL)." -ForegroundColor Green
    }
}

# --- register Gitea's own Healthchecks heartbeat (this element owns its monitoring) -------------
# Uses Healthchecks-Setup.ps1's defaults, which ARE the Gitea ones (task 'boxstrapper-heartbeat',
# /api/healthz on :3000, label Gitea, key HC_GITEA_PING_URL); we just hand it the ping URL. Blank URL
# => it skips itself. Best-effort: monitoring setup must never wedge the service, so swallow errors.
try {
    & (Join-Path $PSScriptRoot '..\Healthchecks-Setup.ps1') -PingUrl $HeartbeatPingUrl
} catch {
    Write-Warning "Gitea heartbeat setup failed: $($_.Exception.Message) (monitoring only; the service is unaffected)."
}

# --- register Gitea's own offsite backup (this element owns its backup too) ---------------------
# The shared Register-ResticBackup.ps1 (repo root) registers a daily SYSTEM task running Backup-Gitea.ps1
# (gitea dump -> restic -> R2; see those headers). It's the SAME registrar Jenkins-Setup uses -- the way
# both services call Healthchecks-Setup for their heartbeat. Owned HERE, not as a standalone Update-Box
# section, so commenting out Gitea's single Update-Box call also drops its backup (the self-contained-
# element convention, like the heartbeat above and the restore block). It skips itself when the R2/restic
# creds are blank. Best-effort: a backup-SETUP hiccup (e.g. a bad R2 cred failing `restic init`) must not
# wedge the service or the bootstrap, so swallow errors -- the worker is monitored via HC_GITEA_BACKUP_PING_URL.
try {
    & (Join-Path $PSScriptRoot '..\Register-ResticBackup.ps1') `
        -TaskName       'boxstrapper-gitea-backup' `
        -Worker         (Join-Path $PSScriptRoot 'Backup-Gitea.ps1') `
        -Schedule       'Daily' `
        -RunAt          '03:00' `
        -SecretsFile    $SecretsFile `
        -R2AccountId    $R2AccountId `
        -R2Bucket       $R2Bucket `
        -R2AccessKeyId  $R2AccessKeyId `
        -R2SecretKey    $R2SecretKey `
        -ResticPassword $ResticPassword
} catch {
    Write-Warning "Gitea backup setup failed: $($_.Exception.Message) (backups only; the service is unaffected)."
}
