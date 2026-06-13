#Requires -Version 5
<#
.SYNOPSIS
    Idempotent "update the box": apply the choco manifest and configure tools.
.DESCRIPTION
    Safe to re-run any time. Installs everything in packages.config (skipping
    what is already present), then installs the VS Code extensions listed in
    vs-extensions.txt. Add further idempotent setup steps in section 3.
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

if (-not (Test-Admin)) {
    throw 'Update-Box.ps1 must run in an elevated PowerShell (Chocolatey needs admin).'
}

# --- 1. apply the choco manifest -------------------------------------------
$manifest = Join-Path $PSScriptRoot 'packages.config'
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

# --- 3. Gitea service (registered + supervised by nssm) --------------------
& (Join-Path $PSScriptRoot 'Gitea-Setup.ps1')

# --- 4. other idempotent setup steps go here -------------------------------
# (settings sync, dotfiles, etc.)

Write-Host '[boxstrapper] Done.' -ForegroundColor Green
