#Requires -Version 5
<#
.SYNOPSIS
    Harden the choco-installed Jenkins Windows service to loopback-only, serve it under /jenkins,
    pre-install a declared set of plugins, and (optionally) seed an admin user so the setup wizard is
    skipped. Idempotent.
.DESCRIPTION
    The 'jenkins' choco package installs Jenkins via its MSI, which ALREADY registers its own
    auto-start Windows service -- a WinSW wrapper (jenkins.exe + jenkins.xml in the install dir). So
    "run on boot" needs no work here, and we deliberately do NOT wrap it in NSSM the way Gitea is:
    this is the one service in the repo that keeps the package's own supervision. This script only
    reconfigures that existing service:

      1. SECURITY -- the package binds Jenkins to 0.0.0.0:8080 and opens an inbound firewall rule,
         i.e. exposed on the LAN/WAN. We rewrite jenkins.xml to bind 127.0.0.1 (the box's
         loopback-only invariant -- remote access is over Tailscale, never the LAN) and disable that
         firewall rule. Jenkins runs arbitrary code by design, so this matters.
      2. PATH ROUTING -- we add --prefix=/jenkins so Jenkins serves correctly under the subpath that
         `tailscale serve --set-path=/jenkins` publishes, alongside Gitea at the root of the same
         tailnet HTTPS endpoint (see Tailscale-Setup.ps1).
      3. PLUGINS -- we pre-install the plugins listed in plugins.txt (next to this script) with
         jenkins-plugin-cli (the official offline installer, downloaded once, pinned). It runs while
         the service is STOPPED (so files aren't locked) and only when the plugin list changed (a hash
         stamp guards re-runs from needlessly bouncing the service). Because the setup wizard is skipped
         when an admin password is supplied, this file is the ONLY source of plugins -- the wizard's
         "suggested plugins" step never runs, so list everything you need.
      4. ADMIN BOOTSTRAP -- when -AdminPassword is supplied (from secrets.ini's JENKINS_ADMIN_PASSWORD)
         we skip the setup wizard (-Djenkins.install.runSetupWizard=false), set JENKINS_ADMIN_USER /
         JENKINS_ADMIN_PASSWORD in jenkins.xml's <env> (the service's OWN environment, so the SYSTEM
         service can read them with no machine-wide env var), and copy the STATIC, secret-free hook
         init.groovy.d\basic-security.groovy into JENKINS_HOME. On each boot that hook reads those env
         vars and ensures the admin account + a logged-in-only authorization strategy. secrets.ini is
         the source of truth (a UI password change reverts on restart; rotate by editing secrets.ini and
         re-running). If -AdminPassword is BLANK we leave the interactive wizard enabled (removing the
         flag, the env vars, and the hook) and print initialAdminPassword as before, so a throwaway box
         still provisions.
      5. OFFSITE BACKUP/RESTORE -- when R2/restic creds are supplied, this script also OWNS Jenkins'
         offsite backup lifecycle (the self-contained-element convention, like the heartbeat below):
         before first start it auto-restores the latest snapshot onto a fresh box (Restore-Jenkins.ps1),
         and it registers the weekly restic->R2 backup task (via the shared Register-ResticBackup.ps1). Both skip when the
         creds are blank. So commenting out Jenkins' one Update-Box.ps1 call drops the service, its
         monitoring, AND its backup together -- they live and die with this script.

      6. DEDICATED SERVICE ACCOUNT -- when -ServiceAccountPassword is supplied (secrets.ini's
         JENKINS_SERVICE_PASSWORD) we stop running Jenkins as LocalSystem. Jenkins runs arbitrary build
         code, so we create/update a NON-admin local '$ServiceAccount' user (default 'jenkins'), grant it
         "Log on as a service" + the file rights it needs (Modify on the install dir for WinSW's logs,
         Full control on JENKINS_HOME), add it to Remote Desktop Users where that group exists (so you can
         RDP in as it over the tailnet), then switch the service's logon identity to it -- reconfiguring an
         EXISTING service in place and restarting only when the identity actually changed. A blank password
         leaves Jenkins as LocalSystem (non-fatal skip), so a throwaway box still provisions.

    JAVA: the jenkins package does NOT bundle a JDK and aborts its install without one, so
    packages.config ships temurin21 and Update-Box.ps1 installs it (and refreshes JAVA_HOME onto the
    session) BEFORE the manifest installs jenkins. We reuse that JAVA_HOME to run jenkins-plugin-cli.

    Assumes the 'jenkins' choco package is already installed (Update-Box.ps1 installs it from
    packages.config before calling this). Safe to re-run: every edit (jenkins.xml, the init.groovy.d
    hook, plugins) is compared before applying, so a clean re-run is a no-op that doesn't bounce the
    service.
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
    [string]$HeartbeatPingUrl = '',
    # Admin account seeded into Jenkins (from secrets.ini's JENKINS_ADMIN_USER/JENKINS_ADMIN_PASSWORD).
    # A non-blank password SKIPS the setup wizard and provisions this user; blank keeps the wizard.
    [string]$AdminUser     = 'admin',
    [string]$AdminPassword = '',
    # Plugin list in jenkins-plugin-cli format (one "id" or "id:version" per line; '#' comments). Blank
    # or missing => no plugin pre-install.
    [string]$PluginsFile = (Join-Path $PSScriptRoot 'plugins.txt'),
    # Pinned plugin-installation-manager-tool release used to fetch/resolve the plugins. Bump as needed;
    # a download failure is non-fatal (it just warns and skips plugin install this run).
    [string]$PluginCliVersion = '2.15.0',
    # Dedicated NON-admin local account the Jenkins service logs on as (created/updated here, then the
    # service is switched off its default LocalSystem to it so Jenkins' arbitrary builds run unprivileged).
    [string]$ServiceAccount = 'jenkins',
    # Password for $ServiceAccount (Update-Box.ps1 passes JENKINS_SERVICE_PASSWORD from secrets.ini). BLANK
    # => the whole dedicated-account step is skipped and Jenkins keeps running as LocalSystem (non-fatal,
    # like every other secret), so a throwaway box still provisions. Non-blank => the account's password is
    # (re)set to this every run (secrets.ini is the source of truth; rotate by editing it and re-running).
    [string]$ServiceAccountPassword = '',
    # Absolute path to secrets.ini, forwarded to the Jenkins backup setup so its weekly SYSTEM task can
    # re-read secrets at run time (a task argument can't carry secrets safely). Blank => the backup setup
    # falls back to the repo-root secrets.ini next to this jenkins\ folder.
    [string]$SecretsFile    = '',
    # R2 + restic credentials. Power TWO self-contained sub-features this script OWNS: auto-RESTORING the
    # latest offsite snapshot onto a FRESH box (the restore block below) and registering the weekly
    # restic->R2 BACKUP task (the Register-ResticBackup call near the end). Update-Box.ps1 passes the same
    # five values to both. Blank => no restore AND no backup (the box provisions / comes up on the wizard).
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
    throw 'Jenkins-Setup.ps1 must run in an elevated PowerShell (reconfiguring a service needs admin).'
}
if (-not $Prefix.StartsWith('/')) { $Prefix = '/' + $Prefix }
if (-not $AdminUser) { $AdminUser = 'admin' }

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

