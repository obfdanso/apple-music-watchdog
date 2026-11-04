#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps Apple Music for Windows playing when it silently stops producing sound.

.DESCRIPTION
    On a shaky internet connection, Apple Music can keep showing a song as
    "Playing" while no audio comes out, until you pause and play again. This
    script keeps checking. When Apple Music says it is playing but its audio
    level stays at zero for SilentSeconds in a row, it pauses and resumes
    playback for you.

    It runs under Windows PowerShell 5.1 (powershell.exe), which comes with
    Windows. Started from PowerShell 7, it hands itself over to 5.1, because
    PowerShell 7 cannot load the Windows media-control APIs this uses.

    Settings changed in the window are saved and also used when the watchdog
    runs in the background. Values given on the command line win over them.

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

.PARAMETER Window
    Open a window that shows what the watchdog is doing and lets you change its
    settings and set a time limit. Closing the window stops the watchdog.

.PARAMETER Check
    Print Apple Music's status and audio level for a few seconds, then exit.
    Use this to confirm detection works on your machine.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\AppleMusicWatchdog.ps1 -Window
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

    [switch]$Window,

    [switch]$Check
)

$ErrorActionPreference = 'Stop'

# PowerShell 7 can't load the Windows media-control APIs, so hand over to
# Windows PowerShell 5.1, which every copy of Windows 10 and 11 has.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Value -is [switch]) {
            if ($param.Value) { $argList += "-$($param.Key)" }
        }
        else {
            $argList += "-$($param.Key)", [string]$param.Value
        }
    }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @argList
    exit $LASTEXITCODE
}

# Apple Music renders its audio through AMPLibraryAgent.exe, not AppleMusic.exe.
$AudioProcesses = [string[]]@('AMPLibraryAgent', 'AppleMusic')
$MaxLogBytes = 1MB
$SettingsPath = Join-Path $env:LOCALAPPDATA 'AppleMusicWatchdog\settings.json'

# Settings the window can change while the watchdog runs.
$Settings = @{
    SilentSeconds    = $SilentSeconds
    CooldownSeconds  = $CooldownSeconds
    KeepAwake        = -not $AllowSleep
    StopAfterEnabled = $false
    StopAfterHours   = 1
    StopAfterMinutes = 0
    PauseWhenDone    = $true
    CloseToTray      = $false
    Font             = 'Default'           # 'Default', 'System' (SystemFont below) or 'Anthropic'
    SystemFont       = ''
}

if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        foreach ($name in @($Settings.Keys)) {
            if ($null -ne $saved.$name) { $Settings[$name] = $saved.$name }
        }
    }
    catch {
        Write-Warning "Ignoring the settings file, which couldn't be read: $SettingsPath"
    }
}

# Values given on the command line win over saved ones.
if ($PSBoundParameters.ContainsKey('SilentSeconds')) { $Settings.SilentSeconds = $SilentSeconds }
if ($PSBoundParameters.ContainsKey('CooldownSeconds')) { $Settings.CooldownSeconds = $CooldownSeconds }
if ($PSBoundParameters.ContainsKey('AllowSleep')) { $Settings.KeepAwake = -not $AllowSleep }

# Keep hand-edited values in range.
$Settings.SilentSeconds = [Math]::Min(600, [Math]::Max(3, [int]$Settings.SilentSeconds))
$Settings.CooldownSeconds = [Math]::Min(3600, [Math]::Max(0, [int]$Settings.CooldownSeconds))
$Settings.StopAfterHours = [Math]::Min(23, [Math]::Max(0, [int]$Settings.StopAfterHours))
$Settings.StopAfterMinutes = [Math]::Min(59, [Math]::Max(0, [int]$Settings.StopAfterMinutes))
foreach ($name in 'KeepAwake', 'StopAfterEnabled', 'PauseWhenDone', 'CloseToTray') { $Settings[$name] = [bool]$Settings[$name] }
if ($Settings.Font -notin 'Default', 'System', 'Anthropic') { $Settings.Font = 'Default' }
$Settings.SystemFont = [string]$Settings.SystemFont

