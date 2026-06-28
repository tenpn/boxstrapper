<#
.SYNOPSIS
    Boxstrapper bootstrap: take a fresh Windows machine to a working dev box.
.DESCRIPTION
    Run in an ELEVATED PowerShell:

        irm https://raw.githubusercontent.com/tenpn/boxstrapper/wildblue/bootstrap.ps1 | iex

    Preflights Smart App Control (clean-install Windows 11 enables SAC, which blocks
    Git for Windows -- if SAC is enforced, bootstrap stops with instructions to turn
    it off and reboot), then installs Chocolatey + git (skipping whatever is already
    present), clones the boxstrapper repo, and hands off to Update-Box.ps1 which
    applies the choco manifest and the rest. Safe to re-run.
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

function Get-SmartAppControlState {
    # Smart App Control (SAC) state, read from the Code Integrity policy flag:
    #   0 = Off, 1 = Enforced, 2 = Evaluation; $null when the value is absent
    # (older/upgraded Windows that never had SAC). Enforced SAC blocks Git for
    # Windows' unsigned MSYS2 DLLs, which the preflight gate below stops on.
    $item = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
        -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
    if ($item) { return $item.VerifiedAndReputablePolicyState }
    return $null
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

# --- Smart App Control preflight -------------------------------------------
# SAC (default-on for clean-install Windows 11 22H2+) blocks Git for Windows'
# unsigned MSYS2 DLLs (msys-2.0.dll, libpcre2-8-0.dll, ...) at the Code Integrity
# layer, so git fails to load with a cryptic "bad image 0xc0e90002" and the whole
# bootstrap is doomed. There is no per-app allowlist -- the only fix is to turn SAC
# off and reboot. Catch it here, before we install anything, and stop with guidance
# (like the secrets gate in Update-Box.ps1) instead of failing obscurely mid-clone.
# Evaluation mode (2) still lets git run, so we only HALT on Enforced (1); we warn
# on Evaluation because Windows can promote it to Enforced on its own.
$sac = Get-SmartAppControlState
if ($sac -eq 1) {
    Write-Host    '[boxstrapper] Smart App Control is ENFORCED on this box -- cannot continue.' -ForegroundColor Cyan
    Write-Host    '  SAC blocks the unsigned MSYS2 DLLs in Git for Windows at the Code Integrity' -ForegroundColor DarkGray
    Write-Host    '  layer (you would hit a cryptic "bad image 0xc0e90002" error), so git cannot' -ForegroundColor DarkGray
    Write-Host    '  run and the rest of the bootstrap would fail. SAC has no per-app allowlist;' -ForegroundColor DarkGray
    Write-Host    '  the only fix is to turn it off and reboot:' -ForegroundColor DarkGray
    Write-Host    '    Settings > Privacy & security > Windows Security >' -ForegroundColor DarkGray
    Write-Host    '    App & browser control > Smart App Control > Off' -ForegroundColor DarkGray
    Write-Host    '  Once off, Windows will not let SAC turn back on without resetting Windows.' -ForegroundColor DarkGray
    Write-Warning 'Smart App Control is enforced: disable it (see above), reboot, then re-run this bootstrap.'
    return
}
if ($sac -eq 2) {
    Write-Warning 'Smart App Control is in EVALUATION mode: git works for now, but Windows can promote it to Enforced at any time and break a later run. Consider turning SAC off via Windows Security > App & browser control > Smart App Control.'
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

# Sensible build-server git defaults, machine-wide (--system) so they also apply
# to the SYSTEM account Jenkins builds run under -- not just this bootstrap user.
# Set before the clone so the first checkout honours them. Idempotent; run every time.
git config --system core.autocrlf input        # normalise EOL on commit, leave the working tree alone
git config --system core.longpaths true        # survive Windows' 260-char MAX_PATH on deep checkouts
git config --system core.fscache true           # Windows filesystem cache for faster status/checkout
git config --system fetch.prune true            # drop stale remote-tracking branches on every fetch
git config --system pull.ff only                # never auto-create a merge commit on pull
git config --system advice.detachedHead false   # silence detached-HEAD noise (CI checks out detached constantly)
git config --system init.defaultBranch main     # match this repo's main-branch convention

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
