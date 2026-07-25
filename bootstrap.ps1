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

    Restore control: pass -Restore None|Latest|Before|ShowSnapshots (with -BeforeDate for Before) to
    choose what to do with the Gitea/Jenkins offsite backups. When neither is passed -- the usual
    `irm | iex` case, which can't carry flags -- this prompts for the choice interactively and forwards
    it to Update-Box.ps1. The default is None (set up backups without restoring).
.PARAMETER Restore
    None (default) | Latest | Before | ShowSnapshots. Blank => prompt interactively. Forwarded to
    Update-Box.ps1, which validates it authoritatively.
.PARAMETER BeforeDate
    ISO date (yyyy-MM-dd) for -Restore Before; ignored otherwise.
#>

param(
    # No [ValidateSet] here on purpose: under `irm | iex` the whole script text is Invoke-Expression'd,
    # and a ValidateSet whose default ('' = not passed) isn't a member throws at parse time before the
    # body runs. Update-Box.ps1 (run as a file, not iex'd) keeps the ValidateSet and validates the value
    # we forward. '' = not passed -> prompt.
    [string]$Restore    = '',
    [string]$BeforeDate = ''
)

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

function Read-RestoreChoice {
    # Interactive restore-policy menu for the piped `irm | iex` bootstrap (which can't take a -Restore
    # flag). Returns a splat hashtable for Update-Box.ps1. Enter = None, the safe default. The date is
    # validated the same way Update-Box's Resolve-RestoreRequest does (InvariantCulture, AssumeLocal).
    Write-Host ''
    Write-Host '[boxstrapper] Restore from an offsite backup? (Gitea + Jenkins)' -ForegroundColor Cyan
    Write-Host '  1) None            - set up backups but do NOT restore  [default]' -ForegroundColor DarkGray
    Write-Host '  2) Latest          - restore the most recent snapshot' -ForegroundColor DarkGray
    Write-Host '  3) Before a date   - restore the most recent snapshot before a date' -ForegroundColor DarkGray
    Write-Host '  4) Show snapshots  - list available snapshots, then stop' -ForegroundColor DarkGray
    while ($true) {
        $sel = (Read-Host 'Choice [1-4, Enter=1]').Trim()
        if (-not $sel -or $sel -eq '1') { return @{ Restore = 'None' } }
        if ($sel -eq '2') { return @{ Restore = 'Latest' } }
        if ($sel -eq '4') { return @{ Restore = 'ShowSnapshots' } }
        if ($sel -eq '3') {
            while ($true) {
                $d = (Read-Host 'Restore the most recent snapshot before which date? (yyyy-MM-dd)').Trim()
                $dt = [datetime]::MinValue
                if ([datetime]::TryParse($d, [cultureinfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dt)) {
                    return @{ Restore = 'Before'; BeforeDate = $d }
                }
                Write-Warning "Could not parse '$d'. Use an ISO date like 2026-07-15."
            }
        }
        Write-Warning 'Enter 1, 2, 3, or 4.'
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

# --- restore policy --------------------------------------------------------
# Decide it up front (before the long installs) so the user can answer and walk away. An explicit
# -Restore skips the prompt; otherwise prompt (this is the piped `irm | iex` path, which can't pass
# flags). $restoreChoice is a splat hashtable forwarded to Update-Box.ps1, which validates it.
if ($Restore) {
    $restoreChoice = @{ Restore = $Restore }
    if ($BeforeDate) { $restoreChoice.BeforeDate = $BeforeDate }
} else {
    $restoreChoice = Read-RestoreChoice
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
    # git lives here (not packages.config): bootstrap needs it to clone the repo before
    # Update-Box/the manifest even exist locally. Pinned for reproducible boxes.
    choco install git --version 2.55.0 -y
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
Write-Host "[boxstrapper] Running $setup (-Restore $($restoreChoice.Restore)) ..." -ForegroundColor Cyan
& $setup @restoreChoice
