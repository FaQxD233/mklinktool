param(
    [string]$PipeName,
    [ValidateSet('Accept', 'Silent', 'Reject', 'Die', 'DieEngineRuns')][string]$Mode,
    [int]$DelayMs = 2500,
    [string]$FinalStatus = 'Ready',
    [int]$ExitCode = 0
)
# Stand-in for migration-worker.ps1 (no elevation). Connects to the GUI pipe, reads one Execute request and
# then behaves according to $Mode. It never sends Hello: the test stubs Connect-ElevatedWorker.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(10000)
$reader = New-Object System.IO.StreamReader($pipe, $utf8)
$writer = New-Object System.IO.StreamWriter($pipe, $utf8)
$writer.NewLine = "`n"
$writer.AutoFlush = $true
$request = $reader.ReadLine() | ConvertFrom-Json
$session = [string]$request.SessionPath
$statePath = Join-Path $session 'state.json'
$resultPath = Join-Path $session ('result-' + [string]$request.RequestId + '.json')
$config = [System.IO.File]::ReadAllText((Join-Path $session 'job.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

function Write-State([string]$Phase, [int]$EnginePid, [string]$EngineStartTime, [string]$Status) {
    $jobs = @()
    $index = 0
    foreach ($job in @($config.Jobs)) {
        $jobs += [ordered]@{ Index = $index; Source = [string]$job.Source; Target = [string]$job.Target; FileCount = 1; TotalBytes = 1; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0; Warning = ''; Status = $Status; Error = '' }
        $index++
    }
    $state = [ordered]@{ Action = [string]$request.Action; Phase = $Phase; Success = ($ExitCode -eq 0); LogIncomplete = $false; EnginePid = $EnginePid; EngineStartTime = $EngineStartTime; Jobs = $jobs; Errors = @(); Warnings = @() }
    [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), $utf8)
}

function Write-Result {
    $result = [ordered]@{ Version = 1; RequestId = [string]$request.RequestId; Action = [string]$request.Action; EnginePid = $PID; ExitCode = $ExitCode; ParentEnded = $false; CompletedUtc = '' }
    [System.IO.File]::WriteAllText($resultPath + '.tmp', ($result | ConvertTo-Json), $utf8)
    [System.IO.File]::Move($resultPath + '.tmp', $resultPath)
}

function Wait-PipeEnd {
    try { $null = $reader.ReadLine() } catch { }
}

switch ($Mode) {
    'Accept' {
        $accepted = @{ Version = 1; Type = 'Accepted'; RequestId = [string]$request.RequestId; Action = [string]$request.Action; EnginePid = $PID; EngineStartTime = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTime() }
        $writer.WriteLine(($accepted | ConvertTo-Json -Compress))
        Start-Sleep -Milliseconds $DelayMs
        Write-State 'Complete' $PID '' $FinalStatus
        Write-Result
        Wait-PipeEnd
    }
    'Silent' {
        # The Accepted reply is lost, but the task still runs to completion.
        Start-Sleep -Milliseconds $DelayMs
        Write-State 'Complete' 0 '' $FinalStatus
        Write-Result
        Wait-PipeEnd
    }
    'Reject' {
        $writer.WriteLine((@{ Version = 1; Type = 'Error'; RequestId = [string]$request.RequestId; Message = 'rejected by fake worker' } | ConvertTo-Json -Compress))
        Wait-PipeEnd
    }
    'Die' {
        exit 3
    }
    'DieEngineRuns' {
        # Start a stand-in engine that outlives this worker. Deny the rights a medium-IL GUI cannot get on an
        # elevated process (PROCESS_QUERY_INFORMATION 0x400; SYNCHRONIZE 0x100000 for the worst case), publish
        # the engine identity in state.json, then die without writing a result.
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class FakeWorkerNative { [DllImport("advapi32.dll", SetLastError = true)] public static extern uint SetSecurityInfo(IntPtr handle, int objectType, int securityInfo, IntPtr owner, IntPtr group, byte[] dacl, IntPtr sacl); }'
        $psi = New-Object System.Diagnostics.ProcessStartInfo("$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile -Command Start-Sleep -Milliseconds $DelayMs")
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $engine = [System.Diagnostics.Process]::Start($psi)
        $engineStart = [string]$engine.StartTime.ToFileTime()
        $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor('D:(D;;0x100400;;;WD)(A;;0x1FFFFF;;;WD)')
        $dacl = New-Object byte[] $sd.DiscretionaryAcl.BinaryLength
        $sd.DiscretionaryAcl.GetBinaryForm($dacl, 0)
        [void][FakeWorkerNative]::SetSecurityInfo($engine.Handle, 6, 4, [IntPtr]::Zero, [IntPtr]::Zero, $dacl, [IntPtr]::Zero)
        Write-State 'Copying' $engine.Id $engineStart 'Copying'
        exit 4
    }
}
