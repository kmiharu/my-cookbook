@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_patch.ps1"
exit /b %ERRORLEVEL%
