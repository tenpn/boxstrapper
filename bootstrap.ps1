<#
.SYNOPSIS
    Boxstrapper bootstrap: take a fresh Windows machine to a working dev box.
.DESCRIPTION
    Run in an ELEVATED PowerShell:

        irm https://raw.githubusercontent.com/tenpn/boxstrapper/wildblue/bootstrap.ps1 | iex

    Installs Chocolatey + git (skipping whatever is already present), clones the
    boxstrapper repo, then hands off to Update-Box.ps1 which applies the choco
    manifest and the rest. Safe to re-run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy Bypass -Scope Process -Force

# --- config (intentionally hardcoded; keep it simple) ----------------------
$RepoUrl = 'https://github.com/tenpn/boxstrapper.git'
$Branch  = 'wildblue'
$Dir     = Join-Path $env:USERPROFILE 'boxstrapper'

# --- TLS 1.2 for older Windows ---------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-Path {
    # Pull newly-installed tools onto PATH for the current session.
    if (-not $env:ChocolateyInstall) {
        $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey'
    }
    $profileModule = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    if (Test-Path $profileModule) {
        Import-Module $profileModule -ErrorAction SilentlyContinue
        if (Test-Command 'Update-SessionEnvironment') { Update-SessionEnvironment }
    }
}

if (-not (Test-Admin)) {
    throw 'boxstrapper must run in an elevated PowerShell. Start PowerShell with "Run as administrator", then re-run the one-liner.'
}

# --- Chocolatey ------------------------------------------------------------
if (Test-Command 'choco') {
    Write-Host '[boxstrapper] Chocolatey already installed.' -ForegroundColor Green
} else {
    Write-Host '[boxstrapper] Installing Chocolatey...' -ForegroundColor Cyan
    # Run the official installer in a fresh powershell.exe so it gets a clean
    # session: no inherited StrictMode/ErrorAction, and no nested-pipeline module
    # autoload bug -- 'irm|iex' inside an 'irm|iex' breaks Expand-Archive's
    # auto-loading of Microsoft.PowerShell.Archive.
    $chocoInstaller = Join-Path $env:TEMP 'boxstrapper-choco-install.ps1'
    (New-Object System.Net.WebClient).DownloadFile('https://community.chocolatey.org/install.ps1', $chocoInstaller)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chocoInstaller
    if ($LASTEXITCODE -ne 0) { throw "Chocolatey install failed (exit code $LASTEXITCODE)." }
    Update-Path
}

# --- git -------------------------------------------------------------------
if (Test-Command 'git') {
    Write-Host '[boxstrapper] git already installed.' -ForegroundColor Green
} else {
    Write-Host '[boxstrapper] Installing git...' -ForegroundColor Cyan
    choco install git -y
    Update-Path
}

# --- clone or update the repo at the target branch -------------------------
if (Test-Path (Join-Path $Dir '.git')) {
    Write-Host "[boxstrapper] Updating existing clone at $Dir ($Branch)..." -ForegroundColor Cyan
    git -C $Dir fetch --all
    git -C $Dir checkout $Branch
    git -C $Dir pull --ff-only
} else {
    Write-Host "[boxstrapper] Cloning $RepoUrl ($Branch) -> $Dir ..." -ForegroundColor Cyan
    git clone --branch $Branch $RepoUrl $Dir
}

# --- hand off to the idempotent setup script -------------------------------
$setup = Join-Path $Dir 'Update-Box.ps1'
Write-Host "[boxstrapper] Running $setup ..." -ForegroundColor Cyan
& $setup
