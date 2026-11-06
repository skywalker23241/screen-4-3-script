@echo off
setlocal
set "TARGET_WIDTH=1920"
set "TARGET_HEIGHT=1440"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ResolutionSwitch.ps1" -Action Apply -Width %TARGET_WIDTH% -Height %TARGET_HEIGHT%
echo.
pause
