#Requires -Version 5
<#
.SYNOPSIS
    Collect everything relevant to a transient Gitea outage on a boxstrapper box into one transcript.
.DESCRIPTION
    Run ON THE BOX in an elevated Windows PowerShell after Gitea has come back. Pass -At (local time the
    outage was noticed) and it pulls, for a window around that instant:
      - when gitea.exe last (re)started, service/nssm events, Gitea's own logs, crash reports
      - whether a boxstrapper scheduled task (backup / heartbeat) ran then, and the staging dump stamps
      - sleep / wake / boot / Windows Update events and the active power-plan sleep timeouts
    Read-only. Writes the transcript to C:\gitea\log\outage-<stamp>.txt; paste that back for analysis.
.EXAMPLE
    .\Collect-GiteaOutage.ps1 -At '2026-09-09 11:00'
#>
[CmdletBinding()]
param(
    [datetime]$At          = (Get-Date).Date.AddHours(11),
    [int]     $WindowMin   = 90,
    [string]  $WorkDir     = 'C:\gitea',
    [string]  $ServiceName = 'gitea'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$from   = $At.AddMinutes(-$WindowMin)
$to     = $At.AddMinutes($WindowMin)
$logDir = Join-Path $WorkDir 'log'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$out = Join-Path $logDir ("outage-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $out | Out-Null

function Section([string]$Title) { Write-Host "`n===== $Title =====" -ForegroundColor Cyan }
function Invoke-Section([string]$Title, [scriptblock]$Body) {
    Section $Title
    try { & $Body } catch { Write-Warning "($Title) $($_.Exception.Message)" }
}
function Short([string]$Text, [int]$Max = 200) {
    $t = $Text -replace '\s+', ' '
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) }
    return $t
}

Write-Host "Window: $from -> $to (local). Now: $(Get-Date). TZ: $([TimeZoneInfo]::Local.Id)"

Invoke-Section 'Current state' {
    Get-Service $ServiceName | Format-List Name, Status, StartType
    $p = Get-Process gitea -ErrorAction SilentlyContinue
    if ($p) {
        $p | Format-List Id, StartTime,
            @{n='UptimeMin';    e={ [int]((Get-Date) - $_.StartTime).TotalMinutes }},
            @{n='WorkingSetMB'; e={ [int]($_.WorkingSet64 / 1MB) }},
            @{n='Threads';      e={ $_.Threads.Count }}
        Write-Host 'gitea.exe StartTime is its last (re)start; compare it with the outage time.' -ForegroundColor DarkGray
    } else {
        Write-Warning 'no gitea.exe process'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host ("LastBootUpTime: {0}   free RAM MB: {1} / {2}" -f $os.LastBootUpTime, [int]($os.FreePhysicalMemory / 1KB), [int]($os.TotalVisibleMemorySize / 1KB))
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:3000/api/healthz' -UseBasicParsing -TimeoutSec 5
        Write-Host "healthz: HTTP $($r.StatusCode) $($r.Content)"
    } catch { Write-Warning "healthz probe failed: $($_.Exception.Message)" }
    Get-Volume -DriveLetter C | Format-Table DriveLetter,
        @{n='FreeGB'; e={ [int]($_.SizeRemaining / 1GB) }}, @{n='SizeGB'; e={ [int]($_.Size / 1GB) }}
}

Invoke-Section 'boxstrapper scheduled tasks (LastRunTime vs the outage)' {
    Get-ScheduledTask -TaskName 'boxstrapper-*' | ForEach-Object {
        $i = $_ | Get-ScheduledTaskInfo
        [pscustomobject]@{
            Task       = $_.TaskName
            State      = $_.State
            LastRun    = $i.LastRunTime
            LastResult = ('0x{0:X}' -f $i.LastTaskResult)
            NextRun    = $i.NextRunTime
        }
    } | Format-Table -AutoSize
    Write-Host 'A backup LastRun near the outage (not 03:00) = StartWhenAvailable catch-up after the box was asleep/off at 03:00.' -ForegroundColor DarkGray
}

Invoke-Section 'Backup staging dumps (filename stamp is UTC)' {
    Get-ChildItem (Join-Path $WorkDir 'backup\staging') -Filter 'gitea-dump-*.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
        Format-Table Name, @{n='SizeMB'; e={ [int]($_.Length / 1MB) }}, LastWriteTime -AutoSize
}

