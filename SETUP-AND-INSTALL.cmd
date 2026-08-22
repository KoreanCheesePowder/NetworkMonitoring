@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SETUP-AND-INSTALL.ps1"
echo.
pause
