@echo off
rem Double-click to open the watchdog window, or run from a terminal:
rem   watchdog [ui|start|stop|restart|status|check|install|uninstall|log]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Manage.ps1" %*
if errorlevel 1 if "%~1"=="" pause