function Resolve-JavaExe {
    # jenkins-plugin-cli needs a JVM. Reuse the JAVA_HOME Update-Box set for the jenkins package.
    if ($env:JAVA_HOME) {
        $j = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path $j) { return $j }
    }
    $machineJh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($machineJh) {
        $j = Join-Path $machineJh 'bin\java.exe'
        if (Test-Path $j) { return $j }
    }
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-FileFromUrl {
    # Robust download: prefer curl.exe (ships with Windows 10/11) -- it follows GitHub's redirect to the
    # release CDN and negotiates TLS reliably, sidestepping Invoke-WebRequest's occasional "The request
    # was aborted: The connection was closed unexpectedly." on that redirect. NOTE: call curl.EXE
    # explicitly -- bare 'curl' is a PowerShell alias for Invoke-WebRequest. -f makes an HTTP error (e.g.
    # a 404 for a wrong asset name) a non-zero exit instead of a saved error page. Falls back to
    # Invoke-WebRequest when curl.exe is absent.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fSL --retry 3 --retry-delay 2 -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "curl.exe exited $LASTEXITCODE downloading $Url" }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
}

function Set-JenkinsArg {
    # Ensure "<Name>=<Value>" is present in the service's <arguments> string (the flags Jenkins'
    # embedded web server parses, which come AFTER `-jar jenkins.war`), replacing any existing
    # "<Name>[=...]" token so re-running is idempotent. Returns the (possibly unchanged) string.
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

function Set-JenkinsJvmArg {
    # Like Set-JenkinsArg but for a JVM system property (e.g. -Djenkins.install.runSetupWizard), which
    # MUST sit BEFORE `-jar` or the JVM hands it to Jenkins as an app arg and ignores it. Replaces an
    # existing token in place, else inserts it just before `-jar`. Idempotent.
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
    $jar = [regex]::Match($Arguments, '(^|\s)-jar(\s|$)')
    if ($jar.Success) {
        $idx = $jar.Index + $jar.Groups[1].Value.Length
        return $Arguments.Substring(0, $idx) + $desired + ' ' + $Arguments.Substring($idx)
    }
    return ($Arguments.TrimEnd() + ' ' + $desired)
}

function Remove-JenkinsArg {
    # Drop a "<Name>[=...]" token (and its leading space) if present. Used to RESTORE the setup wizard
    # when -AdminPassword is later blanked. Idempotent (a no-op when the token isn't there).
    param(
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Name
    )
    $pattern = '\s*' + [regex]::Escape($Name) + '(=\S*)?(?=\s|$)'
    return ([regex]::Replace($Arguments, $pattern, '')).Trim()
}

function Set-JenkinsXmlEnv {
    # Ensure a <env name="Name" value="Value"/> element exists in jenkins.xml, replacing any existing
    # one for Name. WinSW exposes these to the Jenkins PROCESS only -- which is how the SYSTEM service
    # reads JENKINS_ADMIN_* without a machine-wide env var. Value is XML-attribute escaped. Idempotent.
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $enc      = [System.Security.SecurityElement]::Escape($Value)
    $newElem  = '<env name="' + $Name + '" value="' + $enc + '" />'
    $existing = [regex]::Match($Raw, '<env\s+name="' + [regex]::Escape($Name) + '"\s+value="[^"]*"\s*/>')
    if ($existing.Success) {
        return $Raw.Replace($existing.Value, $newElem)
    }
    # Not present: insert as a new element just before <executable>, matching its indentation.
    $exe = [regex]::Match($Raw, '(?m)^([ \t]*)<executable>')
    if ($exe.Success) {
        $indent = $exe.Groups[1].Value
        return $Raw.Substring(0, $exe.Index) + $indent + $newElem + "`r`n" + $Raw.Substring($exe.Index)
    }
    return $Raw
}

function Remove-JenkinsXmlEnv {
    # Drop the <env name="Name" .../> element (and its line) if present. Idempotent.
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Name
    )
    $lineGone = [regex]::Replace($Raw, '(?m)^[ \t]*<env\s+name="' + [regex]::Escape($Name) + '"\s+value="[^"]*"\s*/>[ \t]*\r?\n', '')
    if ($lineGone -ne $Raw) { return $lineGone }
    return [regex]::Replace($Raw, '\s*<env\s+name="' + [regex]::Escape($Name) + '"\s+value="[^"]*"\s*/>', '')
}

