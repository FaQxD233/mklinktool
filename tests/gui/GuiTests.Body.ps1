# GUI 测试主体：由 tests\Test-Gui.ps1 点调用进 migrate-local-folders.ps1 的副本（替换末尾的 [void]$form.ShowDialog()），
# 在 GUI 脚本作用域内运行。窗体移到屏幕外 Show()；Worker 由 FakeWorker.ps1 进程扮演，不走 UAC。
$testDir = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $testDir) 'TestHelpers.ps1')
. (Join-Path $testDir 'GuiHarness.ps1')
$fakeWorkerPath = Join-Path $testDir 'FakeWorker.ps1'
$script:EnginePath = Join-Path (Split-Path -Parent (Split-Path -Parent $testDir)) 'migration-engine.ps1'
$script:RecoveryJournalRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-gui-tests-journal-' + [guid]::NewGuid().ToString('N'))
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 窗口显示时会检查中断记录并清理旧会话目录：测试里换成桩，不读写真实的 %LOCALAPPDATA% 与 %TEMP%。
$script:RealRemoveStaleSessionDirectories = ${function:Remove-StaleSessionDirectories}
function Remove-StaleSessionDirectories { return 0 }
function Find-InterruptedMigrations { return }
# 测试自行接好假 Worker 的管道，不走 UAC。
function Connect-ElevatedWorker { }

Show-TestForm
$utf8 = New-Object System.Text.UTF8Encoding($false)
$createdSessions = New-Object System.Collections.Generic.List[string]
$cleanupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-gui-tests-sessions-' + [guid]::NewGuid().ToString('N'))
$permissionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-gui-tests-permissions-' + [guid]::NewGuid().ToString('N'))

function Reset-TestJobs {
    $script:Jobs.Clear()
    foreach ($name in @('A', 'B')) {
        [void]$script:Jobs.Add([pscustomobject]@{
            Source = "C:\mkl-test-src\$name"; Target = "D:\mkl-test-dst\$name"; IsCustomTarget = $false
            FileCount = 0; TotalBytes = 0L; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0
            Status = 'NotChecked'; Warning = ''; PermissionWarning = ''; Error = ''; CleanupTarget = ''
        })
    }
    Refresh-Grid
}

