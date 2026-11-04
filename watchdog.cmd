@echo off
rem Double-click to start the watchdog, or run from a terminal:
rem   watchdog [start|stop|restart|status|check|install|uninstall|log]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Manage.ps1" %*
if "%~1"=="" pause
