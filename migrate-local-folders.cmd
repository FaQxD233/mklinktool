@echo off
setlocal
start "" "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0migrate-local-folders.ps1"
exit /b 0
