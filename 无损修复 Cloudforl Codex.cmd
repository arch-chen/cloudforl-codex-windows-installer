@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0repair.ps1" -SourceRoot "%~dp0"
exit /b %errorlevel%
