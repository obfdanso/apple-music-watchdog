# Starting the watchdog when you sign in to Windows: a scheduled task that runs it
# in the background with no console window (conhost --headless). Dot-sourced by
# Manage.ps1 ('watchdog install' and 'uninstall') and by the window's "Start when I
# sign in" switch, so both work on the same task.

$AutostartTaskName = 'AppleMusicWatchdog'

function Test-WatchdogAutostart {
    [bool](Get-ScheduledTask -TaskName $AutostartTaskName -ErrorAction SilentlyContinue)
}

function Register-WatchdogAutostart {
    # Always the built-in Windows PowerShell 5.1, even if this was started from PowerShell 7.
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $PSScriptRoot 'AppleMusicWatchdog.ps1'
    $arguments = '--headless "{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $powershell, $script
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $taskAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    # No time limit (the default stops tasks after 3 days) and keep going on battery.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $AutostartTaskName -Action $taskAction -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Pauses and resumes Apple Music when it goes silent.' -Force | Out-Null
}

function Unregister-WatchdogAutostart {
    if (Test-WatchdogAutostart) {
        Unregister-ScheduledTask -TaskName $AutostartTaskName -Confirm:$false
    }
}
