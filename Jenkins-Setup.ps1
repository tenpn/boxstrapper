#Requires -Version 5
<#
.SYNOPSIS
    Harden the choco-installed Jenkins Windows service to loopback-only and serve it under /jenkins,
    then restart it. Idempotent.
.DESCRIPTION
    The 'jenkins' choco package installs Jenkins via its MSI, which ALREADY registers its own
    auto-start Windows service -- a WinSW wrapper (jenkins.exe + jenkins.xml in the install dir). So
    "run on boot" needs no work here, and we deliberately do NOT wrap it in NSSM the way Gitea is:
    this is the one service in the repo that keeps the package's own supervision. This script only
    reconfigures that existing service for two things:

      1. SECURITY -- the package binds Jenkins to 0.0.0.0:8080 and opens an inbound firewall rule,
         i.e. exposed on the LAN/WAN. We rewrite jenkins.xml to bind 127.0.0.1 (the box's
         loopback-only invariant -- remote access is over Tailscale, never the LAN) and disable that
         firewall rule. Jenkins runs arbitrary code by design, so this matters.
      2. PATH ROUTING -- we add --prefix=/jenkins so Jenkins serves correctly under the subpath that
         `tailscale serve --set-path=/jenkins` publishes, alongside Gitea at the root of the same
         tailnet HTTPS endpoint (see Tailscale-Setup.ps1).

    JAVA: the jenkins package does NOT bundle a JDK and aborts its install without one, so
    packages.config ships temurin21 and Update-Box.ps1 installs it (and refreshes JAVA_HOME onto the
    session) BEFORE the manifest installs jenkins.

    ADMIN BOOTSTRAP is Jenkins' own setup wizard, exactly like Gitea's web installer: on first start
    Jenkins writes a one-time password to <JENKINS_HOME>\secrets\initialAdminPassword, which this
    script prints. Open the tailnet URL, paste it, finish setup -- there are NO boxstrapper secrets
    for Jenkins.

    Assumes the 'jenkins' choco package is already installed (Update-Box.ps1 installs it from
    packages.config before calling this). Safe to re-run: the jenkins.xml edit is idempotent (it
    ensures the three flags, replacing any existing value), so a clean re-run is a no-op that doesn't
    bounce the service.
#>

[CmdletBinding()]
param(
    [string]$ServiceName = 'Jenkins',
    [int]   $Port        = 8080,
    # Tailnet path Jenkins is served under. Used TWICE: Jenkins is told it via --prefix so its
    # links/assets resolve behind the subpath reverse proxy, AND it's the `tailscale serve` mount this
    # script publishes Jenkins under at the end.
    [string]$Prefix      = '/jenkins',
    # Healthchecks.io ping URL for THIS service's heartbeat (Update-Box.ps1 passes HC_JENKINS_PING_URL
    # from secrets.ini). Blank => no heartbeat (non-fatal). Owned here so disabling Jenkins -- commenting
    # its one Update-Box call -- also drops its monitoring (the self-contained-element convention).
    [string]$HeartbeatPingUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Jenkins-Setup.ps1 must run in an elevated PowerShell (reconfiguring a service needs admin).'
}
if (-not $Prefix.StartsWith('/')) { $Prefix = '/' + $Prefix }

function Resolve-TailscaleExe {
    # Returns the tailscale.exe path, or $null on a box without Tailscale (e.g. a local sandbox) --
    # the publish step is then skipped, not fatal.
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $known = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $known) { return $known }
    return $null
}

function Test-TailscaleUp {
    # $true only if the Tailscale backend is Running (so `tailscale serve` will work).
    param([string]$TailscaleExe)
    if (-not $TailscaleExe) { return $false }
    try {
        $st = & $TailscaleExe status --json 2>$null | ConvertFrom-Json
        return ($st -and $st.BackendState -eq 'Running')
    } catch { return $false }
}

function Set-JenkinsArg {
    # Ensure "<Name>=<Value>" is present in the service's <arguments> string (the flags Jenkins'
    # embedded web server parses), replacing any existing "<Name>[=...]" token so re-running is
    # idempotent. Returns the (possibly unchanged) string.
    param(
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $desired = "$Name=$Value"
    $pattern = [regex]::Escape($Name) + '(=\S*)?(?=\s|$)'
    if ([regex]::IsMatch($Arguments, $pattern)) {
        return [regex]::Replace($Arguments, $pattern, $desired)
    }
    return ($Arguments.TrimEnd() + ' ' + $desired)
}

# --- locate the service and its WinSW config (jenkins.xml) ------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "The '$ServiceName' service was not found. Is the 'jenkins' choco package installed? (it's in packages.config)."
}

