@echo off
REM Install Android Emulator Hypervisor Driver (AEHD). Needs Administrator / UAC.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-aehd.ps1"
exit /b %ERRORLEVEL%
