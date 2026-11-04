#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps Apple Music for Windows playing when it silently stops producing sound.

.DESCRIPTION
    On a shaky internet connection, Apple Music can keep showing a song as
    "Playing" while no audio comes out, until you pause and play again. This
    script checks once a second. When Apple Music says it is playing but its
    audio level stays at zero for SilentSeconds in a row, it pauses and resumes
    playback for you.

    Must run under Windows PowerShell 5.1 (powershell.exe). PowerShell 7 cannot
    load the Windows media-control APIs this uses.

.PARAMETER SilentSeconds
    How long Apple Music must be "Playing" but silent before the watchdog steps
    in. Keep this above the gap between songs and the length of quiet intros.

.PARAMETER CooldownSeconds
    Minimum wait after a fix before trying again, so a long outage doesn't
    cause constant pausing.

.PARAMETER Threshold
    Audio level (0 to 1) below which output counts as silent.

.PARAMETER LogPath
    Where to write the log.

.PARAMETER AllowSleep
    Let the PC go to sleep as usual. By default the watchdog keeps it awake
    while Apple Music is playing.

.PARAMETER Check
    Print Apple Music's status and audio level for a few seconds, then exit.
    Use this to confirm detection works on your machine.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\AppleMusicWatchdog.ps1 -Check
#>
# LogPath is read inside Add-LogLine, which the analyzer does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'LogPath')]
[CmdletBinding()]
param(
    [ValidateRange(3, 600)]
    [int]$SilentSeconds = 12,

    [ValidateRange(0, 3600)]
    [int]$CooldownSeconds = 20,

    [ValidateRange(0.0, 1.0)]
    [double]$Threshold = 0.0005,

    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'AppleMusicWatchdog\watchdog.log'),

    [switch]$AllowSleep,

    [switch]$Check
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this with Windows PowerShell 5.1 (powershell.exe), not PowerShell 7. Or use watchdog.cmd.'
}

# Apple Music renders its audio through AMPLibraryAgent.exe, not AppleMusic.exe.
$AudioProcesses = [string[]]@('AMPLibraryAgent', 'AppleMusic')
$MaxLogBytes = 1MB

Add-Type -Path (Join-Path $PSScriptRoot 'AppAudio.cs')
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-AsyncOperation($Operation, [Type]$ResultType) {
    $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait(-1) | Out-Null
    $task.Result
}

[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$propertiesType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]

function Get-MediaManager {
    Wait-AsyncOperation ($managerType::RequestAsync()) $managerType
}

function Get-AppleMusicSession($Manager) {
    $Manager.GetSessions() | Where-Object { $_.SourceAppUserModelId -like '*AppleMusic*' } | Select-Object -First 1
}

function Add-LogLine([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $dir = Split-Path $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) {
        Move-Item $LogPath "$LogPath.old" -Force
    }
    Add-Content -Path $LogPath -Value $line
    Write-Verbose $line
}

$mediaManager = Get-MediaManager

if ($Check) {
    foreach ($i in 1..5) {
        $session = Get-AppleMusicSession $mediaManager
        $status = if ($session) { $session.GetPlaybackInfo().PlaybackStatus } else { 'Apple Music not found' }
        $peak = [AppAudio]::GetPeak($AudioProcesses)
        $level = if ($peak -lt 0) { 'no audio stream' } else { '{0:N4}' -f $peak }
        Write-Output ('{0}  status={1}  level={2}' -f (Get-Date -Format 'HH:mm:ss'), $status, $level)
        Start-Sleep -Seconds 1
    }
    Write-Output 'While music is audible, "level" should be above zero. If it stays at zero, please open an issue.'
    return
}

# Only one watchdog per user session.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\AppleMusicWatchdog', [ref]$createdNew)
if (-not $createdNew) {
    Write-Warning 'The watchdog is already running.'
    return
}

# 'watchdog stop' sets this event so the loop can exit cleanly and log that it stopped.
$stopEvent = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\AppleMusicWatchdogStop')
[void]$stopEvent.Reset()

Add-LogLine "Watchdog started (silence ${SilentSeconds}s, cooldown ${CooldownSeconds}s, threshold $Threshold)"
$silentFor = 0
$cooldownUntil = Get-Date
$fixCount = 0

try {
    while ($true) {
        try {
            $session = Get-AppleMusicSession $mediaManager
            $playing = $session -and $session.GetPlaybackInfo().PlaybackStatus -eq 'Playing'
            if (-not $AllowSleep) { [AppAudio]::SetKeepAwake([bool]$playing) }

            $peak = [AppAudio]::GetPeak($AudioProcesses)
            if ($playing -and $peak -lt $Threshold) { $silentFor++ } else { $silentFor = 0 }

            if ($silentFor -ge $SilentSeconds -and (Get-Date) -ge $cooldownUntil) {
                $title = try { (Wait-AsyncOperation ($session.TryGetMediaPropertiesAsync()) $propertiesType).Title } catch { '?' }
                $fixCount++
                Add-LogLine "Silent for ${silentFor}s while 'Playing' ('$title'). Pausing and resuming (fix #$fixCount)."
                [void](Wait-AsyncOperation ($session.TryPauseAsync()) ([bool]))
                Start-Sleep -Milliseconds 1500
                [void](Wait-AsyncOperation ($session.TryPlayAsync()) ([bool]))
                Start-Sleep -Seconds 3
                Add-LogLine ('After resume: level={0:N4}' -f [AppAudio]::GetPeak($AudioProcesses))
                $silentFor = 0
                $cooldownUntil = (Get-Date).AddSeconds($CooldownSeconds)
            }
        }
        catch {
            Add-LogLine "Error: $($_.Exception.Message)"
            # The media manager can go stale if Apple Music restarts; get a fresh one.
            try { $mediaManager = Get-MediaManager } catch { Write-Verbose 'Could not refresh media manager.' }
            $silentFor = 0
        }
        if ($stopEvent.WaitOne(1000)) { break }
    }
}
finally {
    [AppAudio]::SetKeepAwake($false)
    $stopEvent.Dispose()
    $mutex.ReleaseMutex()
    Add-LogLine 'Watchdog stopped'
}