# WinSW's service binary IS jenkins.exe; jenkins.xml sits beside it in the install dir.
$pathName = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).PathName
$installDir = $null
if ($pathName) {
    $exePath = $pathName.Trim().Trim('"')
    if (Test-Path -LiteralPath $exePath) { $installDir = Split-Path -Parent $exePath }
}
if (-not $installDir) { $installDir = Join-Path ${env:ProgramFiles} 'Jenkins' }
$xmlPath = Join-Path $installDir 'jenkins.xml'
if (-not (Test-Path -LiteralPath $xmlPath)) {
    throw "Could not find jenkins.xml at '$xmlPath'. Is Jenkins installed there?"
}
Write-Host "[boxstrapper] Jenkins config: $xmlPath" -ForegroundColor DarkGray

# --- rewrite the service arguments: loopback bind, port, /jenkins prefix ----
# Edit the raw text (one <arguments> element) rather than reserialising the whole XML, so we touch
# nothing else WinSW relies on. Idempotent: Set-JenkinsArg replaces an existing flag in place.
$raw = Get-Content -LiteralPath $xmlPath -Raw
$m   = [regex]::Match($raw, '(?s)<arguments>(.*?)</arguments>')
if (-not $m.Success) {
    throw "jenkins.xml has no <arguments> element to configure; set --httpListenAddress/--httpPort/--prefix manually."
}
$argsText = $m.Groups[1].Value
$newArgs  = $argsText
$newArgs  = Set-JenkinsArg -Arguments $newArgs -Name '--httpListenAddress' -Value '127.0.0.1'
$newArgs  = Set-JenkinsArg -Arguments $newArgs -Name '--httpPort'          -Value "$Port"
$newArgs  = Set-JenkinsArg -Arguments $newArgs -Name '--prefix'            -Value $Prefix

$changed = $false
if ($newArgs -ne $argsText) {
    $raw = $raw.Replace($m.Value, '<arguments>' + $newArgs + '</arguments>')
    # Write UTF-8 WITHOUT a BOM to match the file the MSI shipped.
    [System.IO.File]::WriteAllText($xmlPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
    $changed = $true
    Write-Host "[boxstrapper] jenkins.xml set to bind 127.0.0.1, port $Port, prefix $Prefix." -ForegroundColor DarkGray
} else {
    Write-Host "[boxstrapper] jenkins.xml already bound to 127.0.0.1:$Port under $Prefix; left untouched." -ForegroundColor DarkGray
}

# --- belt-and-suspenders: drop the inbound firewall rule the package opened -
# The loopback bind above is the real protection; this just removes the now-pointless LAN opening.
try {
    $rules = Get-NetFirewallRule -DisplayName 'Jenkins' -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Disable-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Host "[boxstrapper] Disabled the package's inbound 'Jenkins' firewall rule (loopback-only now)." -ForegroundColor DarkGray
    }
} catch {
    Write-Warning "Could not disable the 'Jenkins' firewall rule: $($_.Exception.Message) (Jenkins is still loopback-bound)."
}

# --- apply the config: restart only if we changed it, else just ensure it's up
if ($changed) {
    Write-Host "[boxstrapper] Restarting '$ServiceName' to apply the new config..." -ForegroundColor Cyan
    Restart-Service -Name $ServiceName -Force
} elseif ($svc.Status -ne 'Running') {
    Write-Host "[boxstrapper] Starting '$ServiceName'..." -ForegroundColor Cyan
    Start-Service -Name $ServiceName
} else {
    Write-Host "[boxstrapper] '$ServiceName' already running with the current config." -ForegroundColor Green
}

# --- readiness probe -------------------------------------------------------
# A 'Running' service only means WinSW's wrapper is up; probe the web port for the real signal.
# Jenkins' first start unpacks the war and is slow, so allow ~60s. Any HTTP response (even a 403
# once security is configured) means it's answering.
function Test-HttpAnswered {
    param([string]$Url)
    try {
        Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        # An HTTP error status still means the server responded (it's up); a connection failure
        # leaves no Response. The inner try/catch keeps Set-StrictMode happy if .Response is absent.
        $resp = $null
        try { $resp = $_.Exception.Response } catch { $resp = $null }
        return [bool]$resp
    }
}

