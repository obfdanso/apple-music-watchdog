<#
.SYNOPSIS
    Open the Apple Music watchdog's window, start, stop and check it, or have it
    start when you sign in.

.EXAMPLE
    .\Manage.ps1 ui
.EXAMPLE
    .\Manage.ps1 start
.EXAMPLE
    .\Manage.ps1 install
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('ui', 'start', 'stop', 'restart', 'status', 'check', 'install', 'uninstall', 'log')]
    [string]$Action = 'ui'
)

$ErrorActionPreference = 'Stop'

$Watchdog = Join-Path $PSScriptRoot 'AppleMusicWatchdog.ps1'
$LogPath = Join-Path $env:LOCALAPPDATA 'AppleMusicWatchdog\watchdog.log'
$TaskName = 'AppleMusicWatchdog'
# Always the built-in Windows PowerShell 5.1, even if this was launched from PowerShell 7.
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WatchdogArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Watchdog`""
# conhost --headless runs PowerShell with no console window at all, so nothing flashes
# up on screen (not even when Windows Terminal is the default terminal).
$Conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$HeadlessArgs = "--headless `"$PowerShellExe`" $WatchdogArgs"
$ShortcutPaths = @(
    (Join-Path (Split-Path $PSScriptRoot) 'Apple Music Watchdog.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Apple Music Watchdog.lnk')
)

function Get-WatchdogProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*AppleMusicWatchdog.ps1*' -and $_.CommandLine -notlike '*-Check*' }
}

function Open-Window {
    # If the watchdog is running in the background, the window takes over from it.
    # If the window is already open, it is brought to the front.
    Start-Process -FilePath $Conhost -ArgumentList "$HeadlessArgs -Window"
}

function Get-AutostartTask {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Start-Watchdog {
    if (Get-WatchdogProcess) {
        Write-Output 'The watchdog is already running.'
        return
    }
    Start-Process -FilePath $Conhost -ArgumentList $HeadlessArgs
    Start-Sleep -Seconds 3
    if (Get-WatchdogProcess) {
        Write-Output 'Watchdog started. It runs in the background until you stop it or restart the PC.'
    }
    else {
        Write-Output "The watchdog didn't stay running. Try 'watchdog check' to see what's wrong."
    }
}

function Stop-Watchdog {
    $processes = @(Get-WatchdogProcess)
    if (-not $processes) {
        Write-Output 'The watchdog is not running.'
        return
    }
    # Ask it to stop so it can switch sleep back on and log that it stopped.
    $stopEvent = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\AppleMusicWatchdogStop', [ref]$stopEvent)) {
        [void]$stopEvent.Set()
        $stopEvent.Dispose()
        $processes | ForEach-Object { Wait-Process -Id $_.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }
    }
    # Anything still running (it didn't answer, or is an older version) is ended the hard way.
    $remaining = @(Get-WatchdogProcess)
    if ($remaining) {
        $remaining | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Add-Content -Path $LogPath -Value ('{0}  Watchdog stopped (forced)' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    }
    Write-Output 'Watchdog stopped.'
}

function Show-Status {
    $processes = @(Get-WatchdogProcess)
    if ($processes) {
        $where = if ($processes | Where-Object { $_.CommandLine -match '\s-Window(\s|$)' }) { 'in the window' } else { 'in the background' }
        Write-Output "Running: yes, $where (process $($processes.ProcessId -join ', '))"
    }
    else {
        Write-Output 'Running: no'
    }
    Write-Output ('Starts at sign-in: {0}' -f $(if (Get-AutostartTask) { 'yes' } else { 'no' }))
    Write-Output "Log: $LogPath"
    if (Test-Path $LogPath) {
        Write-Output ''
        Write-Output 'Last log entries:'
        Get-Content $LogPath -Tail 10 | ForEach-Object { Write-Output "  $_" }
    }
}

function Install-Autostart {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $taskAction = New-ScheduledTaskAction -Execute $Conhost -Argument $HeadlessArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    # No time limit (the default stops tasks after 3 days) and keep going on battery.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Pauses and resumes Apple Music when it goes silent.' -Force | Out-Null
    Write-Output 'The watchdog will now start automatically when you sign in.'
    Start-Watchdog
}

function Uninstall-Autostart {
    if (Get-AutostartTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output 'The watchdog will no longer start when you sign in.'
    }
    else {
        Write-Output 'Autostart was not set up.'
    }
    # The window adds these shortcuts the first time it opens.
    $shortcuts = @($ShortcutPaths | Where-Object { Test-Path $_ })
    if ($shortcuts) {
        $shortcuts | Remove-Item
        Write-Output 'Removed the Apple Music Watchdog shortcuts from the Start menu and this folder.'
    }
    if (Get-WatchdogProcess) {
        Write-Output "It is still running for now. Use 'watchdog stop' to stop it."
    }
}

switch ($Action) {
    'ui' { Open-Window }
    'start' { Start-Watchdog }
    'stop' { Stop-Watchdog }
    'restart' { Stop-Watchdog; Start-Watchdog }
    'status' { Show-Status }
    'check' { & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Watchdog -Check }
    'install' { Install-Autostart }
    'uninstall' { Uninstall-Autostart }
    'log' {
        if (Test-Path $LogPath) { Invoke-Item $LogPath } else { Write-Output 'No log yet.' }
    }
}
