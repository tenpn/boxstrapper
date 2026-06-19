#Requires -Version 5
<#
.SYNOPSIS
    Revert the boxstrapper test VM to its clean snapshot, then power it on. Idempotent.
.DESCRIPTION
    The "go back to clean Windows very easily" command for the VM that New-TestVM.ps1 created.
    It restores the named Hyper-V checkpoint (default 'clean-vanilla-sac-off' -- the snapshot you
    take once, after installing Windows and turning Smart App Control off), starts the VM, and
    opens the console. Use it between boxstrapper runs to get a pristine box back in seconds
    instead of reinstalling Windows.

    Standard checkpoints capture live memory, so a revert lands you back on the ready desktop.
    Hyper-V cmdlets require an elevated shell, so run this as administrator. If the VM is running
    it is turned off first (we're discarding its state anyway), then reverted and restarted.

    Safe to re-run. Throws a clear message if the VM or the snapshot doesn't exist yet (create the
    snapshot with:  Checkpoint-VM -Name <VMName> -SnapshotName 'clean-vanilla-sac-off' ).
.PARAMETER VMName
    VM to revert (default 'boxstrapper-test' -- matches New-TestVM.ps1).
.PARAMETER SnapshotName
    Checkpoint to restore (default 'clean-vanilla-sac-off').
.EXAMPLE
    .\Reset-TestVM.ps1
#>
[CmdletBinding()]
param(
    [string]$VMName       = 'boxstrapper-test',
    [string]$SnapshotName = 'clean-vanilla-sac-off'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Reset-TestVM.ps1 must run in an elevated PowerShell (Hyper-V cmdlets require admin).'
}

if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    throw "VM '$VMName' not found. Create it first with New-TestVM.ps1 (or pass -VMName)."
}

$snap = Get-VMSnapshot -VMName $VMName -Name $SnapshotName -ErrorAction SilentlyContinue
if (-not $snap) {
    $have = (Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue).Name -join ', '
    throw ("Snapshot '$SnapshotName' not found on VM '$VMName' (have: $have). After the clean " +
        "SAC-off install, create it with: Checkpoint-VM -Name '$VMName' -SnapshotName '$SnapshotName'")
}

if ((Get-VM -Name $VMName).State -ne 'Off') {
    Write-Host "[boxstrapper] Stopping '$VMName' (discarding its current state)..." -ForegroundColor Cyan
    Stop-VM -Name $VMName -TurnOff -Force
}

Write-Host "[boxstrapper] Reverting '$VMName' to snapshot '$SnapshotName'..." -ForegroundColor Cyan
Restore-VMSnapshot -VMSnapshot $snap -Confirm:$false

Start-VM -Name $VMName
Start-Process -FilePath 'vmconnect.exe' -ArgumentList 'localhost', $VMName
Write-Host "[boxstrapper] '$VMName' reverted to '$SnapshotName' and started." -ForegroundColor Green
