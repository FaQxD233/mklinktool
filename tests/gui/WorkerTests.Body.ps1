# 真实 Worker 端到端测试：由 tests\Test-Gui.ps1 点调用进 GUI 副本，在 GUI 脚本作用域内运行。
# 走真实的 Connect-ElevatedWorker → migration-worker.ps1 → migration-engine.ps1，Worker 路径由启动器在
# $script:TestWorkerPath 中给出。两种模式（$script:TestWorkerElevated）：
#   提权：仓库里原样的 Worker 经 UAC 启动，需要有人点一次“是”；来源中加入只有提权才能复制的嵌套目录符号链接。
#   普通：启动器复制出一份去掉提权检查的 Worker，并去掉 GUI 副本中的 -Verb RunAs，不弹 UAC，可放进默认测试。
# 只在 %TEMP% 下的临时目录里操作，结束时清理。
$testDir = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $testDir) 'TestHelpers.ps1')
. (Join-Path $testDir 'GuiHarness.ps1')
$elevated = [bool]$script:TestWorkerElevated
$script:WorkerPath = $script:TestWorkerPath
$script:EnginePath = Join-Path (Split-Path -Parent $script:TestWorkerPath) 'migration-engine.ps1'
$script:RecoveryJournalRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-worker-tests-journal-' + [guid]::NewGuid().ToString('N'))

# 启动检查与恢复结果弹窗换成桩：不读写真实的记录与旧会话，也不让 MessageBox 阻塞测试。
function Remove-StaleSessionDirectories { return 0 }
function Find-InterruptedMigrations { return }
function Show-RestoreSummary { }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WorkerTestNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool CreateSymbolicLinkW(string link, string target, uint flags);
}
'@

Show-TestForm
$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-worker-tests-' + [guid]::NewGuid().ToString('N'))
$sessionsBefore = Get-SessionDirs
$lockB = $null

