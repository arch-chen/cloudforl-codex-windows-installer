@echo off
setlocal
chcp 65001 >nul
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0bootstrap.ps1"
exit /b 0