function Save-WatchdogSetting {
    $dir = Split-Path $SettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Settings | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
}

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

# What the watchdog currently sees and is doing. The window reads this to show it.
$State = @{
    Manager       = $null
    Active        = -not $Window           # the window waits for you to press Start Watching
    Phase         = 'Watching'             # 'Paused' and 'Resumed' while a fix is under way
    PhaseAt       = [datetime]::MinValue   # when the current fix moves to its next step
    FixSession    = $null
    SilentSince   = $null
    CooldownUntil = [datetime]::MinValue
    Fixes         = 0
    Status        = ''
    Level         = -1.0
    Title         = ''
    Artist        = ''                     # Apple Music sends "Artist - Album" here
    Artwork       = $null                  # the song's album art, for the window
    Position      = 0.0                    # seconds into the song when Apple Music last said
    PositionAt    = [datetime]::MinValue   # when it said so
    Duration      = 0.0                    # the song's length in seconds (0 if unknown)
    TitleAt       = [datetime]::MinValue
    LastError     = ''
    LastFixAt     = $null
    LastFixWorked = $false                 # whether sound came back after the last fix
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

# One check of Apple Music. Called a few times a second; a fix is spread over
# several calls (pause, then play 1.5s later, then check the level 3s after
# that) so the window stays responsive while it happens.
function Invoke-WatchdogStep {
    $now = Get-Date
    try {
        $session = Get-AppleMusicSession $State.Manager
        $State.Status = if ($session) { [string]$session.GetPlaybackInfo().PlaybackStatus } else { 'Not running' }
        $playing = $State.Status -eq 'Playing'
        $State.Level = [AppAudio]::GetPeak($AudioProcesses)
        [AppAudio]::SetKeepAwake($State.Active -and $playing -and $Settings.KeepAwake)

        if (-not $session) {
            $State.Title = ''
            $State.Artist = ''
            $State.Artwork = $null
        }
        elseif ($now -ge $State.TitleAt) {
            try {
                $properties = Wait-AsyncOperation ($session.TryGetMediaPropertiesAsync()) $propertiesType
                $State.Title = [string]$properties.Title
                $State.Artist = [string]$properties.Artist
                $State.Artwork = $properties.Thumbnail
            }
            catch {
                $State.Title = ''
                $State.Artist = ''
                $State.Artwork = $null
            }
            $State.TitleAt = $now.AddSeconds(3)
        }

        # Where we are in the song. Apple Music reports this every couple of seconds,
        # with the time it did, so the window can move the progress bar smoothly in between.
        if ($session) {
            try {
                $timeline = $session.GetTimelineProperties()
                $State.Position = $timeline.Position.TotalSeconds
                $State.Duration = ($timeline.EndTime - $timeline.StartTime).TotalSeconds
                $State.PositionAt = $timeline.LastUpdatedTime.LocalDateTime
            }
            catch {
                $State.Duration = 0
            }
        }
        else {
            $State.Duration = 0
        }

        switch ($State.Phase) {
            'Paused' {
                if ($now -ge $State.PhaseAt) {
                    [void](Wait-AsyncOperation ($State.FixSession.TryPlayAsync()) ([bool]))
                    $State.Phase = 'Resumed'
                    $State.PhaseAt = $now.AddSeconds(3)
                }
            }
            'Resumed' {
                if ($now -ge $State.PhaseAt) {
                    Add-LogLine ('After resume: level={0:N4}' -f $State.Level)
                    $State.LastFixAt = $now
                    $State.LastFixWorked = $State.Level -ge $Threshold
                    $State.Phase = 'Watching'
                    $State.FixSession = $null
                    $State.CooldownUntil = $now.AddSeconds($Settings.CooldownSeconds)
                }
            }
            default {
                if ($State.Active -and $playing -and $State.Level -lt $Threshold) {
                    if (-not $State.SilentSince) { $State.SilentSince = $now }
                }
                else {
                    $State.SilentSince = $null
                }
                $silentFor = if ($State.SilentSince) { ($now - $State.SilentSince).TotalSeconds } else { 0 }

                if ($silentFor -ge $Settings.SilentSeconds -and $now -ge $State.CooldownUntil) {
                    $State.Fixes++
                    $title = if ($State.Title) { $State.Title } else { '?' }
                    Add-LogLine ("Silent for {0:N0}s while 'Playing' ('{1}'). Pausing and resuming (fix #{2})." -f $silentFor, $title, $State.Fixes)
                    [void](Wait-AsyncOperation ($session.TryPauseAsync()) ([bool]))
                    $State.FixSession = $session
                    $State.Phase = 'Paused'
                    $State.PhaseAt = $now.AddSeconds(1.5)
                    $State.SilentSince = $null
                }
            }
        }
        $State.LastError = ''
    }
    catch {
        # Log each new error once rather than several times a second.
        $message = $_.Exception.Message
        if ($message -ne $State.LastError) { Add-LogLine "Error: $message" }
        $State.LastError = $message
        # The media manager can go stale if Apple Music restarts; get a fresh one.
        try { $State.Manager = Get-MediaManager } catch { Write-Verbose 'Could not refresh media manager.' }
        $State.SilentSince = $null
        $State.Phase = 'Watching'
        $State.FixSession = $null
    }
}

$State.Manager = Get-MediaManager

if ($Check) {
    foreach ($i in 1..5) {
        $session = Get-AppleMusicSession $State.Manager
        $status = if ($session) { $session.GetPlaybackInfo().PlaybackStatus } else { 'Apple Music not found' }
        $peak = [AppAudio]::GetPeak($AudioProcesses)
        $level = if ($peak -lt 0) { 'no audio stream' } else { '{0:N4}' -f $peak }
        Write-Output ('{0}  status={1}  level={2}' -f (Get-Date -Format 'HH:mm:ss'), $status, $level)
        Start-Sleep -Seconds 1
    }
    Write-Output 'While music is audible, "level" should be above zero. If it stays at zero, please open an issue.'
    return
}

if ($Window) {
    . (Join-Path $PSScriptRoot 'WatchdogWindow.ps1')
    # Only one window at a time. Opening it again brings the open one to the front,
    # even when it's hidden in the tray.
    $createdNew = $false
    $windowMutex = New-Object System.Threading.Mutex($true, 'Local\AppleMusicWatchdogWindow', [ref]$createdNew)
    if (-not $createdNew) {
        Show-OpenWatchdogWindow
        return
    }
}

# 'watchdog stop', or the window when it opens, sets this event so a running
# watchdog can exit cleanly and log that it stopped.
$stopEvent = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\AppleMusicWatchdogStop')

# Only one watchdog per user session.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\AppleMusicWatchdog', [ref]$createdNew)
if (-not $createdNew) {
    if (-not $Window) {
        Write-Warning 'The watchdog is already running.'
        return
    }
    # The window takes over from a watchdog running in the background.
    [void]$stopEvent.Set()
    try { $acquired = $mutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Show-WatchdogError "The watchdog is already running in the background and didn't stop. Run 'watchdog stop', then open the window again."
        return
    }
}
[void]$stopEvent.Reset()

$opened = if ($Window) { 'Window opened' } else { 'Watchdog started in the background' }
Add-LogLine ("{0} (silence {1}s, cooldown {2}s, threshold {3})" -f $opened, $Settings.SilentSeconds, $Settings.CooldownSeconds, $Threshold)

try {
    if ($Window) {
        Show-WatchdogWindow
    }
    else {
        while ($true) {
            Invoke-WatchdogStep
            if ($stopEvent.WaitOne(500)) { break }
        }
    }
}
catch {
    Add-LogLine "Error: $($_.Exception.Message)"
    if ($Window) { Show-WatchdogError "The watchdog stopped because of an error: $($_.Exception.Message)" }
    throw
}
finally {
    [AppAudio]::SetKeepAwake($false)
    $stopEvent.Dispose()
    $mutex.ReleaseMutex()
    if ($windowMutex) { $windowMutex.ReleaseMutex() }
    Add-LogLine 'Watchdog stopped'
}
