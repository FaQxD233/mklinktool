@echo off
setlocal
set "BASE=%~dp0"
fltmc >nul 2>&1
if not errorlevel 1 goto :run
for /f %%I in ('powershell.exe -NoLogo -NoProfile -Command "[guid]::NewGuid().ToString()"') do set "DROP_SESSION=%%I"
if not defined DROP_SESSION exit /b 1
set "DROP_INBOX=%TEMP%\mklinktool-drop-%DROP_SESSION%"
mkdir "%DROP_INBOX%" >nul 2>&1
if not exist "%DROP_INBOX%\" exit /b 1
start "mklinktool drag receiver" powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%BASE%migrate-local-folders-drop-receiver.ps1" -InboxPath "%DROP_INBOX%"
set "MKLINKTOOL_LAUNCHER=%~f0"
set "MKLINKTOOL_DROP_INBOX=%DROP_INBOX%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $arguments='/d /c '+$q+$q+$env:MKLINKTOOL_LAUNCHER+$q+' '+$q+$env:MKLINKTOOL_DROP_INBOX+$q+$q; try { Start-Process -FilePath $env:ComSpec -Verb RunAs -ArgumentList $arguments -ErrorAction Stop } catch { exit 1 }"
exit /b %ERRORLEVEL%
:run
set "DROP_INBOX=%~1"
cd /d "%BASE%"
set "LOG=%BASE%migrate-local-folders-launch.log"
echo Starting the directory migration GUI.>"%LOG%"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%BASE%migrate-local-folders.ps1" -DropInboxPath "%DROP_INBOX%" >>"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo GUI process exit code: %RC%>>"%LOG%"
exit /b %RC%