function Start-StandIn([string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo($powershellExe, $Arguments)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Connect-FakeWorker([string]$Mode, [int]$DelayMs = 2500, [string]$FinalStatus = 'Ready', [int]$ExitCode = 0) {
    $pipeName = 'mkl-test-' + [guid]::NewGuid().ToString('N')
    $server = [System.IO.Pipes.NamedPipeServerStream]::new($pipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536)
    $pending = $server.BeginWaitForConnection($null, $null)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PipeName {1} -Mode {2} -DelayMs {3} -FinalStatus {4} -ExitCode {5}' -f $fakeWorkerPath, $pipeName, $Mode, $DelayMs, $FinalStatus, $ExitCode
    $process = Start-StandIn $arguments
    if (-not $pending.AsyncWaitHandle.WaitOne(20000)) { throw 'fake worker did not connect' }
    $server.EndWaitForConnection($pending)
    $script:WorkerPipe = $server
    $script:WorkerReader = New-Object System.IO.StreamReader($server, $utf8)
    $script:WorkerWriter = New-Object System.IO.StreamWriter($server, $utf8)
    $script:WorkerWriter.NewLine = [Environment]::NewLine
    $script:WorkerWriter.AutoFlush = $true
    $script:Worker = $process
}

function Complete-Case {
    if (-not [string]::IsNullOrEmpty($script:WorkerSessionPath)) { $createdSessions.Add($script:WorkerSessionPath) }
    Close-ElevatedWorker
    $script:WorkerReadTimeoutMs = 30000
}

function New-SessionDirectory([string]$Root, [string]$Name, [int]$AgeDays, [string[]]$Files) {
    # 造一个会话目录：写入文件后把文件与目录的修改时间统一改到 $AgeDays 天前（最后改目录，写文件会刷新目录时间）。
    $path = Join-Path $Root $Name
    [void][System.IO.Directory]::CreateDirectory($path)
    $stamp = [DateTime]::UtcNow.AddDays(-$AgeDays)
    foreach ($file in $Files) {
        $filePath = Join-Path $path $file
        [System.IO.File]::WriteAllText($filePath, '{}', $utf8)
        [System.IO.File]::SetLastWriteTimeUtc($filePath, $stamp)
    }
    [System.IO.Directory]::SetLastWriteTimeUtc($path, $stamp)
    return $path
}

try {
    '[G1] final state is read when the engine finishes between two polling steps'
    Reset-TestJobs
    $session = Join-Path ([System.IO.Path]::GetTempPath()) ('mklinktool-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($session)
    $createdSessions.Add($session)
    $requestId = [guid]::NewGuid().ToString('N')
    $script:Worker = Start-StandIn '-NoProfile -Command Start-Sleep -Seconds 30'
    Enter-WorkerTask 'Analyze' @($script:Jobs) '' $requestId $session 0 '' ''
    $script:WorkerTimer.Stop()
    $midJobs = @(
        [ordered]@{ Index = 0; Status = 'Ready'; Error = ''; Warning = ''; FileCount = 3; TotalBytes = 10; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0 },
        [ordered]@{ Index = 1; Status = 'Ready'; Error = ''; Warning = ''; FileCount = 4; TotalBytes = 20; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0 })
    [System.IO.File]::WriteAllText($script:WorkerStatePath, ([ordered]@{ Action = 'Analyze'; Phase = 'Analyzing'; Success = $false; Jobs = $midJobs } | ConvertTo-Json -Depth 6), $utf8)
    [System.IO.File]::WriteAllText($script:WorkerLogPath, "[t] scanning`r`n", $utf8)
    $script:OriginalRefreshGrid = ${function:Refresh-Grid}
    $script:Injected = $false
    # Refresh-Grid 位于一次轮询的中间：第一次调用时写入最终状态与结果文件，模拟引擎恰好在两步之间结束。
    function Refresh-Grid {
        & $script:OriginalRefreshGrid
        if (-not $script:Injected -and $script:ActiveJob) {
            $script:Injected = $true
            $conflict = 'CONFLICT: sources contain each other'
            $finalJobs = @(
                [ordered]@{ Index = 0; Status = 'Error'; Error = $conflict; Warning = ''; FileCount = 3; TotalBytes = 10; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0 },
                [ordered]@{ Index = 1; Status = 'Error'; Error = $conflict; Warning = ''; FileCount = 4; TotalBytes = 20; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0 })
            [System.IO.File]::WriteAllText($script:WorkerStatePath, ([ordered]@{ Action = 'Analyze'; Phase = 'PreflightFailed'; Success = $false; Jobs = $finalJobs } | ConvertTo-Json -Depth 6), $utf8)
            [System.IO.File]::AppendAllText($script:WorkerLogPath, "[t] preflight error: $conflict`r`n", $utf8)
            [System.IO.File]::WriteAllText($script:WorkerResultPath, ([ordered]@{ Version = 1; RequestId = $script:WorkerRequestId; Action = 'Analyze'; ExitCode = 1 } | ConvertTo-Json), $utf8)
        }
    }
    Update-WorkerView
    Assert ($script:Injected -and $script:ActiveJob) 'tick 1: injection happened, task still active'
    Update-WorkerView
    Assert (-not $script:ActiveJob) 'tick 2: task completed'
    Assert ($script:Jobs[0].Status -eq 'Error' -and $script:Jobs[1].Error -like 'CONFLICT*') 'rows show the final errors' "status=$($script:Jobs[0].Status) error=$($script:Jobs[1].Error)"
    Assert ($grid.Rows[1].Cells['Status'].ErrorText -like 'CONFLICT*') 'error icon text on the Status cell'
    Assert ($logTextBox.Text.Contains('preflight error')) 'final log line shown'
    Assert (-not $script:PlanValid) 'plan not valid'
    ${function:Refresh-Grid} = $script:OriginalRefreshGrid
    Complete-Case

    '[G2] CleanupTarget follows migrate results'
    $script:WorkerAction = 'Migrate'
    $item = [pscustomobject]@{ Status = ''; Error = ''; Warning = ''; CleanupTarget = 'D:\old-copy' }
    Update-WorkerItem $item ([pscustomobject]@{ Status = 'Copying'; Error = ''; Warning = ''; Target = 'D:\new' })
    Assert ($item.CleanupTarget -eq 'D:\old-copy') 'in-progress status keeps the record'
    Update-WorkerItem $item ([pscustomobject]@{ Status = 'Complete'; Error = ''; Warning = ''; Target = 'D:\new' })
    Assert ($item.CleanupTarget -eq '') 'Complete clears the record'
    Update-WorkerItem $item ([pscustomobject]@{ Status = 'RolledBack'; Error = 'x'; Warning = ''; Target = 'D:\new' })
    Assert ($item.CleanupTarget -eq 'D:\new') 'RolledBack records the target'
    Update-WorkerItem $item ([pscustomobject]@{ Status = 'CompleteBackupRetained'; Error = ''; Warning = ''; Target = 'D:\new' })
    Assert ($item.CleanupTarget -eq '') 'CompleteBackupRetained clears the record'
    $script:WorkerAction = ''

    '[F5-1] normal acceptance still works'
    Reset-TestJobs
    Connect-FakeWorker 'Accept' 800
    Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig)
    Assert ($script:ActiveJob -and $script:WorkerEnginePid -gt 0 -and -not $statusLabel.Text.Contains('未收到')) 'accepted normally' $statusLabel.Text
    Assert (Wait-TaskEnd 15000) 'completed'
    Assert ($script:PlanValid -and $script:Jobs[0].Status -eq 'Ready') 'analysis result applied' "planValid=$($script:PlanValid) status=$($script:Jobs[0].Status)"
    Complete-Case

    '[F5-2] lost confirmation -> tracking until the result arrives'
    Reset-TestJobs
    Connect-FakeWorker 'Silent' 4000
    $script:WorkerReadTimeoutMs = 1500
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $thrown = ''
    try { Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig) } catch { $thrown = $_.Exception.Message }
    $elapsed = $watch.ElapsedMilliseconds
    Assert ([string]::IsNullOrEmpty($thrown)) 'Start-Worker did not throw' $thrown
    Assert ($elapsed -lt 4000) 'UI thread blocked only for the read timeout' "elapsed=$elapsed ms"
    Assert ($script:ActiveJob -and -not $analyzeButton.Enabled -and -not $startButton.Enabled) 'UI stays locked'
    Assert ($statusLabel.Text.Contains('未收到')) 'status explains the lost confirmation' $statusLabel.Text
    Assert ($null -eq $script:WorkerPipe -and $null -ne $script:Worker -and -not $script:Worker.HasExited) 'pipe closed, worker kept and not killed'
    Assert ([System.IO.Directory]::Exists($script:WorkerSessionPath)) 'session directory kept'
    Update-WorkerView
    Assert ($script:ActiveJob) 'still locked while the task runs'
    Assert (Wait-TaskEnd 20000) 'completed after the result arrived'
    Assert ($script:PlanValid -and $script:Jobs[1].Status -eq 'Ready') 'result applied (exit 0)' "planValid=$($script:PlanValid) status=$($script:Jobs[1].Status) label=$($statusLabel.Text)"
    Assert ($script:Worker.WaitForExit(8000)) 'worker exits after reading the closed pipe'
    Complete-Case

    '[F5-3] lost confirmation during Migrate keeps the journal and records failed copies'
    Reset-TestJobs
    Connect-FakeWorker 'Silent' 2500 'Failed' 1
    $script:WorkerReadTimeoutMs = 1000
    Start-Worker 'Migrate' @($script:Jobs) (Get-WorkerConfig)
    $journalFiles = @([System.IO.Directory]::GetFiles($script:RecoveryJournalRoot, '*.json'))
    Assert ($script:ActiveJob -and $journalFiles.Count -eq 1) 'tracking with recovery journal written' "active=$($script:ActiveJob) journals=$($journalFiles.Count)"
    Assert (Wait-TaskEnd 20000) 'completed'
    Assert ([System.IO.File]::Exists($journalFiles[0])) 'journal kept after a failed migration'
    Assert ($script:Jobs[0].CleanupTarget -eq 'D:\mkl-test-dst\A' -and $cleanupButton.Enabled) 'failed copies offered for cleanup' "cleanup=$($script:Jobs[0].CleanupTarget) button=$($cleanupButton.Enabled)"
    Complete-Case

    '[F5-4] worker dies after reading the request -> unlock with a message'
    Reset-TestJobs
    Connect-FakeWorker 'Die'
    $thrown = ''
    try { Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig) } catch { $thrown = $_.Exception.Message }
    Assert ([string]::IsNullOrEmpty($thrown) -and $script:ActiveJob) 'disconnect treated as possibly accepted' $thrown
    Assert (Wait-TaskEnd 10000) 'completed'
    Assert ($statusLabel.Text.Contains('没有返回本次任务的结果') -and -not $script:PlanValid) 'reports the missing result' $statusLabel.Text
    Complete-Case

    '[F5-5] worker dies while its engine keeps running -> stays locked until the engine ends'
    Reset-TestJobs
    Connect-FakeWorker 'DieEngineRuns' 6000 'Copying' 1
    Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 2500) { Start-Sleep -Milliseconds 200; Update-WorkerView }
    Assert ($script:ActiveJob -and $script:WorkerEnginePid -gt 0) 'still locked, engine identity adopted from state.json' "active=$($script:ActiveJob) pid=$($script:WorkerEnginePid)"
    Assert (Wait-TaskEnd 20000) 'completed after the engine ended'
    Assert ($statusLabel.Text.Contains('没有返回本次任务的结果')) 'reports the missing result' $statusLabel.Text
    Complete-Case

    '[F5-6] explicit rejection -> error, session removed, connection kept'
    Reset-TestJobs
    Connect-FakeWorker 'Reject'
    $before = Get-SessionDirs
    $thrown = ''
    try { Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig) } catch { $thrown = $_.Exception.Message }
    $after = Get-SessionDirs
    Assert ($thrown.Contains('rejected by fake worker') -and -not $script:ActiveJob) 'rejection surfaces as an error' $thrown
    Assert (@($after | Where-Object { $before -notcontains $_ }).Count -eq 0) 'session directory removed'
    Assert ($null -ne $script:WorkerPipe) 'connection kept for the next request'
    Complete-Case

    '[G4] Test-EngineRunning without HasExited, against a process that denies QUERY_INFORMATION and SYNCHRONIZE'
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class GuiTestNative { [DllImport("advapi32.dll", SetLastError = true)] public static extern uint SetSecurityInfo(IntPtr handle, int objectType, int securityInfo, IntPtr owner, IntPtr group, byte[] dacl, IntPtr sacl); }'
    $engine = Start-StandIn '-NoProfile -Command Start-Sleep -Seconds 3'
    $engineStart = [string]$engine.StartTime.ToFileTime()
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor('D:(D;;0x100400;;;WD)(A;;0x1FFFFF;;;WD)')
    $dacl = New-Object byte[] $sd.DiscretionaryAcl.BinaryLength
    $sd.DiscretionaryAcl.GetBinaryForm($dacl, 0)
    [void][GuiTestNative]::SetSecurityInfo($engine.Handle, 6, 4, [IntPtr]::Zero, [IntPtr]::Zero, $dacl, [IntPtr]::Zero)
    $script:WorkerEnginePid = $engine.Id
    $script:WorkerEngineStartTime = $engineStart
    Assert (Test-EngineRunning) 'running engine detected'
    $script:WorkerEngineStartTime = '1'
    Assert (-not (Test-EngineRunning)) 'reused PID (different start time) not treated as the engine'
    $script:WorkerEngineStartTime = $engineStart
    [void]$engine.WaitForExit(10000)
    Start-Sleep -Milliseconds 300
    Assert (-not (Test-EngineRunning)) 'exited engine detected'
    $script:WorkerEnginePid = 0
    $script:WorkerEngineStartTime = ''

    '[G5] stale session directories are removed, everything else is left alone'
    [void][System.IO.Directory]::CreateDirectory($cleanupRoot)
    $oldSession = New-SessionDirectory $cleanupRoot ('mklinktool-' + [guid]::NewGuid().ToString('N')) 10 @('job.json', 'state.json', 'engine.log')
    $readOnlySession = New-SessionDirectory $cleanupRoot ('mklinktool-' + [guid]::NewGuid().ToString('N')) 10 @('state.json')
    [System.IO.File]::SetAttributes((Join-Path $readOnlySession 'state.json'), [System.IO.FileAttributes]::ReadOnly)
    [System.IO.Directory]::SetLastWriteTimeUtc($readOnlySession, [DateTime]::UtcNow.AddDays(-10))
    $recentSession = New-SessionDirectory $cleanupRoot ('mklinktool-' + [guid]::NewGuid().ToString('N')) 1 @('state.json')
    $oldWithRecentFile = New-SessionDirectory $cleanupRoot ('mklinktool-' + [guid]::NewGuid().ToString('N')) 10 @('job.json')
    [System.IO.File]::WriteAllText((Join-Path $oldWithRecentFile 'engine.log'), 'still writing', $utf8)
    [System.IO.Directory]::SetLastWriteTimeUtc($oldWithRecentFile, [DateTime]::UtcNow.AddDays(-10))
    $withSubdirectory = New-SessionDirectory $cleanupRoot ('mklinktool-' + [guid]::NewGuid().ToString('N')) 10 @('job.json')
    [void][System.IO.Directory]::CreateDirectory((Join-Path $withSubdirectory 'unexpected'))
    [System.IO.Directory]::SetLastWriteTimeUtc($withSubdirectory, [DateTime]::UtcNow.AddDays(-10))
    $otherName = New-SessionDirectory $cleanupRoot 'mklinktool-corrupt-backup' 30 @('file.ps1')
    $linkTargetDir = New-SessionDirectory $cleanupRoot 'link-target' 30 @('precious.txt')
    $linkedSession = Join-Path $cleanupRoot ('mklinktool-' + [guid]::NewGuid().ToString('N'))
    $null = & cmd.exe /c mklink /J $linkedSession $linkTargetDir
    $removedCount = & $script:RealRemoveStaleSessionDirectories $cleanupRoot 7
    Assert ($removedCount -eq 2) 'two stale sessions removed' "removed=$removedCount"
    Assert (-not [System.IO.Directory]::Exists($oldSession) -and -not [System.IO.Directory]::Exists($readOnlySession)) 'old sessions (including a read-only file) deleted'
    Assert ([System.IO.Directory]::Exists($recentSession)) 'recent session kept'
    Assert ([System.IO.Directory]::Exists($oldWithRecentFile)) 'session with a recently written file kept'
    Assert ([System.IO.Directory]::Exists((Join-Path $withSubdirectory 'unexpected'))) 'session with unexpected content kept'
    Assert ([System.IO.File]::Exists((Join-Path $otherName 'file.ps1'))) 'non-session name kept'
    Assert ([System.IO.Directory]::Exists($linkedSession) -and [System.IO.File]::Exists((Join-Path $linkTargetDir 'precious.txt'))) 'junction named like a session kept, its target untouched'

    '[G6] keep-source-permissions option: permission hints, plan validity and the engine config'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $permissionRoot 'src\P'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $permissionRoot 'broad'))
    # 目标位置给 Users 可继承的修改权限，来源（%TEMP% 下）没有：不勾选时应给出提示。
    $null = & icacls.exe (Join-Path $permissionRoot 'broad') /grant '*S-1-5-32-545:(OI)(CI)M'
    $script:Jobs.Clear()
    [void]$script:Jobs.Add([pscustomobject]@{
        Source = (Join-Path $permissionRoot 'src\P'); Target = (Join-Path $permissionRoot 'broad\P'); IsCustomTarget = $true
        FileCount = 0; TotalBytes = 0L; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0
        Status = 'Ready'; Warning = ''; PermissionWarning = ''; Error = ''; CleanupTarget = ''
    })
    Refresh-Grid
    $keepPermissionsCheckbox.Checked = $false
    Assert (-not (Get-WorkerConfig).KeepSourcePermissions) 'option off by default'
    $script:PlanValid = $true
    Assert ((Update-PermissionWarnings) -eq 1 -and $script:Jobs[0].PermissionWarning.Contains('目标沿用来源的访问权限')) 'unchecked: broad target location reported, hint names the option' $script:Jobs[0].PermissionWarning
    $keepPermissionsCheckbox.Checked = $true
    Assert ([string]::IsNullOrEmpty($script:Jobs[0].PermissionWarning) -and $statusLabel.Text.StartsWith('预检通过。')) 'checked: hint cleared at once' $statusLabel.Text
    Assert ($script:PlanValid -and (Get-WorkerConfig).KeepSourcePermissions) 'plan still valid, option passed to the engine'
    $keepPermissionsCheckbox.Checked = $false
    Assert (-not [string]::IsNullOrEmpty($script:Jobs[0].PermissionWarning) -and $statusLabel.Text.Contains('1 项')) 'unchecked again: hint back' $statusLabel.Text
    $script:PlanValid = $false

    '[G7] the tool-directory warning carries a fix command, and running it clears the warning'
    $toolDir = Join-Path $permissionRoot 'tool'
    [void][System.IO.Directory]::CreateDirectory($toolDir)
    $toolScript = Join-Path $toolDir 'migration-worker.ps1'
    [System.IO.File]::WriteAllText($toolScript, '# stand-in', $utf8)
    # 上级目录给 Users 可继承的修改权限；目录本身再加一条本机无法解析的 SID（像沙箱工具添加的那样）：icacls 处理不了这种条目。
    $null = & icacls.exe $permissionRoot /grant '*S-1-5-32-545:(OI)(CI)M'
    $unknownSid = 'S-1-5-21-1111111111-2222222222-3333333333-444444444'
    $toolSecurity = [System.IO.Directory]::GetAccessControl($toolDir)
    $toolSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier $unknownSid), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    [System.IO.Directory]::SetAccessControl($toolDir, $toolSecurity)
    $warning = Get-ToolTamperWarning $toolDir @($toolScript)
    Assert ($warning.Contains($unknownSid) -and $warning.Contains('C:\Program Files\mklinktool')) 'warning lists the unresolvable writer and the safe location' $warning
    Assert ((Get-WritePrincipalSids (Get-PathSecurity $toolDir) $false) -contains 'S-1-5-32-545') 'inherited broad writer detected'
    $fixLine = @($warning -split "`r?`n" | Where-Object { $_.StartsWith('$d = ') }) | Select-Object -First 1
    Assert ($null -ne $fixLine -and $fixLine.Contains($toolDir)) 'warning contains a fix command for this directory'
    if ($null -ne $fixLine) {
        $encodedFix = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($fixLine))
        $fixOutput = & $powershellExe -NoProfile -EncodedCommand $encodedFix 2>&1 | Out-String
        Assert ($LASTEXITCODE -eq 0) 'fix command runs' $fixOutput
        Assert ([string]::IsNullOrEmpty((Get-ToolTamperWarning $toolDir @($toolScript)))) 'no warning after the fix (inherited and unresolvable entries removed)'
        [System.IO.File]::AppendAllText($toolScript, "`r`n# still writable by the current user", $utf8)
        Assert ([System.IO.File]::ReadAllText($toolScript).Contains('still writable')) 'the current user can still edit the scripts'
    }
} catch {
    "TEST BODY ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $script:TestFail++
} finally {
    $script:ActiveJob = $false
    try { Close-ElevatedWorker } catch { }
    foreach ($dir in $createdSessions) { try { [System.IO.Directory]::Delete($dir, $true) } catch { } }
    try { if ([System.IO.Directory]::Exists($script:RecoveryJournalRoot)) { [System.IO.Directory]::Delete($script:RecoveryJournalRoot, $true) } } catch { }
    try { Remove-TestTree $cleanupRoot } catch { }
    try { if ([System.IO.Directory]::Exists($permissionRoot)) { $null = & icacls.exe $permissionRoot /reset /T /Q; Remove-TestTree $permissionRoot } } catch { }
    $form.Close()
}
Write-TestSummary