function Add-ServiceLogonRight {
    # Ensure $Account holds SeServiceLogonRight ("Log on as a service"). A programmatic service-account
    # change (Win32_Service.Change below) does NOT grant this the way the Services MMC does, and without it
    # the service fails to start with error 1069. secedit is the script-only way to edit a user-rights
    # assignment: we EXPORT the current USER_RIGHTS (so we preserve every existing holder -- a minimal
    # template would REMOVE them), append our SID to the SeServiceLogonRight line, and re-apply. Returns
    # $true if it added the right, $false if it was already present. PS 5.1-safe.
    param([Parameter(Mandatory)][string]$Account)
    $sid  = (New-Object Security.Principal.NTAccount($Account)).Translate(
                [Security.Principal.SecurityIdentifier]).Value
    $base = Join-Path $env:TEMP ('boxstrapper-secpol-' + [guid]::NewGuid().ToString('N'))
    $inf  = "$base.inf"
    $sdb  = "$base.sdb"
    try {
        & secedit /export /cfg $inf /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit /export failed ($LASTEXITCODE)." }
        $lines     = Get-Content -LiteralPath $inf
        $rightLine = $lines | Where-Object { $_ -match '^\s*SeServiceLogonRight\s*=' } | Select-Object -First 1
        if ($rightLine) {
            if ($rightLine -match [regex]::Escape($sid)) { return $false }   # already granted
            $updated = $rightLine.TrimEnd() + ",*$sid"
            $lines   = $lines | ForEach-Object { if ($_ -eq $rightLine) { $updated } else { $_ } }
        } else {
            # No account currently holds the right: add the line right after the [Privilege Rights] header.
            $lines = $lines | ForEach-Object {
                $_
                if ($_ -match '^\s*\[Privilege Rights\]\s*$') { "SeServiceLogonRight = *$sid" }
            }
        }
        Set-Content -LiteralPath $inf -Value $lines -Encoding Unicode
        & secedit /configure /db $sdb /cfg $inf /areas USER_RIGHTS /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit /configure failed ($LASTEXITCODE)." }
        return $true
    } finally {
        Remove-Item -LiteralPath $inf, $sdb -ErrorAction SilentlyContinue
    }
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

# --- resolve JENKINS_HOME (needed for plugins, the admin hook, and the wizard password) ------------
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
Write-Host "[boxstrapper] JENKINS_HOME: $jenkinsHome" -ForegroundColor DarkGray

# --- restore the latest offsite backup onto a FRESH box (before we touch config or start) ----------
# Mirrors how Gitea-Setup runs Restore-Gitea, but with a Jenkins twist: the 'jenkins' choco package
# AUTO-STARTED a default Jenkins before we got here, so we stop it, let the internal Restore-Jenkins.ps1
# worker lay down the last 'jenkins'-tagged snapshot IF this box looks fresh, then leave it stopped --
# the apply block at the bottom starts Jenkins exactly once on the restored data (no start-then-bounce).
# The worker no-ops when there's no snapshot or the box already has jobs / a restore marker, so a
# re-bootstrap never clobbers live data. All best-effort: a restore hiccup just warns and the box comes
# up empty / on the wizard. Guarded by a non-blank R2 account id (blank => backups unconfigured).
if ($R2AccountId) {
    try {
        $jsvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($jsvc -and $jsvc.Status -eq 'Running') {
            Write-Host "[boxstrapper] Stopping '$ServiceName' to check for an offsite backup to restore..." -ForegroundColor Cyan
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 2          # let WinSW release file handles before we overwrite the tree
        }
        & (Join-Path $PSScriptRoot 'Restore-Jenkins.ps1') `
            -R2AccountId $R2AccountId -R2Bucket $R2Bucket -R2AccessKeyId $R2AccessKeyId `
            -R2SecretKey $R2SecretKey -ResticPassword $ResticPassword `
            -ServiceName $ServiceName -JenkinsHome $jenkinsHome
    } catch {
        Write-Host "[boxstrapper] Auto-restore skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
    } finally {
        # Don't leave restic/R2 secrets in this provisioning shell's env (the inline worker set them).
        Remove-Item Env:RESTIC_REPOSITORY, Env:RESTIC_PASSWORD, Env:AWS_ACCESS_KEY_ID, `
                    Env:AWS_SECRET_ACCESS_KEY, Env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
    }
}

# --- rewrite jenkins.xml: <arguments> (bind/port/prefix + wizard skip) and <env> (admin creds) -----
# Edit the raw text rather than reserialising the whole XML, so we touch nothing else WinSW relies on.
# Every edit is idempotent (replace-in-place), so a clean re-run leaves the file byte-for-byte the same.
$orig = Get-Content -LiteralPath $xmlPath -Raw
$raw  = $orig

$m = [regex]::Match($raw, '(?s)<arguments>(.*?)</arguments>')
if (-not $m.Success) {
    throw "jenkins.xml has no <arguments> element to configure; set --httpListenAddress/--httpPort/--prefix manually."
}
$newArgs = $m.Groups[1].Value
$newArgs = Set-JenkinsArg -Arguments $newArgs -Name '--httpListenAddress' -Value '127.0.0.1'
$newArgs = Set-JenkinsArg -Arguments $newArgs -Name '--httpPort'          -Value "$Port"
$newArgs = Set-JenkinsArg -Arguments $newArgs -Name '--prefix'            -Value $Prefix
# Skip the setup wizard ONLY when we have an admin to seed (else we'd boot an UNSECURED Jenkins);
# a blank password restores the wizard by dropping the flag.
if ($AdminPassword) {
    $newArgs = Set-JenkinsJvmArg -Arguments $newArgs -Name '-Djenkins.install.runSetupWizard' -Value 'false'
} else {
    $newArgs = Remove-JenkinsArg -Arguments $newArgs -Name '-Djenkins.install.runSetupWizard'
}
$raw = $raw.Replace($m.Value, '<arguments>' + $newArgs + '</arguments>')

# The admin creds reach the static init.groovy.d hook via the service's OWN environment (<env>), so the
# SYSTEM service reads them without a machine-wide env var and no secret is baked into the hook script.
if ($AdminPassword) {
    $raw = Set-JenkinsXmlEnv -Raw $raw -Name 'JENKINS_ADMIN_USER'     -Value $AdminUser
    $raw = Set-JenkinsXmlEnv -Raw $raw -Name 'JENKINS_ADMIN_PASSWORD' -Value $AdminPassword
} else {
    $raw = Remove-JenkinsXmlEnv -Raw $raw -Name 'JENKINS_ADMIN_USER'
    $raw = Remove-JenkinsXmlEnv -Raw $raw -Name 'JENKINS_ADMIN_PASSWORD'
}

$xmlChanged = $false
if ($raw -ne $orig) {
    # Write UTF-8 WITHOUT a BOM to match the file the MSI shipped.
    [System.IO.File]::WriteAllText($xmlPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
    $xmlChanged = $true
    Write-Host "[boxstrapper] jenkins.xml updated (bind 127.0.0.1:$Port, prefix $Prefix$(if($AdminPassword){', wizard skipped, admin env set'}))." -ForegroundColor DarkGray
} else {
    Write-Host "[boxstrapper] jenkins.xml already correct; left untouched." -ForegroundColor DarkGray
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

# --- install (or remove) the admin-bootstrap init.groovy.d hook ------------------------------------
# Static, secret-free script (init.groovy.d\basic-security.groovy next to THIS script) copied unchanged
# into JENKINS_HOME; it reads JENKINS_ADMIN_USER/PASSWORD from the service env set above and ensures the
# admin account + a logged-in-only authorization strategy on each boot. Blank password => remove the
# hook we previously installed, restoring the vanilla (wizard) state.
$groovySrc     = Join-Path $PSScriptRoot 'init.groovy.d\basic-security.groovy'
$groovyDest    = Join-Path $jenkinsHome 'init.groovy.d\basic-security.groovy'
$groovyChanged = $false
if ($AdminPassword) {
    if (-not (Test-Path -LiteralPath $groovySrc)) {
        Write-Warning "Admin-bootstrap hook missing at $groovySrc; admin user will NOT be seeded."
    } else {
        $want = [System.IO.File]::ReadAllText($groovySrc)
        $have = if (Test-Path -LiteralPath $groovyDest) { [System.IO.File]::ReadAllText($groovyDest) } else { '' }
        if ($want -ne $have) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $groovyDest) | Out-Null
            Copy-Item -LiteralPath $groovySrc -Destination $groovyDest -Force
            $groovyChanged = $true
            Write-Host "[boxstrapper] Installed admin-bootstrap hook -> $groovyDest (admin '$AdminUser', wizard skipped)." -ForegroundColor DarkGray
        } else {
            Write-Host "[boxstrapper] Admin-bootstrap hook already current; left untouched." -ForegroundColor DarkGray
        }
    }
} elseif (Test-Path -LiteralPath $groovyDest) {
    Remove-Item -LiteralPath $groovyDest -Force
    $groovyChanged = $true
    Write-Host "[boxstrapper] Removed admin-bootstrap hook (no JENKINS_ADMIN_PASSWORD; wizard restored)." -ForegroundColor DarkGray
}

# --- pre-install plugins with jenkins-plugin-cli (only when the list changed) ----------------------
# Guarded by a hash stamp so re-runs are no-ops; runs while the service is STOPPED so plugin .jpi files
# aren't locked. Best-effort: a download / install failure warns and leaves the stamp unwritten (so the
# next run retries) -- it never wedges the box, and Jenkins still starts below.
$pluginsInstalled = $false
$pluginLines = @()
if (Test-Path -LiteralPath $PluginsFile) {
    $pluginLines = Get-Content -LiteralPath $PluginsFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}
if ($pluginLines.Count -gt 0) {
    $stampFile = Join-Path $jenkinsHome 'boxstrapper-plugins.hash'
    $wantHash  = (Get-FileHash -LiteralPath $PluginsFile -Algorithm SHA256).Hash
    $haveHash  = if (Test-Path -LiteralPath $stampFile) { (Get-Content -LiteralPath $stampFile -Raw).Trim() } else { '' }
    if ($wantHash -ne $haveHash) {
        try {
            $java = Resolve-JavaExe
            if (-not $java) { throw 'no JVM found (JAVA_HOME unset and java not on PATH).' }
            # The GitHub release asset is named jenkins-plugin-manager-<ver>.jar 
            # Download to a temp then move, so a failed/partial download
            # never leaves a poisoned jar that the Test-Path guard below would later trust.
            $cliJar = Join-Path $installDir "jenkins-plugin-manager-$PluginCliVersion.jar"
            if (-not (Test-Path -LiteralPath $cliJar)) {
                Write-Host "[boxstrapper] Downloading jenkins-plugin-manager $PluginCliVersion..." -ForegroundColor Cyan
                $cliUrl = "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$PluginCliVersion/jenkins-plugin-manager-$PluginCliVersion.jar"
                $cliTmp = "$cliJar.download"
                Get-FileFromUrl -Url $cliUrl -OutFile $cliTmp
                Move-Item -LiteralPath $cliTmp -Destination $cliJar -Force
            }
            # Stop the service so the plugins dir is writable, then install.
            if ((Get-Service -Name $ServiceName).Status -eq 'Running') {
                Write-Host "[boxstrapper] Stopping '$ServiceName' to install plugins..." -ForegroundColor Cyan
                Stop-Service -Name $ServiceName -Force
            }
            $pluginsDir = Join-Path $jenkinsHome 'plugins'
            New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null
            $cliArgs = @('-jar', $cliJar, '--plugin-file', $PluginsFile, '--plugin-download-directory', $pluginsDir)
            $warPath = Join-Path $installDir 'jenkins.war'
            if (Test-Path -LiteralPath $warPath) { $cliArgs += @('--war', $warPath) }
            Write-Host "[boxstrapper] Installing $($pluginLines.Count) plugin(s) from $PluginsFile..." -ForegroundColor Cyan
            & $java @cliArgs
            if ($LASTEXITCODE -ne 0) { throw "jenkins-plugin-cli exited $LASTEXITCODE." }
            New-Item -ItemType Directory -Force -Path $jenkinsHome | Out-Null
            Set-Content -LiteralPath $stampFile -Value $wantHash -NoNewline
            $pluginsInstalled = $true
            Write-Host "[boxstrapper] Plugins installed." -ForegroundColor Green
        } catch {
            Write-Warning "Plugin install failed: $($_.Exception.Message) (Jenkins will still start; re-run to retry)."
        }
    } else {
        Write-Host "[boxstrapper] Plugins already match $PluginsFile; nothing to install." -ForegroundColor DarkGray
    }
}

# --- run Jenkins as a dedicated NON-admin local account (instead of LocalSystem) -------------------
# Jenkins runs arbitrary build code, so we don't want it as LocalSystem. When a service-account password
# is supplied we create/update a local '$ServiceAccount' user (NEVER in Administrators), grant it
# "Log on as a service", give it the file rights it needs (Modify on the install dir for WinSW's logs,
# Full control on JENKINS_HOME), add it to Remote Desktop Users so it can RDP in over the tailnet (where
# that group exists), then switch the service's logon identity to it -- updating an EXISTING service in
# place. Changing identity needs a restart, tracked in $serviceAccountChanged for the apply block. Blank
# password => leave the service as LocalSystem (non-fatal skip, so a sandbox still provisions). All
# best-effort: a failure here just warns and leaves Jenkins running as whatever it was.
$serviceAccountChanged = $false
if ($ServiceAccountPassword) {
    try {
        $securePw = ConvertTo-SecureString $ServiceAccountPassword -AsPlainText -Force

        # 1. Create or update the local account. PasswordNeverExpires keeps an expiring password from
        #    silently breaking the service; we re-assert the password each run (secrets.ini is the source
        #    of truth). Created in Users only -- never Administrators (running unprivileged is the point).
        $existing = Get-LocalUser -Name $ServiceAccount -ErrorAction SilentlyContinue
        if ($existing) {
            Set-LocalUser -Name $ServiceAccount -Password $securePw -PasswordNeverExpires $true
            if (-not $existing.Enabled) { Enable-LocalUser -Name $ServiceAccount }
            Write-Host "[boxstrapper] Updated local service account '$ServiceAccount' (password re-applied)." -ForegroundColor DarkGray
        } else {
            New-LocalUser -Name $ServiceAccount -Password $securePw -FullName 'Jenkins service' `
                -Description 'Non-admin account the Jenkins service runs as (boxstrapper).' `
                -PasswordNeverExpires -AccountNeverExpires | Out-Null
            Write-Host "[boxstrapper] Created non-admin local service account '$ServiceAccount'." -ForegroundColor Cyan
        }

        # 2. Remote Desktop access: add to Remote Desktop Users (well-known SID S-1-5-32-555, resolved by
        #    SID so it works on non-English Windows). Skipped where the group doesn't exist ("if the OS
        #    supports it"). Enabling the RDP LISTENER is a separate box-wide step (RemoteDesktop-Setup.ps1,
        #    its own Update-Box section); once it's on, the tailnet inbound firewall allow already scopes RDP
        #    to the tailnet, so this group membership is all Jenkins' account needs to log in.
        $rdpGroup = Get-LocalGroup -SID 'S-1-5-32-555' -ErrorAction SilentlyContinue
        if ($rdpGroup) {
            try {
                Add-LocalGroupMember -Group $rdpGroup -Member $ServiceAccount -ErrorAction Stop
                Write-Host "[boxstrapper] Added '$ServiceAccount' to '$($rdpGroup.Name)' (RDP over the tailnet)." -ForegroundColor DarkGray
            } catch {
                if ("$($_.FullyQualifiedErrorId)" -notlike '*MemberExists*') { throw }
                Write-Host "[boxstrapper] '$ServiceAccount' already in '$($rdpGroup.Name)'." -ForegroundColor DarkGray
            }
        } else {
            Write-Host "[boxstrapper] No Remote Desktop Users group on this OS; skipping the RDP access grant." -ForegroundColor DarkGray
        }

        # 3. Grant "Log on as a service" (see Add-ServiceLogonRight's header for why this is required).
        if (Add-ServiceLogonRight -Account $ServiceAccount) {
            Write-Host "[boxstrapper] Granted 'Log on as a service' to '$ServiceAccount'." -ForegroundColor DarkGray
        }

        # 4. File rights the non-admin account needs: Modify on the install dir (WinSW writes its logs
        #    beside jenkins.xml, and Program Files is read-only for non-admins) and Full control on
        #    JENKINS_HOME (Jenkins owns everything under it -- jobs, plugins, secrets/ master keys). The
        #    (OI)(CI) inheritable ACEs propagate to existing and future children; re-granting is a no-op.
        & icacls $installDir /grant ("{0}:(OI)(CI)M" -f $ServiceAccount) /C /Q | Out-Null
        if (Test-Path -LiteralPath $jenkinsHome) {
            & icacls $jenkinsHome /grant ("{0}:(OI)(CI)F" -f $ServiceAccount) /C /Q | Out-Null
        }

        # 5. Switch the service's logon identity (also covers an EXISTING service: read its current identity
        #    and only flag a restart when it differs). Done via WMI Change so the password isn't exposed on
        #    a command line. '.\' = this machine's local account. We re-apply the password every run (it may
        #    have rotated) but only restart when the IDENTITY changed -- re-applying the same one needn't
        #    bounce the running process.
        $svcCim       = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
        $currentLogon = $svcCim.StartName
        $desiredLogon = ".\$ServiceAccount"
        $change = Invoke-CimMethod -InputObject $svcCim -MethodName Change `
            -Arguments @{ StartName = $desiredLogon; StartPassword = $ServiceAccountPassword }
        if ($change.ReturnValue -ne 0) {
            throw "Win32_Service.Change returned $($change.ReturnValue) setting the logon account."
        }
        $currentLeaf = if ($currentLogon) { ($currentLogon -split '\\')[-1].ToLowerInvariant() } else { '' }
        if ($currentLeaf -ne $ServiceAccount.ToLowerInvariant()) {
            $serviceAccountChanged = $true
            Write-Host "[boxstrapper] Jenkins service logon set to '$desiredLogon' (was '$currentLogon')." -ForegroundColor Cyan
        } else {
            Write-Host "[boxstrapper] Jenkins service already runs as '$desiredLogon'; password re-applied." -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "Dedicated Jenkins service account setup failed: $($_.Exception.Message) (Jenkins still runs as before)."
    }
}

# --- apply: (re)start so the new config/plugins/admin take effect, else just ensure it's up --------
# A 'Running' service only means WinSW's wrapper is up; we still probe the web port below for real
# health. If we stopped the service to install plugins it's down now, so Start it; if config changed
# in place, Restart; otherwise leave a healthy service alone (keeps re-runs from bouncing it).
$svc = Get-Service -Name $ServiceName
if ($svc.Status -ne 'Running') {
    Write-Host "[boxstrapper] Starting '$ServiceName'..." -ForegroundColor Cyan
    Start-Service -Name $ServiceName
} elseif ($xmlChanged -or $groovyChanged -or $pluginsInstalled -or $serviceAccountChanged) {
    Write-Host "[boxstrapper] Restarting '$ServiceName' to apply changes..." -ForegroundColor Cyan
    Restart-Service -Name $ServiceName -Force
} else {
    Write-Host "[boxstrapper] '$ServiceName' already running with the current config." -ForegroundColor Green
}

# --- readiness probe -------------------------------------------------------
# Jenkins' first start unpacks the war and is slow, so allow ~60s. Any HTTP response (even a 403/401
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
if ($ready) {
    Write-Host "[boxstrapper] Jenkins is responding on $probeUrl" -ForegroundColor Green
} else {
    Write-Warning "Jenkins service is registered but $probeUrl isn't answering yet (first start can be slow; check the service log)."
}

# --- tell the user how to log in -------------------------------------------
# With a seeded admin the wizard is skipped, so point at secrets.ini; otherwise print the one-time
# wizard password exactly as before.
if ($AdminPassword) {
    Write-Host "[boxstrapper] Admin user '$AdminUser' is configured from secrets.ini (setup wizard skipped)." -ForegroundColor Green
} else {
    $pwFile = Join-Path $jenkinsHome 'secrets\initialAdminPassword'
    if (Test-Path -LiteralPath $pwFile) {
        Write-Host "[boxstrapper] First-run admin password (paste it into the setup wizard):" -ForegroundColor Cyan
        Write-Host ("  " + (Get-Content -LiteralPath $pwFile -Raw).Trim()) -ForegroundColor Green
        Write-Host "  (from $pwFile)" -ForegroundColor DarkGray
    } else {
        Write-Host "[boxstrapper] Setup wizard password will be at: $pwFile" -ForegroundColor DarkGray
    }
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
# Generic Healthchecks-Setup.ps1 (shared, at the repo root -- one level up from this jenkins\ folder),
# called with Jenkins' OWN task/label/key and its loopback login probe (/login stays 200 even once
# Jenkins security is on, unlike the root which 403s). Blank URL => it skips itself. Best-effort:
# monitoring setup must never wedge the service, so swallow errors.
try {
    & (Join-Path $PSScriptRoot '..\Healthchecks-Setup.ps1') `
        -TaskName  'boxstrapper-heartbeat-jenkins' `
        -PingUrl   $HeartbeatPingUrl `
        -HealthUrl "http://127.0.0.1:$Port$Prefix/login" `
        -Label     'Jenkins' `
        -SecretKey 'HC_JENKINS_PING_URL'
} catch {
    Write-Warning "Jenkins heartbeat setup failed: $($_.Exception.Message) (monitoring only; the service is unaffected)."
}

# --- register Jenkins' own weekly offsite backup (this element owns its backup too) ----------------
# The shared Register-ResticBackup.ps1 (repo root) registers a weekly SYSTEM task running Backup-Jenkins.ps1
# (restic snapshot of JENKINS_HOME -> R2; see those headers). It's the SAME registrar Gitea-Setup uses --
# the way both services call Healthchecks-Setup for their heartbeat. Owned HERE, not as a standalone
# Update-Box section, so commenting out Jenkins' single Update-Box call also drops its backup (the
# self-contained-element convention, like the heartbeat above and the restore block). It skips itself when
# the R2/restic creds are blank. Best-effort: a backup-SETUP hiccup (e.g. a bad R2 cred failing `restic
# init`) must not wedge the service or the bootstrap, so swallow errors -- the worker is monitored via
# HC_JENKINS_BACKUP_PING_URL.
try {
    & (Join-Path $PSScriptRoot '..\Register-ResticBackup.ps1') `
        -TaskName       'boxstrapper-jenkins-backup' `
        -Worker         (Join-Path $PSScriptRoot 'Backup-Jenkins.ps1') `
        -Schedule       'Weekly' `
        -DayOfWeek      'Sunday' `
        -RunAt          '03:30' `
        -SecretsFile    $SecretsFile `
        -R2AccountId    $R2AccountId `
        -R2Bucket       $R2Bucket `
        -R2AccessKeyId  $R2AccessKeyId `
        -R2SecretKey    $R2SecretKey `
        -ResticPassword $ResticPassword
} catch {
    Write-Warning "Jenkins backup setup failed: $($_.Exception.Message) (backups only; the service is unaffected)."
}

Write-Host "[boxstrapper] Finish setup at the tailnet URL under '$Prefix' (run 'tailscale serve status' for it)." -ForegroundColor DarkGray
