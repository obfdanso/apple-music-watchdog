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

.PARAMETER CheckHost
    The server the watchdog connects to, to tell whether the internet is
    working before it tries a fix. One of Apple Music's own.

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

    [string]$CheckHost = 'amp-api.music.apple.com',

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
    FadeOut          = $true               # fade the music out over the timer's last 30 seconds
    CloseToTray      = $false
    RestartAppleMusic = $true              # as a last resort, when nothing else brings the sound back
    RespectPause     = $false              # never press play on music that's paused
    Notify           = $true               # Windows notifications when something goes wrong
    Font             = 'Default'           # 'Default' or 'System' (SystemFont below)
    SystemFont       = ''
    RestoreVolume    = -1.0                # Apple Music's volume before a fade, until it's put back
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

# Hand-edited values: a whole number in range, or the default if it isn't one.
function ConvertTo-SettingNumber($Value, [int]$Minimum, [int]$Maximum, [int]$Default) {
    $number = 0
    $styles = [Globalization.NumberStyles]::Integer
    if (-not [int]::TryParse([string]$Value, $styles, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { $number = $Default }
    [Math]::Min($Maximum, [Math]::Max($Minimum, $number))
}

# On or off. Text counts as on only if it says "true", so "false" stays off.
function ConvertTo-SettingSwitch($Value) {
    if ($Value -is [string]) { return $Value.Trim() -eq 'true' }
    [bool]$Value
}

$Settings.SilentSeconds = ConvertTo-SettingNumber $Settings.SilentSeconds 3 600 12
$Settings.CooldownSeconds = ConvertTo-SettingNumber $Settings.CooldownSeconds 0 3600 20
$Settings.StopAfterHours = ConvertTo-SettingNumber $Settings.StopAfterHours 0 23 1
$Settings.StopAfterMinutes = ConvertTo-SettingNumber $Settings.StopAfterMinutes 0 59 0
foreach ($name in 'KeepAwake', 'StopAfterEnabled', 'PauseWhenDone', 'FadeOut', 'CloseToTray', 'RestartAppleMusic', 'RespectPause', 'Notify') { $Settings[$name] = ConvertTo-SettingSwitch $Settings[$name] }
if ($Settings.Font -notin 'Default', 'System') { $Settings.Font = 'Default' }
$Settings.SystemFont = [string]$Settings.SystemFont
$volume = 0.0
if (-not [double]::TryParse([string]$Settings.RestoreVolume, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$volume) -or $volume -gt 1) { $volume = -1.0 }
$Settings.RestoreVolume = $volume

# Values given on the command line win over saved ones, for this run only. They
# aren't saved unless you change them in the window.
$CommandLine = @{}
if ($PSBoundParameters.ContainsKey('SilentSeconds')) { $CommandLine.SilentSeconds = $SilentSeconds }
if ($PSBoundParameters.ContainsKey('CooldownSeconds')) { $CommandLine.CooldownSeconds = $CooldownSeconds }
if ($PSBoundParameters.ContainsKey('AllowSleep')) { $CommandLine.KeepAwake = -not $AllowSleep }
$SavedValues = @{}
foreach ($name in $CommandLine.Keys) {
    $SavedValues[$name] = $Settings[$name]
    $Settings[$name] = $CommandLine[$name]
}

function Save-WatchdogSetting {
    $dir = Split-Path $SettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $toSave = $Settings.Clone()
    foreach ($name in $CommandLine.Keys) {
        # Still the command-line value: keep what was saved before.
        if ($toSave[$name] -eq $CommandLine[$name]) { $toSave[$name] = $SavedValues[$name] }
    }
    $toSave | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
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
    LastFixKind   = ''                     # what the last fix did (see $FixSteps)
    LastFixTitle  = ''                     # the song that went silent
    LastFixCut    = $false                 # whether Apple Music was paused or stopped during the last fix
    FixKind       = ''                     # what the fix under way is doing
    FailedFixes   = 0                      # fixes in a row that didn't bring the sound back
    AppId         = ''                     # Apple Music's app ID, to open it again after a restart
    RestartedAt   = [datetime]::MinValue   # when the watchdog last restarted Apple Music
    RestartTried  = $false                 # whether it has restarted Apple Music since the sound last came back
    BackAt        = $null                  # when Apple Music came back after a restart
    Probe         = $null                  # the connection check under way, if any
    ProbeTask     = $null
    ProbeUntil    = [datetime]::MinValue   # when it counts as failed
    ProbeAt       = [datetime]::MinValue   # when to check again while the internet is down
    OfflineSince  = $null
    StoppedAt     = $null                  # when Apple Music stopped playing while the internet was down
    FadeFrom      = -1.0                   # Apple Music's volume before the timer started fading it out
    LastStatus    = ''                     # Apple Music's status at the previous check
    PausedByYou   = $false                 # Apple Music was paused, and not by the watchdog
}

# The ways the watchdog tries to get the sound back, gentlest first. Each time one
# doesn't work, the next silence gets the next one; once the sound comes back, it
# starts from the top again. After these, it restarts Apple Music (at most every
# half hour, and only if that's switched on), then keeps to pausing and playing.
$FixSteps = @('PausePlay', 'PausePlay', 'RestartSong', 'NextSong')

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

# The watchdog's identity in Windows: the taskbar and notifications use it. The
# window's Start menu shortcut carries it too, which notifications need.
$AppId = 'obfdanso.AppleMusicWatchdog'

# A silent Windows notification (so it doesn't talk over the music), if they're
# switched on. Does nothing if Windows won't show it, for example before the window
# has been opened once to add the Start menu shortcut.
function Show-WatchdogNotification([string]$Title, [string]$Text) {
    if (-not $Settings.Notify) { return }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml(('<toast><visual><binding template="ToastGeneric"><text>{0}</text><text>{1}</text></binding></visual><audio silent="true"/></toast>' -f
                [Security.SecurityElement]::Escape($Title), [Security.SecurityElement]::Escape($Text)))
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    }
    catch { Write-Verbose "Couldn't show a notification: $($_.Exception.Message)" }
}

# Starts checking, in the background, whether Apple Music's servers can be reached.
# Pausing and playing can't help while they can't.
function Start-ConnectionCheck {
    Stop-ConnectionCheck
    $State.Probe = New-Object System.Net.Sockets.TcpClient
    $State.ProbeTask = $State.Probe.ConnectAsync($CheckHost, 443)
    $State.ProbeUntil = (Get-Date).AddSeconds(5)
}

# The result of the connection check: $true (online), $false (offline), or $null
# while it's still going.
function Get-ConnectionResult {
    $task = $State.ProbeTask
    if ($task.IsCompleted) {
        $online = $task.Status -eq 'RanToCompletion'
        [void]$task.Exception   # seen, so .NET doesn't report it as unhandled
    }
    elseif ((Get-Date) -ge $State.ProbeUntil) { $online = $false }
    else { return $null }
    Stop-ConnectionCheck
    $online
}

function Stop-ConnectionCheck {
    if ($State.Probe) { $State.Probe.Dispose() }
    $State.Probe = $null
    $State.ProbeTask = $null
}

# Which fix to try next, given how many in a row haven't worked.
function Get-FixKind($Session) {
    # Once the other fixes have all failed. If the last restart was under half an hour
    # ago, it waits, and restarts on a later attempt once the half hour is up.
    if ($State.FailedFixes -ge $FixSteps.Count -and -not $State.RestartTried -and $Settings.RestartAppleMusic -and
        ((Get-Date) - $State.RestartedAt).TotalMinutes -ge 30) {
        $State.RestartTried = $true
        return 'RestartApp'
    }
    $kind = if ($State.FailedFixes -lt $FixSteps.Count) { $FixSteps[$State.FailedFixes] } else { 'PausePlay' }
    $controls = $Session.GetPlaybackInfo().Controls
    # "Skip back" only restarts the song a few seconds in; earlier, it goes to the previous song.
    if ($kind -eq 'RestartSong' -and (-not $controls.IsPreviousEnabled -or $State.Position -lt 5)) { $kind = 'NextSong' }
    if ($kind -eq 'NextSong' -and -not $controls.IsNextEnabled) { $kind = 'PausePlay' }
    $kind
}

# Starts a fix. The rest of it happens over the next few calls of Invoke-WatchdogStep.
function Start-Fix($Session, [string]$Kind, [datetime]$Now, [string]$Reason) {
    $State.Fixes++
    $State.FixKind = $Kind
    $State.FixSession = $Session
    $State.LastFixTitle = $State.Title
    $State.SilentSince = $null
    $title = if ($State.Title) { $State.Title } else { '?' }
    $doing = switch ($Kind) {
        'PausePlay' { 'Pausing and resuming' }
        'RestartSong' { 'Restarting the song' }
        'NextSong' { 'Skipping to the next song' }
        'RestartApp' { 'Restarting Apple Music' }
        'Play' { 'Pressing play' }
    }
    Add-LogLine ("{0} ('{1}'). {2} (fix #{3})." -f $Reason, $title, $doing, $State.Fixes)
    switch ($Kind) {
        'Play' {
            [void](Wait-AsyncOperation ($Session.TryPlayAsync()) ([bool]))
            $State.Phase = 'Resumed'
            $State.PhaseAt = $Now.AddSeconds(4)
        }
        'PausePlay' {
            [void](Wait-AsyncOperation ($Session.TryPauseAsync()) ([bool]))
            $State.Phase = 'Paused'
            $State.PhaseAt = $Now.AddSeconds(1.5)
        }
        'RestartSong' {
            [void](Wait-AsyncOperation ($Session.TrySkipPreviousAsync()) ([bool]))
            $State.Phase = 'Resumed'
            $State.PhaseAt = $Now.AddSeconds(4)
        }
        'NextSong' {
            [void](Wait-AsyncOperation ($Session.TrySkipNextAsync()) ([bool]))
            $State.Phase = 'Resumed'
            $State.PhaseAt = $Now.AddSeconds(4)
        }
        'RestartApp' {
            # Close it (it may not respond), open it again 2s later, then press play.
            $State.AppId = $Session.SourceAppUserModelId
            $State.RestartedAt = $Now
            Get-Process -Name $AudioProcesses -ErrorAction SilentlyContinue | Stop-Process -Force
            $State.Phase = 'Restarting'
            $State.PhaseAt = $Now.AddSeconds(2)
        }
    }
}

# Ends the fix under way: notes whether the sound came back, so the next one can
# try something else if it didn't.
function Complete-Fix([datetime]$Now, [bool]$Worked, [switch]$Abandoned) {
    if (-not $Abandoned) { Add-LogLine ('After resume: level={0:N4}' -f $State.Level) }
    $State.LastFixAt = $Now
    $State.LastFixWorked = $Worked
    $State.LastFixCut = [bool]$Abandoned
    $State.LastFixKind = $State.FixKind
    if ($Worked) { $State.FailedFixes = 0; $State.RestartTried = $false } elseif (-not $Abandoned) { $State.FailedFixes++ }
    $song = if ($State.LastFixTitle) { " ($($State.LastFixTitle))" } else { '' }
    if ($Worked -and $State.FixKind -ne 'PausePlay') {
        $did = switch ($State.FixKind) {
            'RestartSong' { 'Restarted the song' }
            'NextSong' { 'Skipped to the next song' }
            'RestartApp' { 'Restarted Apple Music' }
            default { 'Pressed play after the internet came back' }
        }
        Show-WatchdogNotification 'The sound is back' "$did$song."
    }
    elseif (-not $Worked -and -not $Abandoned -and $State.FailedFixes -eq $FixSteps.Count + 1) {
        Show-WatchdogNotification "Couldn't get the sound back" ("Nothing the watchdog tried has worked{0}. It will keep trying about every {1} seconds." -f $song, [Math]::Max($Settings.CooldownSeconds, $Settings.SilentSeconds))
    }
    $State.Phase = 'Watching'
    $State.FixKind = ''
    $State.FixSession = $null
    $State.CooldownUntil = $Now.AddSeconds($Settings.CooldownSeconds)
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
        # Paused (or stopped) since the last check, and not by the watchdog's own pause or restart?
        if ($State.LastStatus -eq 'Playing' -and $session -and -not $playing -and $State.Phase -notin 'Paused', 'Restarting', 'Launching') {
            $State.PausedByYou = $true
        }
        if ($playing) { $State.PausedByYou = $false }
        $State.LastStatus = $State.Status
        $State.Level = [AppAudio]::GetPeak($AudioProcesses)
        if ($Settings.RestoreVolume -ge 0 -and $State.FadeFrom -lt 0 -and $State.Level -ge 0) {
            # A fade-out was cut short (the PC shut down, say), or Apple Music was closed
            # when it should have been put back: put the volume back now it's open.
            if ([AppAudio]::SetVolume($AudioProcesses, $Settings.RestoreVolume) -gt 0) {
                $Settings.RestoreVolume = -1.0
                Save-WatchdogSetting
                Add-LogLine 'Put the volume back after an unfinished fade-out'
            }
        }
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

        $silentFor = if ($State.SilentSince) { ($now - $State.SilentSince).TotalSeconds } else { 0 }
        switch ($State.Phase) {
            'Checking' {
                # About to fix: first, is the internet working?
                $online = Get-ConnectionResult
                if (-not $State.Active -or -not $playing -or $State.Level -ge $Threshold) {
                    # Sorted itself out (or you stopped watching) in the meantime.
                    Stop-ConnectionCheck
                    $State.Phase = 'Watching'
                }
                elseif ($online -eq $true) {
                    $State.Phase = 'Watching'
                    Start-Fix $session (Get-FixKind $session) $now ("Silent for {0:N0}s while 'Playing'" -f $silentFor)
                }
                elseif ($online -eq $false) {
                    Add-LogLine "Silent, and Apple Music can't be reached. Waiting for the connection to come back."
                    Show-WatchdogNotification "Apple Music can't connect" 'No sound, and the internet seems to be down. The watchdog will fix the sound once it''s back.'
                    $State.Phase = 'Offline'
                    $State.OfflineSince = $now
                    $State.ProbeAt = $now.AddSeconds(5)
                    $State.StoppedAt = $null
                }
            }
            'Offline' {
                # Waiting for the internet. Checks again every 5 seconds, then fixes the
                # sound straight away.
                if ($playing) { $State.StoppedAt = $null } elseif ($session -and -not $State.StoppedAt) { $State.StoppedAt = $now }
                $online = $null
                if ($State.Probe) {
                    $online = Get-ConnectionResult
                    if ($online -eq $false) { $State.ProbeAt = $now.AddSeconds(5) }
                }
                elseif ($now -ge $State.ProbeAt) { Start-ConnectionCheck }

                if (-not $State.Active -or ($playing -and $State.Level -ge $Threshold)) {
                    # You stopped watching, or the sound came back by itself.
                    if ($State.Active) { Add-LogLine 'Sound came back' }
                    Stop-ConnectionCheck
                    $State.Phase = 'Watching'
                    $State.SilentSince = $null
                }
                elseif ($online -eq $true) {
                    Add-LogLine ('The connection is back after {0:N0}s' -f ($now - $State.OfflineSince).TotalSeconds)
                    $State.Phase = 'Watching'
                    if ($playing) {
                        Start-Fix $session (Get-FixKind $session) $now 'Still silent after the connection came back'
                    }
                    elseif ($session -and $State.StoppedAt -and ($now - $State.StoppedAt).TotalMinutes -lt 10) {
                        # It can't tell whether you paused it or Apple Music gave up, so with
                        # "Stay paused when I pause" on, it leaves it paused.
                        if ($Settings.RespectPause) { Add-LogLine 'Apple Music was paused while the connection was down. Leaving it paused.' }
                        else { Start-Fix $session 'Play' $now 'Apple Music stopped while the connection was down' }
                    }
                }
            }
            'Paused' {
                if ($now -ge $State.PhaseAt) {
                    # Already playing again if you pressed play yourself in the meantime.
                    if ($State.Status -ne 'Playing') { [void](Wait-AsyncOperation ($State.FixSession.TryPlayAsync()) ([bool])) }
                    $State.Phase = 'Resumed'
                    $State.PhaseAt = $now.AddSeconds(3)
                }
            }
            'Restarting' {
                if ($now -ge $State.PhaseAt) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($State.AppId)"
                    $State.Phase = 'Launching'
                    $State.PhaseAt = $now.AddSeconds(60)   # give up if it hasn't opened by then
                    $State.BackAt = $null
                }
            }
            'Launching' {
                # Once it's back, give it a few seconds to load the song before pressing play.
                if ($session -and -not $State.BackAt) { $State.BackAt = $now }
                if ($session -and ($now - $State.BackAt).TotalSeconds -ge 5) {
                    [void](Wait-AsyncOperation ($session.TryPlayAsync()) ([bool]))
                    $State.FixSession = $session
                    $State.Phase = 'Resumed'
                    $State.PhaseAt = $now.AddSeconds(5)
                }
                elseif ($now -ge $State.PhaseAt) {
                    Add-LogLine "Apple Music didn't open again"
                    Complete-Fix $now $false
                }
            }
            'Resumed' {
                if ($now -ge $State.PhaseAt) {
                    if ($playing) { Complete-Fix $now ($State.Level -ge $Threshold) }
                    else {
                        # Paused or stopped in the meantime (by you, say), so there's nothing to judge.
                        Add-LogLine 'Apple Music stopped playing during the fix'
                        Complete-Fix $now $false -Abandoned
                    }
                }
            }
            default {
                $audible = $playing -and $State.Level -ge $Threshold
                if ($audible -and $State.LastFixAt -and -not $State.LastFixWorked -and ($now - $State.LastFixAt).TotalSeconds -lt 60) {
                    # The sound came back a little after the last fix was checked.
                    $State.LastFixWorked = $true
                    Add-LogLine ('Sound came back {0:N0}s after the fix' -f ($now - $State.LastFixAt).TotalSeconds)
                }
                if ($audible) { $State.FailedFixes = 0; $State.RestartTried = $false }

                if ($State.Active -and $playing -and $State.Level -lt $Threshold) {
                    if (-not $State.SilentSince) { $State.SilentSince = $now }
                }
                else {
                    $State.SilentSince = $null
                }
                $silentFor = if ($State.SilentSince) { ($now - $State.SilentSince).TotalSeconds } else { 0 }

                if ($silentFor -ge $Settings.SilentSeconds -and $now -ge $State.CooldownUntil) {
                    Start-ConnectionCheck
                    $State.Phase = 'Checking'
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
        if ($State.Phase -in 'Restarting', 'Launching' -and ((Get-Date) - $State.RestartedAt).TotalSeconds -lt 90) {
            # Restarting Apple Music, which is exactly when errors like this happen. Carry
            # on, or it would be left closed (or open but not playing).
            return
        }
        if ($State.Phase -eq 'Paused' -and $State.FixSession) {
            # Paused for a fix: press play before giving up on it, so the music isn't left paused.
            try { [void](Wait-AsyncOperation ($State.FixSession.TryPlayAsync()) ([bool])) }
            catch { Write-Verbose "Couldn't press play again: $($_.Exception.Message)" }
        }
        $State.Phase = 'Watching'
        $State.FixKind = ''
        $State.FixSession = $null
        Stop-ConnectionCheck
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
    # Stopped halfway through a fix (paused, not played again yet): press play so
    # the music isn't left paused.
    if ($State.Phase -eq 'Paused' -and $State.FixSession) {
        try {
            [void](Wait-AsyncOperation ($State.FixSession.TryPlayAsync()) ([bool]))
            Add-LogLine 'Pressed play again before stopping'
        }
        catch { Write-Verbose "Couldn't press play again: $($_.Exception.Message)" }
    }
    if ($State.Phase -eq 'Restarting' -and $State.AppId) {
        # Stopped after closing Apple Music for a restart but before opening it again.
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($State.AppId)"
            Add-LogLine 'Opened Apple Music again before stopping'
        }
        catch { Write-Verbose "Couldn't open Apple Music again: $($_.Exception.Message)" }
    }
    if ($State.FadeFrom -ge 0) {
        # Stopped while fading the music out: put the volume back. If Apple Music isn't
        # open, the saved volume stays, and is put back next time.
        try {
            if ([AppAudio]::SetVolume($AudioProcesses, $State.FadeFrom) -gt 0) {
                $Settings.RestoreVolume = -1.0
                Save-WatchdogSetting
            }
        }
        catch { Write-Verbose "Couldn't put the volume back: $($_.Exception.Message)" }
    }
    [AppAudio]::SetKeepAwake($false)
    $stopEvent.Dispose()
    $mutex.ReleaseMutex()
    if ($windowMutex) { $windowMutex.ReleaseMutex() }
    Add-LogLine 'Watchdog stopped'
}
