@echo off
setlocal
rem The script path travels in an environment variable, so no character in it is parsed as PowerShell code.
rem -Command instead of -File: when the script cannot run at all (a parse error, or an execution policy enforced
rem by Group Policy), the catch below shows the error instead of printing it to the hidden console. Errors raised
rem while the script runs are reported by the script itself. Keep this file pure ASCII.
set "MKLINKTOOL_GUI_SCRIPT=%~dp0migrate-local-folders.ps1"
start "" "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { & $env:MKLINKTOOL_GUI_SCRIPT } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('mklinktool could not start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message, 'mklinktool', 'OK', 'Error') }"
exit /b 0