Invoke-Section 'Task Scheduler operational log (only if enabled)' {
    Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'; StartTime=$from; EndTime=$to} -ErrorAction Stop |
        Where-Object { $_.Message -match 'boxstrapper' } |
        Format-Table TimeCreated, Id, @{n='Msg'; e={ Short $_.Message }} -AutoSize -Wrap
}

Invoke-Section 'Service Control Manager events for the service' {
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'; StartTime=$from; EndTime=$to} |
        Where-Object { $_.Message -match 'gitea' } |
        Format-Table TimeCreated, Id, @{n='Msg'; e={ Short $_.Message }} -AutoSize -Wrap
    Write-Host '7036 stopped->running pair = a controlled stop (backup task / Update-Box). 7031/7034 = crash + nssm restart.' -ForegroundColor DarkGray
}

Invoke-Section 'nssm + Windows Error Reporting (Application log)' {
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$from; EndTime=$to} |
        Where-Object { $_.ProviderName -eq 'nssm' -or (($_.Id -in 1000, 1001, 1002) -and $_.Message -match 'gitea') } |
        Format-Table TimeCreated, ProviderName, Id, @{n='Msg'; e={ Short $_.Message 300 }} -AutoSize -Wrap
}

Invoke-Section 'Boot / sleep / wake / shutdown events (window start minus 9h)' {
    $ids = 41, 42, 107, 1074, 6005, 6006, 6008, 12, 13, 1
    Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$from.AddHours(-9); EndTime=$to} |
        Where-Object { ($_.Id -in $ids) -and ($_.ProviderName -match 'Kernel-Power|Kernel-General|Power-Troubleshooter|EventLog|User32') } |
        Format-Table TimeCreated, ProviderName, Id, @{n='Msg'; e={ Short $_.Message 160 }} -AutoSize -Wrap
    Write-Host '42 = entering sleep, Power-Troubleshooter 1 = woke from sleep, 12/13 = OS start/stop, 1074 = who requested a restart.' -ForegroundColor DarkGray
    powercfg /lastwake
}

Invoke-Section 'Power plan sleep timeouts (hex seconds; 0 = never)' {
    powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE   | Select-String 'Power Setting Index' | ForEach-Object { "STANDBYIDLE   $($_.Line.Trim())" }
    powercfg /q SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE | Select-String 'Power Setting Index' | ForEach-Object { "HIBERNATEIDLE $($_.Line.Trim())" }
    powercfg /a
}

Invoke-Section 'Windows Update activity (last 48h)' {
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=(Get-Date).AddHours(-48)} -ErrorAction SilentlyContinue |
        Format-Table TimeCreated, Id, @{n='Msg'; e={ Short $_.Message 160 }} -AutoSize -Wrap
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3 | Format-Table HotFixID, InstalledOn -AutoSize
}

Invoke-Section 'Gitea logs around the window' {
    # Gitea (console mode under nssm) writes to service-stdout/stderr.log; file mode writes gitea.log.
    # Lines start "yyyy/MM/dd HH:mm:ss" (local). Print every line inside the window, plus lifecycle /
    # failure lines regardless of time.
    $pat = '^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})'
    Get-ChildItem $logDir -Filter '*.log' | ForEach-Object {
        Write-Host ("--- {0} ({1} KB, modified {2})" -f $_.FullName, [int]($_.Length / 1KB), $_.LastWriteTime) -ForegroundColor Yellow
        $lines = Get-Content -LiteralPath $_.FullName -Tail 4000
        $hits = foreach ($l in $lines) {
            $inWindow = $false
            if ($l -match $pat) {
                try {
                    $t = [datetime]::ParseExact($matches[1], 'yyyy/MM/dd HH:mm:ss', $null)
                    $inWindow = ($t -ge $from -and $t -le $to)
                } catch { }
            }
            if ($inWindow -or $l -match 'Listen|Starting new|Shutting down|shutdown|SIGTERM|panic|fatal|Failed to start|database is locked|out of memory|exited|Restarting') { $l }
        }
        $hits | Select-Object -Last 150
    }
}

Invoke-Section 'tailscale serve' {
    & (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe') serve status
}

Stop-Transcript | Out-Null
Write-Host "`nTranscript: $out" -ForegroundColor Green
