#Requires -Version 5
<#
.SYNOPSIS
    Create a clean Windows 11 Hyper-V VM to test boxstrapper end-to-end. Idempotent.
.DESCRIPTION
    A throwaway VM is our clean-room for running bootstrap.ps1 on a "fresh Windows box".
    We can't use Windows Sandbox for this: clean-install Windows enables Smart App Control
    (SAC), which blocks Git for Windows' unsigned MSYS2 DLLs, and SAC CANNOT be disabled from
    inside the sandbox (the registry flag is ignored, CiTool can't reach the policy store, and
    every launch re-arms it). A real Hyper-V VM has a working management plane, so SAC genuinely
    turns off (Settings > Smart App Control > Off, then reboot) and STAYS off -- after which a
    Hyper-V checkpoint gives one-command revert to pristine Windows (see Reset-TestVM.ps1).

    This script does the scriptable half: it creates a Generation-2 VM that meets Windows 11's
    requirements (Secure Boot + a virtual TPM), attaches the install ISO, wires it to Hyper-V's
    built-in NAT "Default Switch" (so the box has internet for the `irm | iex` one-liner), boots
    it, and opens the console. The interactive half -- installing Windows, turning SAC off, and
    snapshotting the clean baseline -- is printed as a runbook when the VM starts (and repeated
    below). Hyper-V cmdlets require an elevated shell, so run this as administrator.

    Safe to re-run: if the VM already exists it is left untouched (use Reset-TestVM.ps1 to revert
    it, or Remove-VM to start over). If Hyper-V isn't installed yet, it is enabled and you're
    asked to reboot and re-run (a feature enable can't take effect without a reboot).

    The consumer Windows 11 ISO needs no product key -- pick "I don't have a product key" and the
    box runs unactivated (a cosmetic watermark only), which is fine for a disposable test bed.
.PARAMETER IsoPath
    Path to a Windows 11 install ISO. Download the consumer ISO from
    https://www.microsoft.com/software-download/windows11 (no key required).
.PARAMETER VMName
    VM name (default 'boxstrapper-test'). Reset-TestVM.ps1 defaults to the same name.
.PARAMETER SwitchName
    Virtual switch (default 'Default Switch' -- Hyper-V's auto-created NAT switch with internet).
.EXAMPLE
    .\New-TestVM.ps1 -IsoPath C:\ISOs\Win11.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$VMName            = 'boxstrapper-test',
    [int]   $CpuCount          = 4,
    [long]  $StartupMemoryBytes = 8GB,
    [long]  $MinMemoryBytes     = 4GB,
    [long]  $MaxMemoryBytes     = 12GB,
    [long]  $DiskSizeBytes      = 80GB,
    [string]$SwitchName        = 'Default Switch'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'New-TestVM.ps1 must run in an elevated PowerShell (Hyper-V cmdlets require admin).'
}

# --- Hyper-V gate ----------------------------------------------------------
# If Hyper-V isn't installed, enable it and stop -- the feature can't take effect until the
# host reboots. (Mirrors the SAC/secrets gate idiom in bootstrap.ps1: do the one thing, then
# ask the user to reboot and re-run.)
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Host '[boxstrapper] Hyper-V is not installed; enabling it now...' -ForegroundColor Cyan
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
    Write-Warning 'Hyper-V enabled. REBOOT this host, then re-run New-TestVM.ps1.'
    return
}

# --- preconditions ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw ("ISO not found at '$IsoPath'. Download the Windows 11 ISO from " +
        'https://www.microsoft.com/software-download/windows11 and pass its path with -IsoPath.')
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    $have = (Get-VMSwitch -ErrorAction SilentlyContinue).Name -join ', '
    throw ("Virtual switch '$SwitchName' not found ('Default Switch' is created automatically " +
        "with Hyper-V). Pass -SwitchName for a different one. Available: $have")
}
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Warning ("VM '$VMName' already exists; leaving it untouched. Revert it with " +
        'Reset-TestVM.ps1, or remove it with Remove-VM to start over.')
    return
}

# --- create the VM ---------------------------------------------------------
$vhdDir  = Join-Path (Get-VMHost).VirtualHardDiskPath $VMName
$vhdPath = Join-Path $vhdDir "$VMName.vhdx"
if (-not (Test-Path -LiteralPath $vhdDir)) { New-Item -ItemType Directory -Path $vhdDir -Force | Out-Null }

$ramGb  = [math]::Round($StartupMemoryBytes / 1GB)
$diskGb = [math]::Round($DiskSizeBytes / 1GB)
Write-Host "[boxstrapper] Creating Gen-2 VM '$VMName' ($ramGb GB RAM, $CpuCount vCPU, $diskGb GB disk)..." -ForegroundColor Cyan

New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $StartupMemoryBytes `
    -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskSizeBytes -SwitchName $SwitchName | Out-Null

Set-VMProcessor -VMName $VMName -Count $CpuCount
Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $true `
    -MinimumBytes $MinMemoryBytes -StartupBytes $StartupMemoryBytes -MaximumBytes $MaxMemoryBytes
Set-VM          -Name $VMName -AutomaticCheckpointsEnabled $false -CheckpointType Standard

# Install media + boot from it first.
Add-VMDvdDrive -VMName $VMName -Path $IsoPath
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

# Windows 11 requires a TPM; a local key protector + vTPM satisfies it without HGS.
Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
Enable-VMTPM       -VMName $VMName

Write-Host "[boxstrapper] VM '$VMName' created. Starting and opening the console..." -ForegroundColor Green
Start-VM -Name $VMName
Start-Process -FilePath 'vmconnect.exe' -ArgumentList 'localhost', $VMName

# --- runbook for the interactive half --------------------------------------
Write-Host ''
Write-Host '[boxstrapper] Next steps in the VM console window that just opened:' -ForegroundColor Cyan
Write-Host '  1. Press a key at "Press any key to boot from CD or DVD" to start Windows Setup.' -ForegroundColor DarkGray
Write-Host '  2. Install Windows 11: choose "I do not have a product key", pick Pro, install.' -ForegroundColor DarkGray
Write-Host '     The first account you create is an Administrator. For a LOCAL (non-Microsoft)' -ForegroundColor DarkGray
Write-Host '     account, at the network screen press Shift+F10 and run:  start ms-cxh:localonly' -ForegroundColor DarkGray
Write-Host '  3. Turn Smart App Control OFF: Settings > Privacy & security > Windows Security >' -ForegroundColor DarkGray
Write-Host '     App & browser control > Smart App Control > Off, then reboot the VM. Verify with:' -ForegroundColor DarkGray
Write-Host "       (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' ``" -ForegroundColor DarkGray
Write-Host '         -Name VerifiedAndReputablePolicyState).VerifiedAndReputablePolicyState   # expect 0' -ForegroundColor DarkGray
Write-Host '  4. Snapshot the clean baseline (run THIS on the host, not in the VM):' -ForegroundColor DarkGray
Write-Host "       Checkpoint-VM -Name '$VMName' -SnapshotName 'clean-vanilla-sac-off'" -ForegroundColor DarkGray
Write-Host '  5. Then test boxstrapper in the VM (elevated PowerShell):' -ForegroundColor DarkGray
Write-Host '       irm https://raw.githubusercontent.com/tenpn/boxstrapper/wildblue/bootstrap.ps1 | iex' -ForegroundColor DarkGray
Write-Host "     Revert to the clean baseline any time with Reset-TestVM.ps1." -ForegroundColor DarkGray
