#Requires -Version 5
<#
.SYNOPSIS
    Idempotent "update the box": apply the choco manifest and configure tools.
.DESCRIPTION
    Safe to re-run any time. Installs everything in packages.config (skipping
    what is already present), then installs the VS Code extensions listed in
    vs-extensions.txt. Add further idempotent setup steps as a new numbered section below.

    Restore control (Gitea + Jenkins offsite backups):
      -Restore None            Set up restic + the backup task but do NOT restore (the default).
      -Restore Latest          Restore the most recent snapshot if present; else behave like None.
      -Restore Before -BeforeDate 2026-07-15
                               Restore the most recent snapshot strictly before that date (local
                               midnight for a bare yyyy-MM-dd). If a service has snapshots but none
                               before the date, stops with a clear error and the box stays re-runnable.
      -Restore ShowSnapshots   Print the available snapshot dates per service, then stop.
    -BeforeDate is valid only with -Restore Before. bootstrap.ps1 prompts for these interactively.
.EXAMPLE
    .\Update-Box.ps1 -Restore Latest
.EXAMPLE
    .\Update-Box.ps1 -Restore Before -BeforeDate 2026-07-15
#>

[CmdletBinding()]
param(
    # Restore policy for the offsite backups. Resolved to a concrete snapshot id here (once, before the
    # service scripts run) and handed to each as -RestoreSnapshotId. See [[gitea-restore-from-snapshot]].
    [ValidateSet('None','Latest','ShowSnapshots','Before')]
    [string]$Restore = 'None',
    # Only meaningful with -Restore Before: ISO date (yyyy-MM-dd) whose most-recent-prior snapshot to
    # restore. A string (not [datetime]) so bootstrap.ps1 can forward it through an `irm | iex` pipe.
    [string]$BeforeDate = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared restic/secrets helpers (Resolve-RestoreRequest, Get-ResticSnapshots, Set-ResticEnv, ...). Its
# Read-Secrets is identical to the one defined below -- dot-sourcing simply redefines it, harmlessly.
. (Join-Path $PSScriptRoot 'Backup-Common.ps1')

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

function Show-ManifestDrift {
    # Generic version-drift check across the choco manifest: for every pin in packages.config,
    # compare it to what's actually installed and warn (never act) on a mismatch. 
    # This exists because `choco install packages.config` SKIPS an already-installed package 
    # -- so bumping a pin and re-running silently leaves the OLD version in place. We surface
    # that instead of hiding it, and print the exact `choco upgrade` to run. 
    param([Parameter(Mandatory)][string]$Manifest)

    try {
        [xml]$pkgXml = Get-Content -Raw -LiteralPath $Manifest

        # Installed id -> version, queried once. `choco list` is local-only by default on choco 2.x but
        # needs --local-only on 1.x (where a bare `list` searches remote sources); detect and branch.
        # --limit-output gives clean `id|version` lines (no header/footer/progress).
        $listArgs = @('list', '--limit-output')
        try {
            $cv = (& choco --version 2>$null | Select-Object -First 1)
            if ($cv -match '^\s*(\d+)' -and [int]$Matches[1] -lt 2) { $listArgs += '--local-only' }
        } catch { }

        $installed = @{}
        foreach ($line in (& choco @listArgs)) {
            $parts = @($line -split '\|')
            if ($parts.Count -ge 2 -and $parts[0]) { $installed[$parts[0].ToLowerInvariant()] = $parts[1] }
        }

        $drift = @()
        foreach ($pkg in $pkgXml.packages.package) {
            $id  = [string]$pkg.id
            $pin = [string]$pkg.version
            if (-not $id -or -not $pin) { continue }                 # unpinned line: nothing to compare
            $have = $installed[$id.ToLowerInvariant()]
            if (-not $have) { continue }                             # not installed yet: the install step handles it
            if ($have -ne $pin) {                                    # -ne is case-insensitive for strings
                $drift += [pscustomobject]@{ Id = $id; Installed = $have; Pinned = $pin }
            }
        }

        if ($drift.Count -gt 0) {
            Write-Warning "[boxstrapper] Version drift: $($drift.Count) package(s) are pinned in packages.config but a DIFFERENT version is installed."
            Write-Warning "[boxstrapper] Re-running does NOT fix this ('choco install' skips already-installed packages). Upgrade explicitly:"
            foreach ($d in $drift) {
                Write-Host ("    {0}: {1} installed, {2} pinned  ->  choco upgrade {0} --version {2} -y" -f $d.Id, $d.Installed, $d.Pinned) -ForegroundColor Yellow
            }
            Write-Host "    (stop the package's service first if it runs as one -- e.g. Stop-Service gitea -- then re-run Update-Box.ps1 to reconcile.)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "[boxstrapper] Manifest drift check skipped: $($_.Exception.Message)"
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

function Format-SnapDate {
    # Display a Get-ResticSnapshots row's instant as local 'yyyy-MM-dd HH:mm', falling back to the raw
    # RFC3339 string if the time didn't parse. Used only by the restore-resolution block below.
    param($Snap)
    if ($Snap.Time) { return $Snap.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    return $Snap.TimeRaw
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
    Write-Warning "Fill in your secrets (leave a key blank to skip that feature):"
    Write-Host    "[boxstrapper] > edit $secretsFile" -ForegroundColor Cyan
    Write-Warning "Then run Update-Box.ps1:"
    $selfPath = Join-Path $PSScriptRoot 'Update-Box.ps1'
    Write-Host    "[boxstrapper] > $selfPath" -ForegroundColor Cyan
    return
}
$secrets = Read-Secrets -Path $secretsFile

# --- 1. apply the choco manifest -------------------------------------------
$manifest = Join-Path $PSScriptRoot 'packages.config'
# Jenkins' choco package ABORTS unless JAVA_HOME is set, but temurin21's MSI sets the machine PATH
# and NOT JAVA_HOME -- so install the JDK first, then set JAVA_HOME BEFORE the manifest reaches
# the jenkins package. 
Write-Host "[boxstrapper] Ensuring a JDK is present for Jenkins (temurin21)..." -ForegroundColor Cyan
choco install temurin21 --version 21.0.9.10 -y
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
# --ignore-checksums scoped to JUST this package. 
Write-Host "[boxstrapper] Installing sysinternals (skipping its stale upstream checksum)..." -ForegroundColor Cyan
choco install sysinternals --version 2026.6.17 -y --ignore-checksums
Write-Host "[boxstrapper] Applying choco manifest: $manifest" -ForegroundColor Cyan
choco install $manifest -y
Update-Path

Show-ManifestDrift -Manifest $manifest

# --- 1b. resolve the restore policy to a concrete snapshot id per service ---------------------------
# Runs AFTER the manifest (restic is now installed) and BEFORE the services, so each service script is
# handed the exact snapshot to restore via -RestoreSnapshotId: '' = don't restore (still set up backups),
# 'latest' = the most recent, or a full snapshot id (Before). ShowSnapshots prints and stops here; a bad
# -Restore/-BeforeDate or an unsatisfiable Before also stops here -- after the idempotent manifest, so the
# box is cleanly re-runnable with a corrected flag. All of this is a no-op for the default -Restore None.
$req         = Resolve-RestoreRequest -Restore $Restore -BeforeDate $BeforeDate   # throws on a bad request
$restoreMode = $req.Mode
$boundary    = $req.Boundary
$giteaSnapId   = ''
$jenkinsSnapId = ''

if ($restoreMode -eq 'Latest') {
    # The workers already resolve 'latest' (and no-op on an empty repo) -- no interrogation needed here.
    $giteaSnapId   = 'latest'
    $jenkinsSnapId = 'latest'
} elseif ($restoreMode -eq 'ShowSnapshots' -or $restoreMode -eq 'Before') {
    $services    = @([pscustomobject]@{ Name = 'Gitea'; Tag = 'gitea' },
                     [pscustomobject]@{ Name = 'Jenkins'; Tag = 'jenkins' })
    $resolvedIds = @{ gitea = ''; jenkins = '' }
    $haveR2      = -not [string]::IsNullOrEmpty($secrets['R2_ACCOUNT_ID'])
    $resticCmd   = Get-Command restic -ErrorAction SilentlyContinue
    if (-not $haveR2 -or -not $resticCmd) {
        if (-not $haveR2) { $why = 'offsite backup is not configured (no R2_ACCOUNT_ID in secrets.ini)' }
        else              { $why = 'restic is not on PATH' }
        if ($restoreMode -eq 'ShowSnapshots') {
            Write-Host "[boxstrapper] Cannot show snapshots: $why." -ForegroundColor DarkGray
            Write-Host "[boxstrapper] Restore options: -Restore None | Latest | ShowSnapshots | (Before -BeforeDate yyyy-MM-dd)." -ForegroundColor DarkGray
            return
        }
        Write-Warning "Cannot resolve -Restore Before: $why; continuing as -Restore None (nothing restored)."
    } else {
        $restic = $resticCmd.Source
        try {
            Set-ResticEnv -R2AccountId   $secrets['R2_ACCOUNT_ID'] -R2Bucket      $secrets['R2_BUCKET'] `
                          -R2AccessKeyId $secrets['R2_ACCESS_KEY_ID'] -R2SecretKey $secrets['R2_SECRET_ACCESS_KEY'] `
                          -ResticPassword $secrets['RESTIC_PASSWORD']
            if ($restoreMode -eq 'ShowSnapshots') {
                foreach ($svc in $services) {
                    Write-Host ''
                    Write-Host "[boxstrapper] $($svc.Name) snapshots (tag $($svc.Tag)):" -ForegroundColor Cyan
                    $snaps = Get-ResticSnapshots -ResticExe $restic -Tag $svc.Tag
                    if ($null -eq $snaps) {
                        Write-Host '  (restic repo unreachable / not initialised yet)' -ForegroundColor DarkGray
                    } elseif ($snaps.Count -eq 0) {
                        Write-Host '  (no snapshots)' -ForegroundColor DarkGray
                    } else {
                        $sorted = @($snaps | Sort-Object Time)
                        foreach ($s in $sorted) { Write-Host ('  {0}  {1}' -f (Format-SnapDate $s), $s.ShortId) }
                        Write-Host ('  {0} snapshot(s), {1} .. {2}' -f $sorted.Count, (Format-SnapDate $sorted[0]), (Format-SnapDate $sorted[-1])) -ForegroundColor DarkGray
                    }
                }
                Write-Host ''
                Write-Host '[boxstrapper] To continue, re-run Update-Box.ps1 with one of:' -ForegroundColor Cyan
                Write-Host '  -Restore Latest                          (restore the most recent snapshot)' -ForegroundColor DarkGray
                Write-Host '  -Restore Before -BeforeDate yyyy-MM-dd    (restore the most recent snapshot before a date)' -ForegroundColor DarkGray
                Write-Host '  -Restore None                            (set up backups without restoring)' -ForegroundColor DarkGray
                return
            } else {
                # Before: resolve each tag's most-recent snapshot strictly before the boundary, or collect a
                # clear per-service error. A tag with NO snapshots is a clean skip (nothing to restore); a
                # tag WITH snapshots but none before the date is an error (a bad date, not an empty repo).
                $errors = @()
                foreach ($svc in $services) {
                    $snaps = Get-ResticSnapshots -ResticExe $restic -Tag $svc.Tag
                    if ($null -eq $snaps -or $snaps.Count -eq 0) {
                        Write-Host "[boxstrapper] No $($svc.Name) snapshots in the repo; nothing to restore for $($svc.Name)." -ForegroundColor DarkGray
                        continue
                    }
                    $before = @($snaps | Where-Object { $_.Time -and $_.Time -lt $boundary })
                    if ($before.Count -eq 0) {
                        $sorted = @($snaps | Sort-Object Time)
                        $errors += "$($svc.Name): no snapshot before $BeforeDate (has $($sorted.Count): $(Format-SnapDate $sorted[0]) .. $(Format-SnapDate $sorted[-1]))."
                    } else {
                        $pick = @($before | Sort-Object Time)[-1]
                        $resolvedIds[$svc.Tag] = $pick.Id
                        Write-Host "[boxstrapper] $($svc.Name): will restore snapshot $($pick.ShortId) ($(Format-SnapDate $pick))." -ForegroundColor Green
                    }
                }
                if ($errors.Count -gt 0) {
                    Write-Host "[boxstrapper] Cannot honour -Restore Before -BeforeDate $BeforeDate :" -ForegroundColor Red
                    foreach ($e in $errors) { Write-Host "  $e" -ForegroundColor Red }
                    Write-Warning 'Re-run Update-Box.ps1 with a corrected -BeforeDate, or -Restore Latest / -Restore None. Nothing was changed.'
                    return
                }
                $giteaSnapId   = $resolvedIds['gitea']
                $jenkinsSnapId = $resolvedIds['jenkins']
            }
        } finally {
            Clear-ResticEnv
        }
    }
}

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
#        before first start, AND the daily gitea-dump->restic->R2 BACKUP task (it calls the shared
#        Register-ResticBackup.ps1 itself, the way it calls Healthchecks-Setup). We only PARSE the secrets here and hand them in as
#        params (HC_GITEA_PING_URL -> -HeartbeatPingUrl); the R2/restic creds + the secrets.ini PATH feed
#        both the restore and the backup. The script itself never reads secrets.ini. ---
& (Join-Path $PSScriptRoot 'gitea\Gitea-Setup.ps1') `
    -R2AccountId      $secrets['R2_ACCOUNT_ID'] `
    -R2Bucket         $secrets['R2_BUCKET'] `
    -R2AccessKeyId    $secrets['R2_ACCESS_KEY_ID'] `
    -R2SecretKey      $secrets['R2_SECRET_ACCESS_KEY'] `
    -ResticPassword   $secrets['RESTIC_PASSWORD'] `
    -HeartbeatPingUrl $secrets['HC_GITEA_PING_URL'] `
    -SecretsFile      $secretsFile `
    -RestoreSnapshotId $giteaSnapId

# --- 5. Jenkins service (choco installs its OWN auto-start WinSW service; Jenkins-Setup.ps1 rebinds ---
#        it loopback-only at 127.0.0.1:8080, serves it under /jenkins, pre-installs jenkins\plugins.txt,
#        and seeds an admin user (skipping the setup wizard). Jenkins-Setup ALSO owns -- as self-contained
#        sub-features, so this ONE call toggles them all -- its tailnet publish, its Healthchecks heartbeat,
#        an auto-RESTORE of the latest offsite snapshot onto a fresh box before first start, AND the weekly
#        restic->R2 BACKUP task (it calls the shared Register-ResticBackup.ps1 itself, like Healthchecks-Setup).
#        We only PARSE the secrets here and hand them in as params; a blank JENKINS_ADMIN_PASSWORD keeps the
#        interactive wizard. The R2/restic creds + the secrets.ini PATH feed both the restore and backup. ---
& (Join-Path $PSScriptRoot 'jenkins\Jenkins-Setup.ps1') `
    -AdminUser              $secrets['JENKINS_ADMIN_USER'] `
    -AdminPassword          $secrets['JENKINS_ADMIN_PASSWORD'] `
    -ServiceAccountPassword $secrets['JENKINS_SERVICE_PASSWORD'] `
    -HeartbeatPingUrl       $secrets['HC_JENKINS_PING_URL'] `
    -SecretsFile            $secretsFile `
    -R2AccountId            $secrets['R2_ACCOUNT_ID'] `
    -R2Bucket               $secrets['R2_BUCKET'] `
    -R2AccessKeyId          $secrets['R2_ACCESS_KEY_ID'] `
    -R2SecretKey            $secrets['R2_SECRET_ACCESS_KEY'] `
    -ResticPassword         $secrets['RESTIC_PASSWORD'] `
    -RestoreSnapshotId      $jenkinsSnapId

# --- 6. Autologon for the admin desktop session (skips if no password) ------
& (Join-Path $PSScriptRoot 'Autologon-Setup.ps1') -Password $secrets['AUTOLOGON_PASSWORD']

# --- 7. Remote Desktop (enable the RDP listener; tailnet-only -- see RemoteDesktop-Setup.ps1). Its OWN
#        step, not part of Jenkins-Setup: enabling the listener is box-wide, whereas Jenkins-Setup only
#        grants its service account RDP access by adding it to the Remote Desktop Users group. No secret --
#        reachability is gated by Tailscale-Setup's tailnet firewall rule + group membership. ---
& (Join-Path $PSScriptRoot 'RemoteDesktop-Setup.ps1')

# --- 8. other idempotent setup steps go here -------------------------------
# (settings sync, dotfiles, etc.)

Write-Host '[boxstrapper] Done.' -ForegroundColor Green
