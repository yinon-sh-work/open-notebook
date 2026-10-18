@echo off
REM Starts Open Notebook (offline bundle). Logs: logs\
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-OpenNotebook.ps1" %*
if errorlevel 1 pause