$probeUrl = "http://127.0.0.1:$Port$Prefix/"
$ready = $false
foreach ($attempt in 1..30) {
    if (Test-HttpAnswered $probeUrl) { $ready = $true; break }
    Start-Sleep -Seconds 2
}

# --- point the user at the setup-wizard password ---------------------------
# JENKINS_HOME comes from jenkins.xml's <env>; WinSW expands %BASE% to the install dir.
$jenkinsHome = $null
try {
    [xml]$xdoc = Get-Content -LiteralPath $xmlPath -Raw
    foreach ($e in @($xdoc.service.env)) {
        if ($e -and $e.name -eq 'JENKINS_HOME') { $jenkinsHome = $e.value }
    }
} catch { }
if ($jenkinsHome) { $jenkinsHome = $jenkinsHome.Replace('%BASE%', $installDir) }
else              { $jenkinsHome = Join-Path $installDir '.jenkins' }
$pwFile = Join-Path $jenkinsHome 'secrets\initialAdminPassword'

if ($ready) {
    Write-Host "[boxstrapper] Jenkins is responding on $probeUrl" -ForegroundColor Green
} else {
    Write-Warning "Jenkins service is registered but $probeUrl isn't answering yet (first start can be slow; check the service log)."
}
if (Test-Path -LiteralPath $pwFile) {
    Write-Host "[boxstrapper] First-run admin password (paste it into the setup wizard):" -ForegroundColor Cyan
    Write-Host ("  " + (Get-Content -LiteralPath $pwFile -Raw).Trim()) -ForegroundColor Green
    Write-Host "  (from $pwFile)" -ForegroundColor DarkGray
} else {
    Write-Host "[boxstrapper] Setup wizard password will be at: $pwFile" -ForegroundColor DarkGray
}

# --- publish Jenkins on the tailnet at $Prefix (only when we're actually on the tailnet) ---------
# TARGET-PATH serve (the backend URL carries $Prefix), UNLIKE Gitea's bare target: `tailscale serve
# --set-path` STRIPS the mount prefix before proxying, but Jenkins ROUTES its own --prefix (Jetty
# serves under $Prefix and 404s at '/'), so we put the path BACK on the target -- tailscale strips the
# inbound $Prefix then re-joins the target's $Prefix, netting the backend the full '$Prefix/...' Jenkins
# expects. Tailscale-Setup.ps1 already ran `serve reset`, so we just add our own mount. Non-fatal:
# `tailscale serve` needs HTTPS Certificates + MagicDNS on the tailnet; a failure here just warns.
$tailscale = Resolve-TailscaleExe
if (Test-TailscaleUp -TailscaleExe $tailscale) {
    Write-Host "[boxstrapper] Publishing Jenkins on the tailnet at '$Prefix'..." -ForegroundColor Cyan
    & $tailscale serve --bg --set-path=$Prefix "http://127.0.0.1:$Port$Prefix"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "tailscale serve for Jenkins failed (exit $LASTEXITCODE); Jenkins isn't published at '$Prefix' yet."
        Write-Host    "  Enable HTTPS Certificates + MagicDNS for the tailnet at https://login.tailscale.com/admin/dns, then re-run."
    } else {
        Write-Host "[boxstrapper] Jenkins published on the tailnet at '$Prefix'." -ForegroundColor Green
    }
}

# --- register Jenkins' own Healthchecks heartbeat (this element owns its monitoring) ------------
# Generic Healthchecks-Setup.ps1, called with Jenkins' OWN task/label/key and its loopback login probe
# (/login stays 200 even once Jenkins security is on, unlike the root which 403s). Blank URL => it skips
# itself. Best-effort: monitoring setup must never wedge the service, so swallow errors.
try {
    & (Join-Path $PSScriptRoot 'Healthchecks-Setup.ps1') `
        -TaskName  'boxstrapper-heartbeat-jenkins' `
        -PingUrl   $HeartbeatPingUrl `
        -HealthUrl "http://127.0.0.1:$Port$Prefix/login" `
        -Label     'Jenkins' `
        -SecretKey 'HC_JENKINS_PING_URL'
} catch {
    Write-Warning "Jenkins heartbeat setup failed: $($_.Exception.Message) (monitoring only; the service is unaffected)."
}
Write-Host "[boxstrapper] Finish setup at the tailnet URL under '$Prefix' (run 'tailscale serve status' for it)." -ForegroundColor DarkGray