function New-TextFile([string]$Path, [string]$Text) {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function New-DirectorySymlink([string]$Link, [string]$Target) {
    # 非提权创建需要开发者模式（flags 3 含 ALLOW_UNPRIVILEGED_CREATE）。
    if (-not [WorkerTestNative]::CreateSymbolicLinkW($Link, $Target, 3)) {
        throw "Failed to create symbolic link (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())): $Link"
    }
}

function New-TestJob([string]$Source, [string]$Target) {
    [pscustomobject]@{
        Source = $Source; Target = $Target; IsCustomTarget = $true
        FileCount = 0; TotalBytes = 0L; JunctionCount = 0; SymbolicLinkCount = 0; AbsoluteLinkCount = 0
        Status = 'NotChecked'; Warning = ''; PermissionWarning = ''; Error = ''; CleanupTarget = ''
    }
}

function Get-LinkType([string]$Path) {
    return [string][System.IO.DirectoryInfo]::new($Path).LinkType
}

try {
    "  mode: $(if ($elevated) { 'elevated worker via UAC' } else { 'unelevated worker copy, no UAC' })"
    # A：含 Junction；提权模式再加绝对、相对两种目录符号链接（非提权的 Robocopy 复制不了嵌套符号链接）。
    $sourceA = Join-Path $root 'src\A'
    New-TextFile (Join-Path $sourceA 'a.txt') 'AAAAA'
    New-TextFile (Join-Path $sourceA 'sub\b.txt') 'BBBBBBB'
    $null = & cmd.exe /c mklink /J (Join-Path $sourceA 'jn') (Join-Path $sourceA 'sub')
    if ($elevated) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $sourceA 'links'))
        New-DirectorySymlink (Join-Path $sourceA 'abs') (Join-Path $sourceA 'sub')
        New-DirectorySymlink (Join-Path $sourceA 'links\rel') '..\sub'
    }
    # B：迁移时用不带共享删除的句柄占住其中一个文件，来源改名会失败，留下目标副本供清理。
    $sourceB = Join-Path $root 'src\B'
    New-TextFile (Join-Path $sourceB 'keep.txt') 'keep'
    # C：模拟“改名后、建链前”中断：只剩备份，原路径为空。
    $sourceC = Join-Path $root 'src\C'
    New-TextFile (Join-Path ($sourceC + '_migration_backup') 'data.txt') 'backup'
    # D：确认丢失测试用的小目录。
    $sourceD = Join-Path $root 'src\D'
    New-TextFile (Join-Path $sourceD 'd.txt') 'D'
    $targetA = Join-Path $root 'dst\A'
    $targetB = Join-Path $root 'dst\B'

    $script:Jobs.Clear()
    [void]$script:Jobs.Add((New-TestJob $sourceA $targetA))
    [void]$script:Jobs.Add((New-TestJob $sourceB $targetB))
    Refresh-Grid
    $jobA = $script:Jobs[0]
    $jobB = $script:Jobs[1]
    $expectedSymlinks = if ($elevated) { 2 } else { 0 }

    '[X1] Analyze through the real worker'
    Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig)
    Assert ($script:ActiveJob -and $script:WorkerEnginePid -gt 0) 'worker accepted the task' $statusLabel.Text
    Assert (Wait-TaskEnd 120000) 'analysis finished'
    Assert ($script:PlanValid -and $jobA.Status -eq 'Ready' -and $jobB.Status -eq 'Ready') 'both items pass preflight' "planValid=$($script:PlanValid) A=$($jobA.Status) $($jobA.Error) B=$($jobB.Status) $($jobB.Error)"
    Assert ([int]$jobA.JunctionCount -eq 1 -and [int]$jobA.SymbolicLinkCount -eq $expectedSymlinks) 'nested links counted' "junctions=$($jobA.JunctionCount) symlinks=$($jobA.SymbolicLinkCount)"

    '[X2] Migrate: A succeeds, B fails at the rename'
    $lockB = [System.IO.File]::Open((Join-Path $sourceB 'keep.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $deleteBackupCheckbox.Checked = $true
    Start-Worker 'Migrate' @($script:Jobs) (Get-WorkerConfig)
    Assert ($script:ActiveJob -and -not $statusLabel.Text.Contains('未收到')) 'same worker reused, accepted normally' $statusLabel.Text
    Assert (Wait-TaskEnd 180000) 'migration finished'
    Assert ($jobA.Status -eq 'Complete') 'A complete' "$($jobA.Status) $($jobA.Error)"
    Assert ((Get-LinkType $sourceA) -eq 'SymbolicLink' -and -not [System.IO.Directory]::Exists($sourceA + '_migration_backup')) 'A is now a symbolic link, backup deleted'
    Assert ((Get-LinkType (Join-Path $targetA 'jn')) -eq 'Junction' -and [System.IO.File]::ReadAllText((Join-Path $sourceA 'jn\b.txt')) -eq 'BBBBBBB') 'nested junction preserved and reachable through the new link'
    if ($elevated) {
        Assert ((Get-LinkType (Join-Path $targetA 'abs')) -eq 'SymbolicLink' -and (Get-LinkType (Join-Path $targetA 'links\rel')) -eq 'SymbolicLink') 'nested symbolic links preserved in the target'
        Assert ([System.IO.File]::ReadAllText((Join-Path $sourceA 'links\rel\b.txt')) -eq 'BBBBBBB') 'data reachable through the relative nested link'
    }
    Assert ($jobB.Status -eq 'Failed' -and $jobB.CleanupTarget -eq $targetB) 'B failed before the rename, copy offered for cleanup' "$($jobB.Status) cleanup=$($jobB.CleanupTarget) $($jobB.Error)"
    Assert ([System.IO.File]::Exists((Join-Path $sourceB 'keep.txt')) -and [System.IO.Directory]::Exists($targetB)) 'B source intact, copy left behind'
    Assert ($cleanupButton.Enabled -and @([System.IO.Directory]::GetFiles($script:RecoveryJournalRoot, '*.json')).Count -eq 1) 'cleanup button enabled, recovery journal kept'
    $lockB.Dispose()
    $lockB = $null

    '[X3] Clean up the failed copy of B'
    $candidates = @(Get-CleanupCandidates)
    $config = [pscustomobject]@{ Jobs = @($candidates | ForEach-Object { [pscustomobject]@{ Source = $_.Source; Target = $_.CleanupTarget } }) }
    Start-Worker 'Cleanup' $candidates $config
    Assert (Wait-TaskEnd 120000) 'cleanup finished'
    Assert ($jobB.Status -eq 'Cleaned' -and -not [System.IO.Directory]::Exists($targetB) -and [System.IO.File]::Exists((Join-Path $sourceB 'keep.txt'))) 'copy removed, source untouched' "$($jobB.Status) $($jobB.Error)"
    Assert (-not $cleanupButton.Enabled) 'nothing left to clean'

    '[X4] Restore an interrupted migration'
    $restoreItems = @([pscustomobject]@{ Source = $sourceC; Target = (Join-Path $root 'dst\C'); Status = 'Waiting'; Error = ''; Warning = '' })
    $restoreConfig = [pscustomobject]@{ Jobs = @([pscustomobject]@{ Source = $sourceC; Target = (Join-Path $root 'dst\C') }) }
    Start-Worker 'Restore' $restoreItems $restoreConfig
    Assert (Wait-TaskEnd 120000) 'restore finished'
    Assert ($restoreItems[0].Status -eq 'Restored' -and [System.IO.File]::Exists((Join-Path $sourceC 'data.txt')) -and -not [System.IO.Directory]::Exists($sourceC + '_migration_backup')) 'backup moved back' "$($restoreItems[0].Status) $($restoreItems[0].Error)"

    '[X5] Lost confirmation: the worker still writes the result, tracking ends normally'
    $script:Jobs.Clear()
    [void]$script:Jobs.Add((New-TestJob $sourceD (Join-Path $root 'dst\D')))
    Refresh-Grid
    $script:WorkerReadTimeoutMs = 1
    $thrown = ''
    try { Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig) } catch { $thrown = $_.Exception.Message }
    $script:WorkerReadTimeoutMs = 30000
    Assert ([string]::IsNullOrEmpty($thrown) -and $script:ActiveJob -and $statusLabel.Text.Contains('未收到')) 'tracking started' "$thrown | $($statusLabel.Text)"
    $sessionD = $script:WorkerSessionPath
    Assert (Wait-TaskEnd 120000) 'tracking finished'
    Assert (@([System.IO.Directory]::GetFiles($sessionD, 'result-*.json')).Count -eq 1) 'worker wrote the result although its reply could not be sent'
    Assert ($script:PlanValid -and $script:Jobs[0].Status -eq 'Ready' -and -not $statusLabel.Text.Contains('没有返回')) 'completed with the real outcome' $statusLabel.Text
    Assert ($script:Worker.WaitForExit(10000) -and $script:Worker.HasExited -eq $true) 'worker exits afterwards; its exit is visible through the launch handle'
} catch {
    "TEST BODY ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $script:TestFail++
} finally {
    if ($null -ne $lockB) { $lockB.Dispose() }
    $script:ActiveJob = $false
    try { Close-ElevatedWorker } catch { }
    try { Remove-TestTree $root } catch { "  cleanup of $root failed: $($_.Exception.Message)" }
    try { Remove-TestTree $script:RecoveryJournalRoot } catch { }
    foreach ($session in @(Get-SessionDirs | Where-Object { $sessionsBefore -notcontains $_ })) {
        try { Remove-TestTree $session } catch { "  cleanup of $session failed: $($_.Exception.Message)" }
    }
    $form.Close()
}
Write-TestSummary
