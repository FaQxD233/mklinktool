# 引擎端到端与故障注入测试。需要 Windows PowerShell 5.1，并开启开发者模式（或以管理员身份运行）以创建目录符号链接。
# 每个用例使用独立目录和一份引擎副本；故障注入的做法是在副本里找到唯一匹配的一行代码，在其前后插入或直接替换为测试代码。
# 非提权运行时 Robocopy 无法复制嵌套符号链接，因此来源树里的嵌套链接一律用 Junction。
param([string]$EnginePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
if ([string]::IsNullOrEmpty($EnginePath)) { $EnginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'migration-engine.ps1' }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$engineText = [System.IO.File]::ReadAllText($EnginePath, [System.Text.Encoding]::UTF8)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-engine-tests-' + [guid]::NewGuid().ToString('N'))

function New-Case([string]$Name) {
    $caseDir = Join-Path $testRoot $Name
    [void][System.IO.Directory]::CreateDirectory($caseDir)
    return $caseDir
}

function New-EngineCopy([string]$CaseDir, [string]$Anchor, [string]$Injection, [ValidateSet('Before', 'After', 'Replace', 'None')][string]$Mode) {
    $text = $engineText
    if ($Mode -ne 'None') {
        $count = ([regex]::Matches($text, [regex]::Escape($Anchor))).Count
        if ($count -ne 1) { throw "Anchor must match exactly once, found $count : $Anchor" }
        $replacement = switch ($Mode) {
            'Before' { $Injection + "`n" + $Anchor }
            'After' { $Anchor + "`n" + $Injection }
            'Replace' { $Injection }
        }
        $text = $text.Replace($Anchor, $replacement)
    }
    $path = Join-Path $CaseDir 'engine.ps1'
    [System.IO.File]::WriteAllText($path, $text, $utf8Bom)
    return $path
}

function New-Junction([string]$Path, [string]$Target) {
    $null = & cmd.exe /c mklink /J $Path $Target
    if (-not [System.IO.Directory]::Exists($Path)) { throw "Failed to create junction: $Path" }
}

function New-SourceTree([string]$Root) {
    # a.txt / sub\b.txt / ro.txt（只读）/ rodir\c.txt（只读目录）/ jn -> sub（绝对目标的 Junction）
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Root 'sub'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Root 'rodir'))
    [System.IO.File]::WriteAllText((Join-Path $Root 'a.txt'), 'AAAAA', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'sub\b.txt'), 'BBBBBBB', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'ro.txt'), 'readonly', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'rodir\c.txt'), 'C', $utf8NoBom)
    [System.IO.File]::SetAttributes((Join-Path $Root 'ro.txt'), [System.IO.FileAttributes]::ReadOnly)
    [System.IO.File]::SetAttributes((Join-Path $Root 'rodir'), [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReadOnly)
    New-Junction (Join-Path $Root 'jn') (Join-Path $Root 'sub')
    # 让原始时间戳明显早于测试中的改写。
    foreach ($file in [System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
        $attributes = [System.IO.File]::GetAttributes($file)
        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::SetLastWriteTimeUtc($file, [DateTime]::UtcNow.AddHours(-2))
        [System.IO.File]::SetAttributes($file, $attributes)
    }
}

function Invoke-Engine([string]$CaseDir, [string]$Action, [object[]]$Jobs, [bool]$DeleteBackup = $true, [string]$Anchor = '', [string]$Injection = '', [string]$Mode = 'None') {
    $config = [pscustomobject]@{ LinkType = 'SymbolicLink'; VerifySha256 = $false; DeleteBackup = $DeleteBackup; Jobs = @($Jobs) }
    [System.IO.File]::WriteAllText((Join-Path $CaseDir 'job.json'), ($config | ConvertTo-Json -Depth 5), $utf8NoBom)
    $engine = New-EngineCopy $CaseDir $Anchor $Injection $Mode
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -Action $Action -ConfigPath (Join-Path $CaseDir 'job.json') -StatePath (Join-Path $CaseDir 'state.json') -LogPath (Join-Path $CaseDir 'engine.log') -RobocopyLogPath (Join-Path $CaseDir 'robocopy.log') | Out-Null
    $exitCode = $LASTEXITCODE
    $state = [System.IO.File]::ReadAllText((Join-Path $CaseDir 'state.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $log = [System.IO.File]::ReadAllText((Join-Path $CaseDir 'engine.log'), [System.Text.Encoding]::UTF8)
    return [pscustomobject]@{ Dir = $CaseDir; ExitCode = $exitCode; State = $state; Log = $log; Jobs = @($Jobs) }
}

function Invoke-EngineCase([string]$Name, [int]$JobCount = 1, [bool]$DeleteBackup = $true, [string]$Anchor = '', [string]$Injection = '', [string]$Mode = 'None', [string]$Action = 'Migrate') {
    # 为每项作业生成一棵标准来源树，再以指定动作运行引擎。
    $caseDir = New-Case $Name
    $jobs = @()
    for ($i = 1; $i -le $JobCount; $i++) {
        $source = Join-Path $caseDir "src\data$i"
        New-SourceTree $source
        $jobs += [pscustomobject]@{ Source = $source; Target = (Join-Path $caseDir "dst\data$i") }
    }
    return Invoke-Engine $caseDir $Action $jobs $DeleteBackup $Anchor $Injection $Mode
}

function Get-LinkInfo([string]$Path) {
    $info = [System.IO.DirectoryInfo]::new($Path)
    $target = $info.Target
    if ($target -is [array]) { $target = $target[0] }
    return [pscustomobject]@{ Exists = $info.Exists; LinkType = [string]$info.LinkType; Target = [string]$target }
}

function Test-NormalDirectory([string]$Path) {
    if (-not [System.IO.Directory]::Exists($Path)) { return $false }
    return (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}

function New-TextFile([string]$Path, [string]$Text) {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

# 下面的注入代码在引擎的 Invoke-Migration 作用域内运行，可直接使用 $source、$backup。
$writeSourceSameSize = "[System.IO.File]::WriteAllText((Join-Path `$source 'a.txt'), 'ZZZZZ'); [System.IO.File]::SetLastWriteTimeUtc((Join-Path `$source 'a.txt'), [DateTime]::UtcNow)"
$writeBackupSameSize = "[System.IO.File]::WriteAllText((Join-Path `$backup 'a.txt'), 'ZZZZZ'); [System.IO.File]::SetLastWriteTimeUtc((Join-Path `$backup 'a.txt'), [DateTime]::UtcNow)"

[void][System.IO.Directory]::CreateDirectory($testRoot)
try {
    '[E1] Migrate success, delete backup, nested junction + read-only file/dir'
    $r = Invoke-EngineCase 'e1'
    $job = @($r.State.Jobs)[0]
    $link = Get-LinkInfo $r.Jobs[0].Source
    Assert ($r.ExitCode -eq 0) 'exit code 0' "exit=$($r.ExitCode) errors=$(@($r.State.Errors) -join ' | ')"
    Assert ($job.Status -eq 'Complete') 'status Complete' "status=$($job.Status) error=$($job.Error)"
    Assert ($link.LinkType -eq 'SymbolicLink' -and $link.Target -eq $r.Jobs[0].Target) 'source is symlink to target' "$($link.LinkType) -> $($link.Target)"
    Assert (-not [System.IO.Directory]::Exists($r.Jobs[0].Source + '_migration_backup')) 'backup deleted'
    Assert ([System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Target 'a.txt')) -eq 'AAAAA') 'target content'
    Assert ((Get-LinkInfo (Join-Path $r.Jobs[0].Target 'jn')).LinkType -eq 'Junction') 'nested junction kept'
    Assert ([int]$r.State.EnginePid -gt 0 -and -not [string]::IsNullOrEmpty([string]$r.State.EngineStartTime)) 'state has EnginePid/EngineStartTime'
    Assert ($r.Log.Contains('文件大小和修改时间')) 'NTFS target: mtime compared'
    $robocopyLog = [System.IO.File]::ReadAllText((Join-Path $r.Dir 'robocopy.log'))
    Assert (-not $robocopyLog.Contains('a.txt')) 'robocopy log does not list copied files (/NFL)'

    '[E2] Migrate success, keep backup'
    $r = Invoke-EngineCase 'e2' -DeleteBackup $false
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained') 'status CompleteBackupRetained' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert (Test-NormalDirectory ($r.Jobs[0].Source + '_migration_backup')) 'backup retained'

    '[E3] Same-size write after robocopy, before source snapshot -> copy verification fails on mtime'
    $r = Invoke-EngineCase 'e3' -Anchor '$sourceSnapshot = Get-TreeSnapshot -Path $source -IncludeHash:([bool]$Config.VerifySha256)' -Injection $writeSourceSameSize -Mode Before
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'Failed') 'status Failed' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ($job.Error.Contains('修改时间') -and $job.Error.Contains('a.txt')) 'error names the mtime mismatch of a.txt' $job.Error
    Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and [System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Source 'a.txt')) -eq 'ZZZZZ') 'source intact with the new content'
    Assert (-not [System.IO.Directory]::Exists($r.Jobs[0].Source + '_migration_backup')) 'no backup created'

    '[E4] Same-size write after verification, before rename -> rolled back after the link check'
    $r = Invoke-EngineCase 'e4' -JobCount 2 -Anchor "`$analysis.Status = 'RenamingSource'" -Injection $writeSourceSameSize -Mode Before
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'RolledBack') 'status RolledBack' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ($job.Error.Contains('仍被写入') -and $job.Error.Contains('修改时间')) 'error explains the write' $job.Error
    Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and [System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Source 'a.txt')) -eq 'ZZZZZ') 'source restored with the newer content'
    Assert ([System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Target 'a.txt')) -eq 'AAAAA') 'stale target copy kept'
    Assert (-not [System.IO.Directory]::Exists($r.Jobs[0].Source + '_migration_backup')) 'backup renamed back'
    Assert (@($r.State.Jobs)[1].Status -eq 'NotStarted') 'next job NotStarted' (@($r.State.Jobs)[1].Status)

    '[E5] New file before rename -> rolled back (file count)'
    $r = Invoke-EngineCase 'e5' -Anchor "`$analysis.Status = 'RenamingSource'" -Injection "[System.IO.File]::WriteAllText((Join-Path `$source 'new.txt'), 'N')" -Mode Before
    $job = @($r.State.Jobs)[0]
    Assert ($job.Status -eq 'RolledBack' -and $job.Error.Contains('文件数')) 'RolledBack on file count' "status=$($job.Status) error=$($job.Error)"
    Assert ([System.IO.File]::Exists((Join-Path $r.Jobs[0].Source 'new.txt'))) 'new file back at the source'

    '[E6] Write into the renamed backup before link creation -> rolled back'
    $r = Invoke-EngineCase 'e6' -Anchor '$backupCreated = $true' -Injection $writeBackupSameSize -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($job.Status -eq 'RolledBack' -and $job.Error.Contains('修改时间')) 'RolledBack on the backup write' "status=$($job.Status) error=$($job.Error)"
    Assert ([System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Source 'a.txt')) -eq 'ZZZZZ') 'source has the write'

    '[E7] Exception right after the commit point -> no rollback'
    $r = Invoke-EngineCase 'e7' -Anchor '$jobSucceeded = $true' -Injection "throw 'injected post-commit failure'" -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained') 'CompleteBackupRetained, exit 0' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ((Get-LinkInfo $r.Jobs[0].Source).LinkType -eq 'SymbolicLink') 'working link kept'
    Assert (Test-NormalDirectory ($r.Jobs[0].Source + '_migration_backup')) 'backup kept'

    '[E8] Link creation failure -> rollback, following job NotStarted'
    $r = Invoke-EngineCase 'e8' -JobCount 2 -Anchor 'New-DirectorySymbolicLink (Get-ExtendedLengthPath $source) $target' -Injection "throw 'injected link failure'" -Mode Replace
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'RolledBack') 'RolledBack' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert (Test-NormalDirectory $r.Jobs[0].Source) 'source restored'
    Assert (@($r.State.Jobs)[1].Status -eq 'NotStarted') 'next job NotStarted'

    '[E9] Backup removal fails midway -> link kept, backup reported as possibly incomplete'
    $r = Invoke-EngineCase 'e9' -Anchor '[System.IO.Directory]::Delete($extendedRoot, $true)' -Injection "throw 'injected delete failure'" -Mode Replace
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained') 'CompleteBackupRetained, exit 0' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ($job.Error.Contains('中途失败')) 'message says the backup may be incomplete' $job.Error
    Assert ((Get-LinkInfo $r.Jobs[0].Source).LinkType -eq 'SymbolicLink') 'working link kept'

    '[E10] Backup enumeration fails before anything is removed -> backup reported intact'
    $r = Invoke-EngineCase 'e10' -Anchor '$ModificationStarted.Value = $true' -Injection "throw 'injected enumeration failure'" -Mode Replace
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained' -and $job.Error.Contains('完整保留')) 'backup reported intact' "status=$($job.Status) error=$($job.Error)"
    Assert ([System.IO.File]::Exists((Join-Path ($r.Jobs[0].Source + '_migration_backup') 'a.txt'))) 'backup really intact'

    '[E11] Analyze'
    $r = Invoke-EngineCase 'e11' -Action 'Analyze'
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'Ready' -and [int]$job.FileCount -eq 4 -and [int]$job.JunctionCount -eq 1) 'Analyze Ready with counts' "exit=$($r.ExitCode) status=$($job.Status) files=$($job.FileCount) junctions=$($job.JunctionCount) error=$($job.Error)"

    '[E12] Cross-item conflicts are reported on every affected row'
    $caseDir = New-Case 'e12'
    $outer = Join-Path $caseDir 'src\outer'
    New-SourceTree $outer
    $r = Invoke-Engine $caseDir 'Analyze' @(
        [pscustomobject]@{ Source = $outer; Target = (Join-Path $caseDir 'dst\outer') },
        [pscustomobject]@{ Source = (Join-Path $outer 'sub'); Target = (Join-Path $caseDir 'dst\inner') })
    $items = @($r.State.Jobs)
    Assert ($r.ExitCode -eq 1 -and $items[0].Status -eq 'Error' -and $items[1].Status -eq 'Error') 'both rows marked Error' "exit=$($r.ExitCode) statuses=$($items[0].Status)/$($items[1].Status)"
    Assert ($items[0].Error.Contains('互相包含') -and $items[0].Error -eq $items[1].Error) 'same conflict message on both rows' "$($items[0].Error) | $($items[1].Error)"

    '[E13] Cleanup removes a leftover copy without following links inside it'
    $caseDir = New-Case 'e13'
    $source = Join-Path $caseDir 'src\data'
    New-SourceTree $source
    $target = Join-Path $caseDir 'dst\data'
    New-TextFile (Join-Path $target 'copy.txt') 'copy'
    New-Junction (Join-Path $target 'back-to-source') $source
    $r = Invoke-Engine $caseDir 'Cleanup' @([pscustomobject]@{ Source = $source; Target = $target })
    Assert ($r.ExitCode -eq 0 -and @($r.State.Jobs)[0].Status -eq 'Cleaned') 'status Cleaned' "exit=$($r.ExitCode) status=$(@($r.State.Jobs)[0].Status) error=$(@($r.State.Jobs)[0].Error)"
    Assert (-not [System.IO.Directory]::Exists($target)) 'copy deleted'
    Assert ([System.IO.File]::ReadAllText((Join-Path $source 'a.txt')) -eq 'AAAAA' -and [System.IO.File]::Exists((Join-Path $source 'sub\b.txt'))) 'source untouched through the link'

    '[E14] Cleanup refuses whenever the copy might be the only complete data'
    $caseDir = New-Case 'e14'
    $linkedTarget = Join-Path $caseDir 'dst\linked'
    New-TextFile (Join-Path $linkedTarget 'data.txt') 'only copy'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $caseDir 'src'))
    $linkedSource = Join-Path $caseDir 'src\linked'
    New-Junction $linkedSource $linkedTarget
    $backedSource = Join-Path $caseDir 'src\backed'
    New-SourceTree $backedSource
    [void][System.IO.Directory]::CreateDirectory($backedSource + '_migration_backup')
    $backedTarget = Join-Path $caseDir 'dst\backed'
    New-TextFile (Join-Path $backedTarget 'data.txt') 'copy'
    $plainSource = Join-Path $caseDir 'src\plain'
    New-SourceTree $plainSource
    $elsewhere = Join-Path $caseDir 'elsewhere'
    New-TextFile (Join-Path $elsewhere 'keep.txt') 'keep'
    $linkTarget = Join-Path $caseDir 'dst\plain'
    New-Junction $linkTarget $elsewhere
    $r = Invoke-Engine $caseDir 'Cleanup' @(
        [pscustomobject]@{ Source = $linkedSource; Target = $linkedTarget },
        [pscustomobject]@{ Source = $backedSource; Target = $backedTarget },
        [pscustomobject]@{ Source = $plainSource; Target = $linkTarget })
    $items = @($r.State.Jobs)
    Assert ($r.ExitCode -eq 1) 'exit code 1'
    Assert ($items[0].Status -eq 'CleanupFailed' -and [System.IO.File]::Exists((Join-Path $linkedTarget 'data.txt'))) 'source is a link: copy kept' "$($items[0].Status) $($items[0].Error)"
    Assert ($items[1].Status -eq 'CleanupFailed' -and [System.IO.File]::Exists((Join-Path $backedTarget 'data.txt'))) 'backup exists: copy kept' "$($items[1].Status) $($items[1].Error)"
    Assert ($items[2].Status -eq 'CleanupFailed' -and [System.IO.File]::Exists((Join-Path $elsewhere 'keep.txt'))) 'copy is a link: nothing deleted' "$($items[2].Status) $($items[2].Error)"

    '[E15] Restore moves an orphaned backup back and skips an occupied original path'
    $caseDir = New-Case 'e15'
    $missing = Join-Path $caseDir 'src\missing'
    New-TextFile (Join-Path ($missing + '_migration_backup') 'data.txt') 'backup'
    $occupied = Join-Path $caseDir 'src\occupied'
    New-TextFile (Join-Path $occupied 'current.txt') 'current'
    New-TextFile (Join-Path ($occupied + '_migration_backup') 'old.txt') 'old'
    $r = Invoke-Engine $caseDir 'Restore' @(
        [pscustomobject]@{ Source = $missing; Target = (Join-Path $caseDir 'dst\missing') },
        [pscustomobject]@{ Source = $occupied; Target = (Join-Path $caseDir 'dst\occupied') })
    $items = @($r.State.Jobs)
    Assert ($r.ExitCode -eq 0 -and $items[0].Status -eq 'Restored') 'backup restored' "exit=$($r.ExitCode) status=$($items[0].Status) error=$($items[0].Error)"
    Assert ([System.IO.File]::Exists((Join-Path $missing 'data.txt')) -and -not [System.IO.Directory]::Exists($missing + '_migration_backup')) 'data back at the original path'
    Assert ($items[1].Status -eq 'RestoreSkipped' -and [System.IO.File]::Exists((Join-Path $occupied 'current.txt')) -and [System.IO.Directory]::Exists($occupied + '_migration_backup')) 'occupied path left unchanged' $items[1].Status

    '[E16] The engine lock refuses a second migrating engine but not Analyze'
    $mutex = [System.Threading.Mutex]::new($false, 'Global\mklinktool-engine')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        Assert $held 'test holds the engine lock'
        $r = Invoke-EngineCase 'e16'
        Assert ($r.ExitCode -eq 1 -and (@($r.State.Errors) -join ' ').Contains('另一个迁移')) 'Migrate refused while locked' "exit=$($r.ExitCode) errors=$(@($r.State.Errors) -join ' | ')"
        Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and -not [System.IO.Directory]::Exists($r.Jobs[0].Target)) 'nothing touched'
        $r = Invoke-EngineCase 'e16b' -Action 'Analyze'
        Assert ($r.ExitCode -eq 0) 'Analyze not blocked by the lock'
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} catch {
    "TEST ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $script:TestFail++
} finally {
    Remove-TestTree $testRoot
}
Write-TestSummary
if ($script:TestFail -gt 0) { exit 1 }
exit 0
