param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^mklinktool-pipe-[a-fA-F0-9]{32}$')]
    [string]$PipeName,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$ParentPid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MklinkToolPipeNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);
}
'@

function Send-Message($Writer, [hashtable]$Message) {
    $Message.Version = 1
    $Writer.WriteLine(($Message | ConvertTo-Json -Depth 5 -Compress))
    $Writer.Flush()
}

function Test-ParentAlive([System.Diagnostics.Process]$ParentProcess) {
    try {
        $ParentProcess.Refresh()
        return -not $ParentProcess.HasExited
    } catch {
        return $false
    }
}

function Resolve-SessionPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $directory = [System.IO.DirectoryInfo]::new($fullPath)
    if ($null -eq $directory.Parent -or
        -not [string]::Equals($directory.Parent.FullName.TrimEnd('\'), $tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ($directory.Name -match '^mklinktool-[a-fA-F0-9]{32}$')) {
        throw 'The job session must be a direct GUID-named child of the current user temp directory.'
    }
    if (-not [System.IO.Directory]::Exists($fullPath)) { throw 'The job session directory does not exist.' }
    if (([System.IO.File]::GetAttributes($fullPath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The job session directory cannot be a reparse point.'
    }
    return $fullPath
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The migration worker was not started with an elevated token.'
}

$pipe = $null
$reader = $null
$writer = $null
$parentProcess = $null
try {
    $parentProcess = [System.Diagnostics.Process]::GetProcessById($ParentPid)
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(20000)

    [uint32]$serverPid = 0
    if (-not [MklinkToolPipeNative]::GetNamedPipeServerProcessId($pipe.SafePipeHandle.DangerousGetHandle(), [ref]$serverPid) -or $serverPid -ne [uint32]$ParentPid) {
        throw 'The named-pipe server process does not match the expected main-window process.'
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $reader = New-Object System.IO.StreamReader($pipe, $utf8)
    $writer = New-Object System.IO.StreamWriter($pipe, $utf8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true

    Send-Message $writer @{ Type = 'Hello'; WorkerPid = $PID; ParentPid = $ParentPid }
    $helloAckLine = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($helloAckLine) -or $helloAckLine.Length -gt 65536) {
        throw 'The main window did not complete the worker handshake.'
    }
    $helloAck = $helloAckLine | ConvertFrom-Json -ErrorAction Stop
    if ([int]$helloAck.Version -ne 1 -or [string]$helloAck.Type -ne 'HelloAck' -or [int]$helloAck.ParentPid -ne $ParentPid) {
        throw 'The main window sent an invalid worker handshake.'
    }

    $shouldStop = $false
    while (-not $shouldStop) {
        $requestLine = $reader.ReadLine()
        if ($null -eq $requestLine) { break }
        if ($requestLine.Length -gt 1048576) {
            Send-Message $writer @{ Type = 'Error'; Message = 'The request exceeded the protocol size limit.' }
            continue
        }

        try {
            $engineProcess = $null
            $request = $requestLine | ConvertFrom-Json -ErrorAction Stop
            if ([int]$request.Version -ne 1) { throw 'Unsupported protocol version.' }
            if ([string]$request.Type -eq 'Shutdown') {
                Send-Message $writer @{ Type = 'Bye' }
                $shouldStop = $true
                continue
            }
            if ([string]$request.Type -ne 'Execute') { throw 'Unsupported worker command.' }

            $requestId = [string]$request.RequestId
            if ($requestId -notmatch '^[a-fA-F0-9]{32}$') { throw 'Invalid request identifier.' }
            $action = [string]$request.Action
            if ($action -notin @('Analyze', 'Migrate')) { throw 'Unsupported engine action.' }

            $sessionPath = Resolve-SessionPath ([string]$request.SessionPath)
            $configPath = Join-Path $sessionPath 'job.json'
            $statePath = Join-Path $sessionPath 'state.json'
            $logPath = Join-Path $sessionPath 'engine.log'
            $robocopyLogPath = Join-Path $sessionPath 'robocopy.log'
            $resultPath = Join-Path $sessionPath ('result-{0}.json' -f $requestId)
            $temporaryResultPath = $resultPath + '.tmp'
            if (-not [System.IO.File]::Exists($configPath)) { throw 'The job configuration file is missing.' }
            if (([System.IO.File]::GetAttributes($configPath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The job configuration file cannot be a reparse point.'
            }
            if ((New-Object System.IO.FileInfo($configPath)).Length -gt 16777216) { throw 'The job configuration exceeds 16 MiB.' }
            if ([System.IO.File]::Exists($resultPath)) { throw 'A result file already exists for this request.' }
            if ([System.IO.File]::Exists($temporaryResultPath)) { throw 'A temporary result file already exists for this request.' }
            foreach ($engineFilePath in @($statePath, $logPath, $robocopyLogPath)) {
                if ([System.IO.File]::Exists($engineFilePath) -and
                    (([System.IO.File]::GetAttributes($engineFilePath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw 'An engine output file cannot be a reparse point.'
                }
            }

            $enginePath = Join-Path $PSScriptRoot 'migration-engine.ps1'
            if (-not [System.IO.File]::Exists($enginePath)) { throw 'The migration engine script is missing.' }
            $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -ConfigPath "{2}" -StatePath "{3}" -LogPath "{4}" -RobocopyLogPath "{5}"' -f $enginePath, $action, $configPath, $statePath, $logPath, $robocopyLogPath
            $engineProcess = Start-Process -FilePath $powershellPath -ArgumentList $arguments -PassThru -WindowStyle Hidden
            Send-Message $writer @{ Type = 'Accepted'; RequestId = $requestId; Action = $action; EnginePid = $engineProcess.Id }

            $parentEnded = $false
            while (-not $engineProcess.WaitForExit(1000)) {
                if (-not (Test-ParentAlive $parentProcess)) { $parentEnded = $true }
            }
            $engineProcess.Refresh()

            $result = [ordered]@{
                Version = 1
                RequestId = $requestId
                Action = $action
                EnginePid = $engineProcess.Id
                ExitCode = $engineProcess.ExitCode
                ParentEnded = $parentEnded
                CompletedUtc = [DateTime]::UtcNow.ToString('o')
            }
            [System.IO.File]::WriteAllText($temporaryResultPath, ($result | ConvertTo-Json -Depth 4), $utf8)
            [System.IO.File]::Move($temporaryResultPath, $resultPath)
            $engineProcess.Dispose()
            if ($parentEnded) { $shouldStop = $true }
        } catch {
            if ($null -ne $engineProcess) {
                try {
                    while (-not $engineProcess.WaitForExit(1000)) { }
                    $engineProcess.Dispose()
                } catch { }
                $shouldStop = $true
                break
            }
            $requestIdForError = ''
            try { $requestIdForError = [string]$request.RequestId } catch { }
            Send-Message $writer @{ Type = 'Error'; RequestId = $requestIdForError; Message = $_.Exception.Message }
        }
    }
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $pipe) { $pipe.Dispose() }
    if ($null -ne $parentProcess) { $parentProcess.Dispose() }
}
