#Requires -Version 5
<#
.SYNOPSIS
    Enable Windows Remote Desktop (RDP) on this box -- tailnet-only by design. Idempotent.
.DESCRIPTION
    Flips the RDP listener on so you can remote-desktop into this headless box. Two registry toggles:
      * HKLM\...\Terminal Server\fDenyTSConnections = 0  -- allow incoming RDP sessions.
      * HKLM\...\Terminal Server\WinStations\RDP-Tcp\UserAuthentication = 1 -- require NLA (Network Level
        Authentication), the secure default: the client authenticates BEFORE a session is created.

    TAILNET-ONLY BY DESIGN. We deliberately do NOT enable the built-in "Remote Desktop" firewall group,
    which would open :3389 on the LAN. The only inbound allow on this box is Tailscale-Setup.ps1's
    `boxstrapper-tailnet-inbound` rule -- a SOURCE-scoped (Profile Any, port-agnostic) allow for the
    tailnet ranges -- so RDP is reachable from tailnet peers and stays blocked on the LAN/WAN, matching
    the loopback/tailnet-only invariant the services follow. Off the tailnet (no auth key) RDP is simply
    unreachable, which is the safe default. Allowing LAN RDP would mean adding a firewall rule by hand;
    that's intentionally not automated here.

    WHO MAY LOG IN is governed by the Remote Desktop Users group, NOT this script: Jenkins-Setup.ps1 adds
    its non-admin service account to that group, and Administrators can always RDP. This script only turns
    the listener on -- it is its own box-wide step precisely because enabling RDP isn't Jenkins-specific.

    No secret and nothing to skip: RDP is always enabled (access is still gated by the tailnet firewall
    rule + group membership). TermService is trigger-started by an incoming connection, so no service
    change is needed. Safe to re-run: it just re-asserts the two registry values.
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

if (-not (Test-Admin)) {
    throw 'RemoteDesktop-Setup.ps1 must run in an elevated PowerShell (writing the Terminal Server policy needs admin).'
}

# --- enable incoming RDP sessions ------------------------------------------
$tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -Value 0 -Type DWord
Write-Host "[boxstrapper] Remote Desktop enabled (fDenyTSConnections=0)." -ForegroundColor Cyan

# --- require Network Level Authentication (secure default) ------------------
# RDP-Tcp lives one level down; it's present on any box that has the RDP listener.
$rdpTcpKey = Join-Path $tsKey 'WinStations\RDP-Tcp'
if (Test-Path $rdpTcpKey) {
    Set-ItemProperty -Path $rdpTcpKey -Name 'UserAuthentication' -Value 1 -Type DWord
    Write-Host "[boxstrapper] Required Network Level Authentication for RDP (UserAuthentication=1)." -ForegroundColor DarkGray
} else {
    Write-Warning "RDP-Tcp registry key not found; left NLA unchanged (is the Remote Desktop feature present?)."
}

Write-Host "[boxstrapper] RDP is on -- reachable from tailnet peers via 'boxstrapper-tailnet-inbound'; LAN stays blocked." -ForegroundColor Green
Write-Host "  Add users to 'Remote Desktop Users' to let them in (Jenkins-Setup adds its service account)." -ForegroundColor DarkGray
