@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ResolutionSwitch.ps1" -Action Diagnose
echo.
pause
