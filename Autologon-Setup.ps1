#Requires -Version 5
<#
.SYNOPSIS
    Enable Windows autologon for a local account using Sysinternals Autologon. Idempotent.
.DESCRIPTION
    Configures the box to log a user in automatically at boot, so an interactive desktop
    session is up without anyone at the keyboard (RDP convenience, user-session apps, or
    interactive scheduled tasks). Note the Gitea/Tailscale services run under their own
    accounts and do NOT need this -- autologon is only for the desktop session.

    Uses Sysinternals Autologon rather than writing the Winlogon registry values by hand:
    Autologon stores the password as an ENCRYPTED LSA secret (the 'DefaultPassword' secret)
    instead of dropping it in plaintext at HKLM\...\Winlogon\DefaultPassword. It still sets
    the public Winlogon values (AutoAdminLogon=1, DefaultUserName, DefaultDomainName).

    SECURITY CAVEAT: this auto-logs the box straight into the ADMIN desktop session (it
    defaults to the bootstrap account), and that account's password is stored as an LSA secret
    -- "not plaintext in the open", but NOT "safe on a compromised box": anything running as
    SYSTEM/admin (Autologon itself, mimikatz, ...) can recover it, because Winlogon must
    decrypt it at boot. So treat physical/console access to this box as equivalent to admin,
    and don't reuse this account's password anywhere else.

    The password is a SECRET and is never committed. Update-Box.ps1 reads it from secrets.ini
    (key AUTOLOGON_PASSWORD; see secrets.example) and passes it in as -Password. If it's blank
    (e.g. a throwaway sandbox), the script explains how to enable it and skips -- non-fatal, so
    the rest of the box still provisions. The password is consumed once into the LSA secret at
    setup time; nothing reads it at run time, so this script never persists it anywhere.

    Defaults target the local account running the bootstrap ($env:USERNAME on this machine).
    For a different or domain account, pass -Username / -Domain. A password is required (this
    script does not configure passwordless autologon).

    Assumes the 'sysinternals' choco package is installed (Update-Box.ps1 installs it from
    packages.config before calling this). Safe to re-run: re-applies the same values, which
    also lets you rotate the password by re-running with a new secret.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Autologon takes the password as a plaintext CLI argument, so a SecureString buys nothing here.')]
param(
    # Account to auto-login. Defaults to the user running the bootstrap.
    [string]$Username = $env:USERNAME,
    # Domain for the account. For a LOCAL account this is the machine name; pass an AD
    # domain for a domain account.
    [string]$Domain   = $env:COMPUTERNAME,
    [string]$Password = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Autologon-Setup.ps1 must run in an elevated PowerShell (writing the LSA secret + Winlogon keys needs admin).'
}
if (-not $env:ChocolateyInstall) {
    $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey'
}

function Resolve-AutologonExe {
    # Prefer the REAL exe under the sysinternals tools dir over the choco 'bin' shim:
    # the shim spawns the GUI-subsystem tool in a detached child, which defeats the
    # -Wait below (we'd never see its real exit code). Prefer the 64-bit build.
    $toolsDir = Join-Path $env:ChocolateyInstall 'lib\sysinternals\tools'
    foreach ($name in 'Autologon64.exe', 'Autologon.exe') {
        $direct = Join-Path $toolsDir $name
        if (Test-Path $direct) { return (Resolve-Path $direct).Path }
    }
    $libRoot = Join-Path $env:ChocolateyInstall 'lib'
    if (Test-Path $libRoot) {
        $hit = Get-ChildItem $libRoot -Recurse -Filter 'Autologon*.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\bin\\' } |
               Sort-Object Name -Descending | Select-Object -First 1   # *64.exe sorts first
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command Autologon -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Could not locate Autologon.exe. Is the 'sysinternals' choco package installed? (it's in packages.config)"
}

# --- a password must be provided, else there's nothing to configure ---------
if (-not $Password) {
    Write-Warning "No autologon password provided; skipping autologon setup (the box still works)."
    Write-Host    "  To enable: put the password for '$Domain\$Username' in secrets.ini"
    Write-Host    "  (key AUTOLOGON_PASSWORD; see secrets.example), then re-run Update-Box.ps1."
    return
}

$autologonExe = Resolve-AutologonExe
Write-Host "[boxstrapper] Autologon exe: $autologonExe" -ForegroundColor DarkGray
Write-Host "[boxstrapper] Enabling autologon for $Domain\$Username" -ForegroundColor Cyan

# --- pre-accept the EULA so an unattended run can't hang on the dialog -------
# Sysinternals tools pop a first-run EULA GUI unless accepted. Set the per-tool key
# (covers both Autologon.exe and Autologon64.exe) AND pass -accepteula below.
$eulaKey = 'HKCU:\Software\Sysinternals\Autologon'
if (-not (Test-Path $eulaKey)) { New-Item -Path $eulaKey -Force | Out-Null }
Set-ItemProperty -Path $eulaKey -Name 'EulaAccepted' -Value 1 -Type DWord

# --- apply (stores the password as an encrypted LSA secret) -----------------
# Autologon is a GUI-subsystem app, so '& $exe' would return immediately with a
# meaningless exit code; Start-Process -Wait blocks and gives the real one. The
# password is briefly visible on the process command line -- unavoidable, as
# Autologon takes it only as an argument; the window is short and the box trusted.
$proc = Start-Process -FilePath $autologonExe `
    -ArgumentList @('-accepteula', $Username, $Domain, $Password) `
    -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "Autologon exited with code $($proc.ExitCode); autologon was NOT configured (check the account/password)."
}

# --- verify via the public Winlogon values (the password itself isn't readable) ---
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$aal = (Get-ItemProperty -Path $winlogon -Name AutoAdminLogon  -ErrorAction SilentlyContinue).AutoAdminLogon
$dun = (Get-ItemProperty -Path $winlogon -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
if ($aal -ne '1') {
    Write-Warning "Autologon ran but AutoAdminLogon is '$aal' (expected '1'); autologon may not be active. Verify manually."
} else {
    Write-Host "[boxstrapper] Autologon enabled for '$dun' (password stored as an LSA secret)." -ForegroundColor Green
    Write-Host "  The password is now in the LSA secret; you can clear AUTOLOGON_PASSWORD from secrets.ini if you like." -ForegroundColor DarkGray
}
